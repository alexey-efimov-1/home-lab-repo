#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY_FILE="${SCRIPT_DIR}/hosts.ini"

if [ ! -f "$INVENTORY_FILE" ]; then
    echo "Ошибка: файл hosts.ini не найден в ${SCRIPT_DIR}"
    exit 1
fi

# Извлекаем уникальные IP-адреса из строк с ansible_host=
IPS=$(grep 'ansible_host=' "$INVENTORY_FILE" \
      | grep -v '^#' \
      | awk -F'ansible_host=' '{print $2}' \
      | awk '{print $1}' \
      | tr -d '\r' \
      | sort -u)

if [ -z "$IPS" ]; then
    echo "Ошибка: в hosts.ini не найдено IP-адресов"
    exit 1
fi

echo "Начало подготовки виртуальных машин..."

echo 'Acquire::ForceIPv4 "true";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4

for IP in $IPS; do
    echo "--- Подготовка ВМ: ${IP} ---"
    
    # Удаляем старые SSH-ключи для этого IP из стандартного файла known_hosts
    # Это предотвращает ошибки подключения, если ВМ была пересоздана с тем же адресом
    ssh-keygen -f '/home/unit/.ssh/known_hosts' -R "${IP}" 2>/dev/null || true
    
    # Выполняем команды на удаленной машине через SSH
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ansible@"${IP}" bash << 'REMOTE_SCRIPT'
set -e

# Обновляем список пакетов и систему
sudo apt update
sudo apt upgrade -y

# Отключаем swap (Kubernetes не работает с включенным swap)
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Устанавливаем Python 3 (обязательно для работы Kubespray)
sudo apt install -y python3 python3-pip

# Загружаем сетевые модули ядра
sudo modprobe br_netfilter
sudo modprobe overlay

# Добавляем параметры ядра для корректной работы сетевой политики и маршрутизации
cat << 'SYSCTL' | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
SYSCTL

sudo sysctl --system

echo "Подготовка завершена."
REMOTE_SCRIPT
    
    echo "ВМ ${IP} готова."
    echo "-----------------------------------"
done

echo "Все виртуальные машины подготовлены."