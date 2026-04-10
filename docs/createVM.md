# Создание вирутальных машин (Nested-KVM)

Набор bash-скриптов для быстрой развёртки вложенной виртуализации (nested KVM) на Ubuntu с автоматической настройкой cloud-init и SSH-доступа.

Почему вложенная виртуализация?
На рабочем ПК установлен windows.
wsl мне не походит, vagrant+hyperx мне не нравится.
Поэтому решение такое - создается ВМ с помощью VirtualBox.
Эта ВМ, в свою очередь, является хостовой для лабораторных машин.

### Пререквизиты:
-ВМ с достаточным количеством ресурсов (16Гб+ более памяти, 4+vcpu)
-включена вложенная виртуализация (Nested VT-x/AMD-V) в настройках ВМ

### Для быстрого запуска:

``` bash
git clone https://github.com/alexey-efimov-1/home-lab-repo.git
cd home-lab-repo/infra/VMs/nested-version/
chmod +x prepare-jumpbox.sh create-vm.sh
sudo ./prepare-jumpbox.sh
```

### Скрипт подготовит хостовую ВМ:
-установит пакеты: qemu-kvm, libvirt-daemon-system, libvirt-clients, cloud-image-utils, virtinst, genisoimage, curl, wget, git, openssh-client
-создаст ssh ключ, если его нет
-проверит поддержку KVM через kvm-ok
-проведет подготовку групп и пользователя
-настроит правила UFW для virbr0
-настроит DHCP-пул libvirt (сузит до диапазона .100-.200)
-скачает базовый образ noble-server-cloudimg-amd64.img

После подготовки ВМ можно приступать к созданию нужного количества ВМ со статическим IP.
Также будет создан пользователь ansible и настроен ssh доступ.

Команда для создания ВМ:
``` bash
sudo ./create-vm.sh <имя> <IP> [MAC] [RAM_МБ] [vCPU]
```

Значения по умолчанию зашиты внутри скрипта, можно переопредлить в команде вызова, например:

``` bash
sudo ./create-vm.sh my-vm 192.168.122.99 "" 2048 2 
```

Скрипты разработаны для Ubuntu 24.04 (Noble Numbat) и libvirt ≥ 8.0

базовые команды для управаления ВМ:

``` bash
virsh list --all                    # Список всех ВМ
virsh start <имя>                   # Запуск
virsh shutdown <имя>                # Корректное выключение
virsh destroy <имя>                 # Принудительное выключение (аналог выдёргивания шнура)
virsh reboot <имя>                  # Перезагрузка
virsh undefine <имя> --remove-all-storage  # Полное удаление ВМ и дисков
virsh dominfo <имя>                 # Подробная информация о ресурсах
virsh domstate <имя>                # Текущее состояние
virsh console <имя>                 # Подключение к последовательной консоли (выход: Ctrl + ])
virsh net-dhcp-leases default       # Просмотр выданных DHCP-адресов
virsh autostart <имя>               # Включение автозапуска при старте хоста
```

