 ### Запуск локально standalone\cluster kafka

Скопировать репо и перейти в директорию со скриптами для ВМ, выдать права и запустить скрипт для подготовки машины к работе:
``` bash
git clone https://github.com/alexey-efimov-1/home-lab-repo.git
cd home-lab-repo/infra/VMs/regular-version/
sudo chmod +x prepare-jumpbox.sh create-vm.sh
sudo ./prepare-jumpbox.sh
```

После подготовки машины создать нужное количество ВМ (например, 3 шт для минимального кластера):
```bash
sudo create-vm.sh vm-kafka-1 192.168.122.20 "" 2048 2
sudo create-vm.sh vm-kafka-2 192.168.122.21 "" 2048 2
sudo create-vm.sh vm-kafka-3 192.168.122.22 "" 2048 2
```

Подождать 2-3 минуты для полной инициализации ВМ.
Перейти в директорию ~/home-lab-repo/infra/kafka

Настроить инвентори под свои нужды (например, кластер на 3х хостах):
```
[kafka]
vm-kafka-1 ansible_host=192.168.122.20 ansible_user=ansible ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'
vm-kafka-2 ansible_host=192.168.122.21 ansible_user=ansible ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'
vm-kafka-3 ansible_host=192.168.122.22 ansible_user=ansible ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'
# Для standalone оставить только один хост. Ansible сам определит режим.
#для кластера указать нужное количество хостов.
```

Запустить плейбук:
``` bash
ansible-playbook -i inventory.ini playbook.yaml
```