#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY_FILE="${SCRIPT_DIR}/hosts.ini"
KUBESPRAY_DIR="${SCRIPT_DIR}/kubespray"
VENV_DIR="${SCRIPT_DIR}/venv"

sudo apt install -y python3.12-venv

if [ ! -f "$INVENTORY_FILE" ]; then
    echo "Ошибка: файл hosts.ini не найден"
    exit 1
fi


# Клонируем Kubespray, если директория отсутствует
if [ ! -d "$KUBESPRAY_DIR" ]; then
    echo "Клонируем репозиторий Kubespray..."
    git clone https://github.com/kubernetes-sigs/kubespray.git "$KUBESPRAY_DIR"
    cd "$KUBESPRAY_DIR"
    cd "$SCRIPT_DIR"
else
    echo "Используем существующую директорию: ${KUBESPRAY_DIR}"
fi

# Проверяем целостность виртуального окружения.
# Если файла активации нет, удаляем папку и создаём окружение заново.
if [ ! -f "$VENV_DIR/bin/activate" ]; then
    echo "Виртуальное окружение отсутствует или повреждено. Создаём..."
    rm -rf "$VENV_DIR"
    python3 -m venv "$VENV_DIR"
else
    echo "Используем существующее виртуальное окружение."
fi

echo "Активируем виртуальное окружение..."
source "$VENV_DIR/bin/activate"

# Подготавливаем директорию инвентаря и копируем файл
INVENTORY_DIR="${KUBESPRAY_DIR}/inventory/mycluster"
mkdir -p "$INVENTORY_DIR"
cp "$INVENTORY_FILE" "${INVENTORY_DIR}/hosts.ini"

# Устанавливаем зависимости внутри виртуального окружения
echo "Устанавливаем зависимости Python..."
pip install -r "${KUBESPRAY_DIR}/requirements.txt"

# Запускаем основной плейбук установки Kubernetes
echo "Запускаем развертывание кластера..."
cd "$KUBESPRAY_DIR"
ansible-playbook -i inventory/mycluster/hosts.ini --user=ansible cluster.yml -b -vvv 
cd "$SCRIPT_DIR"

snap install kubectl --classic

# Определяем IP первого узла control-plane
CONTROL_PLANE_IP=$(grep 'ansible_host=' "$INVENTORY_FILE" \
                   | grep -v '^#' \
                   | head -n 1 \
                   | awk -F'ansible_host=' '{print $2}' \
                   | awk '{print $1}' \
                   | tr -d '\r')

if [ -z "$CONTROL_PLANE_IP" ]; then
    echo "Ошибка: не удалось определить IP контрольной плоскости"
    exit 1
fi

# Копируем конфигурационный файл кластера на управляющую машину
echo "Копируем kubeconfig..."
rm -rf ~/.kube
mkdir -p ~/.kube
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ansible@"${CONTROL_PLANE_IP}" \
    "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/config

chmod 600 ~/.kube/config

# Проверяем доступ к API
echo "Проверка подключения к кластеру..."
kubectl cluster-info

echo "Установка завершена."
echo "Конфигурация сохранена в ~/.kube/config"