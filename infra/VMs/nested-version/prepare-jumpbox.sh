#!/usr/bin/env bash
#==============================================================================
# Подготовка Ubuntu-хоста для вложенной виртуализации (nested KVM)
# Запускается ЕДИНОЖДЫ на jumpbox после первой загрузки
#==============================================================================
set -euo pipefail

readonly LIBVIRT_DIR="/var/lib/libvirt/images"
readonly BASE_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
readonly BASE_IMG="${LIBVIRT_DIR}/noble-server-cloudimg-amd64.img"
readonly NET_NAME="default"
readonly DHCP_RANGE_START="192.168.122.100"
readonly DHCP_RANGE_END="192.168.122.200"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  error "Run this script with sudo: sudo $0"
  exit 1
fi

REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
SSH_DIR="$REAL_HOME/.ssh"
SSH_KEY="$SSH_DIR/id_ed25519"

if [[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]]; then
  error "Не удалось определить домашнюю директорию пользователя '$REAL_USER'."
  exit 1
fi

log "Обновление пакетов и установка зависимостей..."
apt update -qq
apt install -y -qq \
  qemu-kvm libvirt-daemon-system libvirt-clients \
  cloud-image-utils virtinst genisoimage \
  curl wget git openssh-client >/dev/null

log "Проверка поддержки вложенной виртуализации..."
if ! command -v kvm-ok &>/dev/null || ! kvm-ok &>/dev/null; then
  error "KVM не доступен. Включите Nested VT-x/AMD-V в настройках VirtualBox."
  error "Перезагрузите ВМ и запустите скрипт повторно."
  exit 1
fi
log "Поддержка KVM подтверждена."

log "Проверка SSH-ключа для пользователя '$REAL_USER'..."
if [[ ! -f "$SSH_KEY" ]]; then
  log "Генерация пары ключей: $SSH_KEY"
  mkdir -p "$SSH_DIR"
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "${REAL_USER}@jumpbox"
  chown -R "$REAL_USER":"$REAL_USER" "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  chmod 600 "$SSH_KEY"
  chmod 644 "${SSH_KEY}.pub"
  log "SSH-ключ успешно создан."
else
  log "SSH-ключ уже существует: $SSH_KEY"
fi

log "Добавление пользователя '$REAL_USER' в группу libvirt..."
usermod -aG libvirt "$REAL_USER"
log "Для применения изменений выполните: newgrp libvirt"

# Включаем IP-форвардинг (libvirt обычно делает это сам, но гарантируем)
log "Включение IP-форвардинга..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-nested-virt.conf
sysctl -p /etc/sysctl.d/99-nested-virt.conf >/dev/null

# Настраиваем UFW, если он активен (по умолчанию блокирует FORWARD)
if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
  log "Обнаружен UFW. Разрешаем маршрутизацию для virbr0..."
  ufw allow in on virbr0 >/dev/null 2>&1 || true
  ufw allow out on virbr0 >/dev/null 2>&1 || true
  sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
  ufw reload >/dev/null 2>&1 || true
  log "UFW настроен для проброса трафика."
fi

# Ограничиваем DHCP-пул libvirt, чтобы освободить адреса для статики
log "Проверка DHCP-диапазона сети libvirt..."
if ! virsh net-info "$NET_NAME" &>/dev/null; then
  error "Сеть '$NET_NAME' не найдена. Убедитесь, что libvirt запущен."
  exit 1
fi

CURRENT_CONFIG=$(virsh net-dumpxml "$NET_NAME")
if ! echo "$CURRENT_CONFIG" | grep -q "${DHCP_RANGE_START}"; then
  log "Обновление DHCP-диапазона: ${DHCP_RANGE_START}-${DHCP_RANGE_END}"
  TEMP_XML=$(mktemp)
  echo "$CURRENT_CONFIG" | sed \
    -e "s|<range start='[^']*' end='[^']*'/>|<range start='${DHCP_RANGE_START}' end='${DHCP_RANGE_END}'/>|g" \
    > "$TEMP_XML"
  virsh net-define "$TEMP_XML" >/dev/null
  rm -f "$TEMP_XML"
  virsh net-destroy "$NET_NAME" >/dev/null 2>&1 || true
  virsh net-start "$NET_NAME" >/dev/null
else
  log "DHCP-диапазон уже настроен корректно."
fi

if [[ ! -f "$BASE_IMG" ]]; then
  log "Скачивание базового образа Ubuntu (~500 МБ)..."
  mkdir -p "$LIBVIRT_DIR"
  curl -L -o "$BASE_IMG" "$BASE_IMG_URL"
  chmod 644 "$BASE_IMG"
  log "Образ сохранён: $BASE_IMG"
else
  log "Базовый образ уже существует: $BASE_IMG"
fi

echo ""
log "Настройка завершена."
echo ""
echo "Дальнейшие действия:"
echo "  1. Примените изменения группы: newgrp libvirt"
echo "  2. Создавайте ВМ: sudo ./create-vm.sh <имя> <статический_ip> [mac] [ram_mb] [vcpus]"
echo "  3. Пример: sudo ./create-vm.sh web-01 192.168.122.10"
echo ""
echo "Сетевая конфигурация:"
echo "  Шлюз (virbr0):   192.168.122.1"
echo "  Статические:     192.168.122.2 - 192.168.122.99"
echo "  DHCP-пул:        ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"
echo "  Интернет:        NAT через встроенную сеть libvirt (default)"
echo "  SSH-ключ:        $SSH_KEY"