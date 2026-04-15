#!/usr/bin/env bash
#==============================================================================
# prepare-jumpbox.sh
# Подготовка Ubuntu Desktop-хоста для KVM-виртуализации
# Запускается разово после установки системы
#==============================================================================
set -euo pipefail

readonly LIBVIRT_DIR="/var/lib/libvirt/images"
readonly BASE_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
readonly BASE_IMG="${LIBVIRT_DIR}/noble-server-cloudimg-amd64.img"
readonly NET_NAME="default"
readonly DHCP_RANGE_START="192.168.122.100"
readonly DHCP_RANGE_END="192.168.122.200"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
    error "скрипт требует SUDO привелегий: sudo $0"
fi

REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
SSH_DIR="$REAL_HOME/.ssh"
SSH_KEY="$SSH_DIR/id_ed25519"

if [[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]]; then
    error "Не удалось определить домашнюю директорию пользователя '$REAL_USER'."
fi

#------------------------------------------------------------------------------
# 1. Установка зависимостей
#------------------------------------------------------------------------------
log "Обновление пакетов и установка зависимостей..."
apt update -qq
apt install -y -qq \
    cpu-checker \
    qemu-kvm libvirt-daemon-system libvirt-clients \
    cloud-image-utils virtinst genisoimage \
    curl wget git openssh-client >/dev/null

#------------------------------------------------------------------------------
# 2. Проверка KVM
#------------------------------------------------------------------------------
log "Проверка поддержки аппаратной виртуализации..."
if ! kvm-ok &>/dev/null; then
    error "KVM не доступен. Убедитесь, что Virtualization Technology (VT-x/AMD-V) включена в BIOS/UEFI."
    error "Также проверьте: sudo modprobe kvm && ls -l /dev/kvm"
fi
log "Поддержка KVM подтверждена."

#------------------------------------------------------------------------------
# 3. SSH-ключи и группа libvirt
#------------------------------------------------------------------------------
log "Проверка SSH-ключа для пользователя '$REAL_USER'..."
if [[ ! -f "$SSH_KEY" ]]; then
    log "Генерация пары ключей: $SSH_KEY"
    mkdir -p "$SSH_DIR"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "${REAL_USER}@$(hostname)" >/dev/null
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

#------------------------------------------------------------------------------
# 4. Сетевые настройки
#------------------------------------------------------------------------------
log "Включение IP-форвардинга..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-kvm-net.conf
sysctl -p /etc/sysctl.d/99-kvm-net.conf >/dev/null 2>&1

if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
    log "UFW активен. Разрешаем трафик через virbr0..."
    ufw allow in on virbr0 >/dev/null 2>&1 || true
    ufw allow out on virbr0 >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
    log "UFW настроен."
fi

log "Настройка DHCP-диапазона сети libvirt..."
if ! virsh net-info "$NET_NAME" &>/dev/null; then
    error "Сеть '$NET_NAME' не найдена. Убедитесь, что сервис libvirtd запущен."
fi

# Функция для получения текущего диапазона DHCP
get_current_dhcp_range() {
    virsh net-dumpxml "$NET_NAME" 2>/dev/null | \
        grep -oP "<range start='\K[^']+(?=' end='[^']+'/>)" | head -1
}

CURRENT_START=$(get_current_dhcp_range)

if [[ "$CURRENT_START" != "${DHCP_RANGE_START}" ]]; then
    log "Обнаружен диапазон: ${CURRENT_START:-не задан}. Настраиваем: ${DHCP_RANGE_START}-${DHCP_RANGE_END}"
    
    # 1. Удаляем все существующие dhcp-range записи (если есть)
    while virsh net-dumpxml "$NET_NAME" 2>/dev/null | grep -q "<range start="; do
        OLD_RANGE=$(virsh net-dumpxml "$NET_NAME" | grep -oP "<range start='[^']*' end='[^']*'/>" | head -1)
        if [[ -n "$OLD_RANGE" ]]; then
            virsh net-update "$NET_NAME" delete ip-dhcp-range "$OLD_RANGE" --config --live 2>/dev/null || true
        fi
    done
    
    # 2. Добавляем новый диапазон
    virsh net-update "$NET_NAME" add-last ip-dhcp-range \
        "<range start='${DHCP_RANGE_START}' end='${DHCP_RANGE_END}'/>" \
        --config --live
    
    log "DHCP-диапазон обновлён: ${DHCP_RANGE_START}-${DHCP_RANGE_END}"
else
    log "DHCP-диапазон уже настроен корректно: ${DHCP_RANGE_START}-${DHCP_RANGE_END}"
fi

#------------------------------------------------------------------------------
# 5. Базовый образ
#------------------------------------------------------------------------------
if [[ ! -f "$BASE_IMG" ]]; then
    log "Скачивание базового образа Ubuntu Noble (~600 МБ)..."
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