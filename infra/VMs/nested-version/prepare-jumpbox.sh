#!/usr/bin/env bash
#==============================================================================
# Подготовка Ubuntu-хоста для вложенной виртуализации (nested KVM)
# Запускается ЕДИНОЖДЫ на jumpbox после первой загрузки
#==============================================================================
set -euo pipefail
#------------------------------------------------------------------------------
# Константы
#------------------------------------------------------------------------------
readonly LIBVIRT_DIR="/var/lib/libvirt/images"
readonly BASE_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
readonly BASE_IMG="${LIBVIRT_DIR}/noble-server-cloudimg-amd64.img"
readonly NET_NAME="default"
readonly GATEWAY="192.168.122.1"
readonly DHCP_RANGE_START="192.168.122.100"
readonly DHCP_RANGE_END="192.168.122.200"

#------------------------------------------------------------------------------
# Вспомогательные функции
#------------------------------------------------------------------------------
log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; }

#------------------------------------------------------------------------------
# Проверка прав суперпользователя
#------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  error "Run script with sudo: sudo $0"
  exit 1
fi

# Определяем реального пользователя и его домашнюю директорию
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
SSH_DIR="$REAL_HOME/.ssh"
SSH_KEY="$SSH_DIR/id_ed25519"

if [[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]]; then
  error "Не удалось определить домашнюю директорию пользователя '$REAL_USER'."
  exit 1
fi

#------------------------------------------------------------------------------
# 1. Установка зависимостей
#------------------------------------------------------------------------------
log "Обновление пакетов и установка зависимостей..."
apt update -qq
apt install -y -qq \
  qemu-kvm libvirt-daemon-system libvirt-clients \
  cloud-image-utils virtinst genisoimage \
  iptables-persistent netfilter-persistent \
  curl wget git openssh-client >/dev/null

#------------------------------------------------------------------------------
# 2. Проверка вложенной виртуализации
#------------------------------------------------------------------------------
log "Проверка поддержки вложенной виртуализации..."
if ! command -v kvm-ok &>/dev/null || ! kvm-ok &>/dev/null; then
  error "KVM не доступен. Включите Nested VT-x/AMD-V в настройках VirtualBox:"
  error "  Settings -> System -> Processor -> Enable Nested VT-x/AMD-V"
  error "Перезагрузите ВМ и запустите скрипт повторно."
  exit 1
fi
log "Поддержка KVM подтверждена."

#------------------------------------------------------------------------------
# 3. Генерация SSH-ключа (если отсутствует)
#------------------------------------------------------------------------------
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

#------------------------------------------------------------------------------
# 4. Настройка прав доступа к libvirt
#------------------------------------------------------------------------------
log "Добавление пользователя '$REAL_USER' в группу libvirt..."
usermod -aG libvirt "$REAL_USER"
log "Пользователь добавлен. Для применения изменений выполните: newgrp libvirt"
log "Либо выйдите из системы и зайдите заново."

#------------------------------------------------------------------------------
# 5. Включение IP-форвардинга и настройка NAT
#------------------------------------------------------------------------------
log "Настройка IP-форвардинга и правил iptables..."

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-nested-virt.conf
sysctl -p /etc/sysctl.d/99-nested-virt.conf >/dev/null

EXT_IF=$(ip route | grep default | awk '{print $5}' | head -1)
if [[ -z "$EXT_IF" ]]; then
  error "Не удалось определить внешний сетевой интерфейс."
  exit 1
fi
log "Внешний интерфейс: $EXT_IF"

# Очистка старых правил для идемпотентности
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true

# Разрешение маскарадинга и перенаправления трафика
iptables -t nat -A POSTROUTING -s "${GATEWAY%.*}.0/24" -o "$EXT_IF" -j MASQUERADE
iptables -A FORWARD -i "$EXT_IF" -o virbr0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i virbr0 -o "$EXT_IF" -j ACCEPT

# Сохранение правил
netfilter-persistent save >/dev/null 2>&1 || true
systemctl enable --now netfilter-persistent >/dev/null 2>&1 || true

log "NAT и правила перенаправления сохранены."

#------------------------------------------------------------------------------
# 6. Настройка DHCP-диапазона libvirt (чтобы не конфликтовал со статикой)
#------------------------------------------------------------------------------
log "Проверка конфигурации сети libvirt..."

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

#------------------------------------------------------------------------------
# 7. Скачивание базового облачного образа
#------------------------------------------------------------------------------
if [[ ! -f "$BASE_IMG" ]]; then
  log "Скачивание базового образа Ubuntu (~500 МБ)..."
  mkdir -p "$LIBVIRT_DIR"
  curl -L -o "$BASE_IMG" "$BASE_IMG_URL"
  chmod 644 "$BASE_IMG"
  log "Образ сохранён: $BASE_IMG"
else
  log "Базовый образ уже существует: $BASE_IMG"
fi

#------------------------------------------------------------------------------
# 8. Итоговое сообщение
#------------------------------------------------------------------------------
echo ""
log "Настройка завершена."
echo ""
echo "Дальнейшие действия:"
echo "  1. Примените изменения группы: newgrp libvirt (или перелогиньтесь)"
echo "  2. Создавайте ВМ: ./create-vm.sh <имя> <статический_ip> [mac] [ram_mb] [vcpus]"
echo "  3. Пример: ./create-vm.sh web-01 192.168.122.10"