#!/usr/bin/env bash
#==============================================================================
# create-vm.sh
# Создание ВМ в nested-KVM со статическим IP и cloud-init
# Использование: ./create-vm.sh <имя_вм> <статический_IP> [MAC-адрес] [память_МБ] [CPU]
#==============================================================================
set -euo pipefail
#------------------------------------------------------------------------------
# Параметры по умолчанию
#------------------------------------------------------------------------------
VM_NAME="${1:?Ошибка: укажите имя ВМ. Пример: $0 web-01 192.168.122.10}"
VM_IP="${2:?Ошибка: укажите статический IP. Пример: $0 web-01 192.168.122.10}"
VM_MAC="${3:-52:54:00:$(printf '%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))}"
RAM="${4:-1024}"
VCPUS="${5:-1}"

#------------------------------------------------------------------------------
# Константы
#------------------------------------------------------------------------------
readonly LIBVIRT_DIR="/var/lib/libvirt/images"
readonly BASE_IMG="${LIBVIRT_DIR}/noble-server-cloudimg-amd64.img"
readonly SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
readonly GATEWAY="192.168.122.1"
readonly NET_NAME="default"
readonly DISK_SIZE="20G"

#------------------------------------------------------------------------------
# Вспомогательные функции
#------------------------------------------------------------------------------
log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; }
cleanup() { 
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

#------------------------------------------------------------------------------
# Проверки
#------------------------------------------------------------------------------
log "Проверка параметров..."

# Валидация формата IP
if ! [[ "$VM_IP" =~ ^192\.168\.122\.[0-9]{1,3}$ ]]; then
  error "IP должен быть в подсети 192.168.122.0/24"
  exit 1
fi

# Проверка, что статический IP не попадает в DHCP-пул
IP_LAST="${VM_IP##*.}"
if [[ "$IP_LAST" -ge 100 && "$IP_LAST" -le 200 ]]; then
  error "Внимание: IP $VM_IP попадает в DHCP-диапазон (100-200). Рекомендуется использовать 2-99."
  read -p "Продолжить? [y/N] " -n 1 -r < /dev/tty || true
  echo
  [[ ! "$REPLY" =~ ^[Yy]$ ]] && exit 1
fi

# Проверка зависимостей
for cmd in virt-install cloud-localds virsh qemu-img; do
  command -v "$cmd" &>/dev/null || { error "Не найдена зависимость: $cmd"; exit 1; }
done

# Проверка базового образа
if [[ ! -f "$BASE_IMG" ]]; then
  error "Базовый образ не найден. Запустите сначала: sudo ./setup-jumpbox.sh"
  exit 1
fi

# Проверка SSH-ключа
if [[ ! -f "$SSH_KEY_FILE" ]]; then
  error "SSH-ключ не найден: $SSH_KEY_FILE"
  error "Сгенерируйте его: ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519"
  exit 1
fi

# Проверка, что ВМ ещё не существует
if virsh domstate "$VM_NAME" &>/dev/null; then
  error "ВМ '$VM_NAME' уже существует."
  error "Удалите её: virsh undefine $VM_NAME --remove-all-storage"
  exit 1
fi

#------------------------------------------------------------------------------
# Подготовка рабочей директории
#------------------------------------------------------------------------------
WORK_DIR="${LIBVIRT_DIR}/.staging/${VM_NAME}-$(date +%s)"
mkdir -p "$WORK_DIR"
log "Рабочая директория: $WORK_DIR"

#------------------------------------------------------------------------------
# 1. Создание диска ВМ
#------------------------------------------------------------------------------
log "Создание диска ВМ..."
VM_DISK="${LIBVIRT_DIR}/${VM_NAME}.qcow2"
cp "$BASE_IMG" "$VM_DISK"
qemu-img resize "$VM_DISK" "$DISK_SIZE" >/dev/null
chown libvirt-qemu:kvm "$VM_DISK" 2>/dev/null || true

#------------------------------------------------------------------------------
# 2. Генерация cloud-init конфигурации
#------------------------------------------------------------------------------
log "Генерация cloud-init конфигурации..."

SSH_PUBLIC_KEY=$(cat "$SSH_KEY_FILE")

cat > "${WORK_DIR}/user-data" <<EOF
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY}
    lock_passwd: true

network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses:
        - ${VM_IP}/24
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1, 9.9.9.9]

package_update: true
package_upgrade: false
packages:
  - openssh-server
  - curl
  - vim
  - wget
  - git

runcmd:
  - systemctl enable ssh
  - systemctl restart ssh

final_message: "ВМ ${VM_NAME} (${VM_IP}) успешно инициализирована"
EOF

cat > "${WORK_DIR}/meta-data" <<EOF
instance-id: ${VM_NAME}-$(date +%s)
local-hostname: ${VM_NAME}
EOF

#------------------------------------------------------------------------------
# 3. Создание seed-ISO для cloud-init
#------------------------------------------------------------------------------
log "Создание cloud-init seed-ISO..."
cloud-localds "${WORK_DIR}/seed.iso" "${WORK_DIR}/user-data" "${WORK_DIR}/meta-data"
chown libvirt-qemu:kvm "${WORK_DIR}/seed.iso" 2>/dev/null || true

#------------------------------------------------------------------------------
# 4. Запуск ВМ через virt-install
#------------------------------------------------------------------------------
log "Запуск ВМ '$VM_NAME' (IP: $VM_IP, MAC: $VM_MAC, RAM: ${RAM}MB, CPU: $VCPUS)..."

virt-install \
  --name "$VM_NAME" \
  --memory "$RAM" \
  --vcpus "$VCPUS" \
  --disk path="$VM_DISK",format=qcow2 \
  --disk path="${WORK_DIR}/seed.iso",device=cdrom,readonly=on \
  --os-variant ubuntu24.04 \
  --import \
  --network network="$NET_NAME",mac="$VM_MAC" \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole

virsh autostart "$VM_NAME" >/dev/null 2>&1 || true

#------------------------------------------------------------------------------
# 5. Ожидание запуска
#------------------------------------------------------------------------------
log "Ожидание запуска ВМ (до 90 сек)..."

for i in {1..45}; do
  if virsh domstate "$VM_NAME" 2>/dev/null | grep -q "running"; then
    log "ВМ запущена."
    break
  fi
  sleep 2
done

#------------------------------------------------------------------------------
# 6. Финальный вывод
#------------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "ВМ '${VM_NAME}' успешно создана"
echo "=========================================="
echo "IP-адрес:     ${VM_IP}"
echo "MAC-адрес:    ${VM_MAC}"
echo "SSH:          ssh ubuntu@${VM_IP}"
echo "Консоль:      virsh console ${VM_NAME}"
echo "Статус:       $(virsh domstate "$VM_NAME")"
echo "=========================================="
echo ""
echo "Полезные команды:"
echo "  Проверить доступность: ping -c 2 ${VM_IP}"
echo "  Посмотреть логи:       virsh console ${VM_NAME}  (выход: Ctrl + ])"
echo "  Остановить:            virsh shutdown ${VM_NAME}"
echo "  Удалить:               virsh undefine ${VM_NAME} --remove-all-storage"