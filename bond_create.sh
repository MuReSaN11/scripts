#!/bin/bash

# Перевірка на права root
if [[ $EUID -ne 0 ]]; then
   echo "Помилка: Цей скрипт потрібно запускати через sudo."
   exit 1
fi

echo "--- Налаштування Bonding (LACP) ---"

# 1. Виведення доступних інтерфейсів для довідки
echo "Доступні інтерфейси у вашій системі:"
ip -br link show | grep -v "lo"
echo "----------------------------------"

# 2. Збір даних від користувача
read -p "Введіть назву першого інтерфейсу (напр. enp94s0f0): " INTERFACE_1
read -p "Введіть назву другого інтерфейсу (напр. enp94s0f1): " INTERFACE_2
read -p "Введіть IP адресу з маскою (напр. 195.160.220.113/23): " IP_ADDR
read -p "Введіть Gateway (напр. 195.160.220.1): " GATEWAY
read -p "Введіть DNS (через кому, напр. 8.8.8.8, 1.1.1.1): " DNS_SERVERS

# 3. Формування конфігурації Netplan
# Використовуємо ваші специфічні параметри LACP та структуру
NETPLAN_FILE="/etc/netplan/01-netcfg-bond.yaml"

cat <<EOF > $NETPLAN_FILE
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE_1:
      dhcp4: no
      dhcp6: no
    $INTERFACE_2:
      dhcp4: no
      dhcp6: no
  bonds:
    bond0:
      interfaces: [$INTERFACE_1, $INTERFACE_2]
      addresses:
        - $IP_ADDR
      gateway4: $GATEWAY
      nameservers:
        addresses: [$DNS_SERVERS]
      parameters:
        mode: 802.3ad
        mii-monitor-interval: 1
        transmit-hash-policy: "layer3+4"
        lacp-rate: fast
EOF

echo "---"
echo "Файл $NETPLAN_FILE створено."

# 4. Застосування налаштувань
echo "Перевірка та застосування конфігурації..."
netplan apply

if [ $? -eq 0 ]; then
    echo "Налаштування успішно застосовано!"
    echo "--- Поточний статус інтерфейсу bond0 ---"
    ip a show bond0
    echo "--- Статус об'єднання (Bonding) ---"
    cat /proc/net/bonding/bond0 | grep -E "Bonding Mode|Transmit Hash Policy|Slave Interface|MII Status"
else
    echo "Виникла помилка під час застосування Netplan. Перевірте синтаксис."
fi
