# Скрипты для подготовки нод и создания кластера kubernetes

## Быстрый старт:

1. Копируем репо, выдаем права на скрипты и запускаем скрипт подготовки хостовой машины

``` bash
git clone https://github.com/alexey-efimov-1/home-lab-repo.git
cd home-lab-repo/infra/VMs/regular-version/
chmod +x prepare-jumpbox.sh create-vm.sh
sudo ./prepare-jumpbox.sh
```
2. Создать нужное количество ВМ

``` bash
sudo ./create-vm.sh master-node 192.168.122.10 "" 2048 2
sudo ./create-vm.sh worker-node 192.168.122.11 "" 2048 2 
```

3. Дождаться создания ВМ (лучше подождать 2-3 минуты до полной инициализации ВМ).
Выполнить подготовку ВМ:
``` bash
cd ~/home-lab-repo/infra/k8s/
chmod +x prepare_vms.sh install_k8s.sh
./prepare_vms.sh
```

4. Запуск установки k8s:

``` bash
./install_k8s.sh
```

## Настройка инвентори--файла.
Адреса должны быть описаны в файле hosts.ini по формату inventory для kubespray.

### Пример 1. Кластер на 2х нодах. Мастер + воркер.

Лежит тут:
~/home-lab-repo/infra/k8s/hosts.ini

``` vim
# Configure 'ip' variable to bind kubernetes services on a different ip than the default iface
# We should set etcd_member_name for etcd cluster. The node that are not etcd members do not need to set the value,
# or can set the empty string value.

[kube_control_plane]
node1 ansible_host=192.168.122.10 ip=192.168.122.10 etcd_member_name=etcd1

[etcd:children]
kube_control_plane

[kube_node]
node2 ansible_host=192.168.122.11 ip=192.168.122.11
```

### Пример 2. Кластер на 5-и нодах. 3 мастер + 2 воркера.
Лежит тут:
~/home-lab-repo/infra/k8s/hosts_HA_cluster.ini

``` vim
# This inventory describe a HA typology with stacked etcd (== same nodes as control plane)
# and 2 worker nodes
# See https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html
# for tips on building your # inventory

# Configure 'ip' variable to bind kubernetes services on a different ip than the default iface
# We should set etcd_member_name for etcd cluster. The node that are not etcd members do not need to set the value,
# or can set the empty string value.

[kube_control_plane]
node1 ansible_host=192.168.122.10 ip=192.168.122.10 etcd_member_name=etcd1
node2 ansible_host=192.168.122.11 ip=192.168.122.11 etcd_member_name=etcd2
node3 ansible_host=192.168.122.12 ip=192.168.122.12 etcd_member_name=etcd3

[etcd:children]
kube_control_plane

[kube_node]
node4 ansible_host=192.168.122.13 ip=192.168.122.13
node5 ansible_host=192.168.122.14 ip=192.168.122.14
```

Инвентори можно готовить под любую топологию кластера.
Скрипт подготовки спарсит все адреса ВМ и настроит их автоматически.

Скрипт сразу копирует конфигурацию для досступа к кластеру на машину, с которой запускается скрипт.