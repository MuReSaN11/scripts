#!/bin/bash
set -e

GREEN="\e[32m"
RED="\e[31m"
RESET="\e[0m"
INFO="\e[36m"

# ================== Визначення пакетного менеджера ==================
install_pkg() {
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq >/dev/null 2>&1
        sudo apt-get install -y "$@" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        if grep -qi "AlmaLinux" /etc/os-release; then
            echo -e "${INFO}[INFO] AlmaLinux виявлено — додаю GPG ключ${RESET}"
            sudo rpm --import https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux
        fi
        sudo dnf install -y "$@" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        if grep -qi "AlmaLinux" /etc/os-release; then
            echo -e "${INFO}[INFO] AlmaLinux виявлено — додаю GPG ключ${RESET}"
            sudo rpm --import https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux
        fi
        sudo yum install -y "$@" >/dev/null 2>&1
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper --non-interactive install "$@" >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm "$@" >/dev/null 2>&1
    else
        echo "❌ Не знайдено підтримуваного пакетного менеджера!" >&2
        exit 1
    fi
}

# ================== Встановлення необхідного ==================
install_pkg iperf3 smartmontools curl lshw dmidecode ethtool

echo -e "${INFO}===== ІНФОРМАЦІЯ ПРО СЕРВЕР =====${RESET}"

# ================== Видалення користувачів ==================
echo -e "\n${INFO}[ВИДАЛЕННЯ КОРИСТУВАЧІВ]${RESET}"
awk -F: '$1 != "root" && $1 != "nobody" && $1 != "nogroup" && $6 ~ /^\/home\//' /etc/passwd | while IFS=: read -r username _ _ _ _ homedir _; do
    echo "Видаляю користувача: $username та його домашню директорію $homedir"
    sudo userdel -r "$username" 2>/dev/null || echo "Не вдалося видалити $username або директорія відсутня"
done

# ================== Диски ==================
echo -e "\n${INFO}[ДИСКИ]${RESET}"
for disk in $(lsblk -d -n -o NAME,TYPE | awk '$2=="disk"{print $1}'); do
    type="HDD/SSD"
    [[ "$disk" == nvme* ]] && type="NVMe"
    echo -e "\n=== $disk ($type) ==="
    model=$(sudo smartctl -i /dev/$disk | grep -E "Model|Device Model" | awk -F: '{print $2}' | xargs)
    echo "Модель: $model"
    health=$(sudo smartctl -H /dev/$disk | grep "overall-health" | awk -F: '{print $2}' | xargs)
    [[ "$health" == "PASSED" ]] && echo -e "Здоров'я: ${GREEN}$health${RESET}" || echo -e "Здоров'я: ${RED}$health${RESET}"
    if [[ "$type" == "NVMe" ]]; then
        sudo smartctl -a /dev/$disk | grep -E "Reallocated|Current_Pending|Offline_Uncorrectable|Power_On|Temperature" | while read -r line; do
            value=$(echo $line | awk '{print $NF}')
            [[ "$value" =~ ^[0-9]+$ && "$value" -eq 0 ]] && echo -e "${GREEN}$line${RESET}" || echo -e "${RED}$line${RESET}"
        done
    else
        sudo smartctl -A /dev/$disk | grep -E "Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|Power_On_Hours|Temperature_Celsius" | while read -r line; do
            attr=$(echo $line | awk '{print $2}')
            val=$(echo $line | awk '{print $10}')
            if [[ "$attr" =~ Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable ]]; then
                [[ "$val" -eq 0 ]] && echo -e "${GREEN}$line${RESET}" || echo -e "${RED}$line${RESET}"
            else
                echo "$line"
            fi
        done
    fi
done

# ================== CPU ==================
echo -e "\n${INFO}[ПРОЦЕСОР]${RESET}"
sockets=$(lscpu | grep "Socket(s):" | awk '{print $2}')
cores=$(lscpu | grep "^CPU(s):" | awk '{print $2}')
model=$(lscpu | grep "Model name:" | sed 's/Model name:\s*//')
echo "Модель: $model"
echo "Сокетів: $sockets"
echo "Кількість ядер: $cores"

# ================== ОПЕРАТИВНА ПАМ'ЯТЬ ==================
echo -e "\n${INFO}[ОПЕРАТИВНА ПАМ'ЯТЬ]${RESET}"
mem_total_gb=$(free -g | awk '/Mem:/ {print $2}')
echo "Загальний об’єм: ${mem_total_gb} GB"
# Показуємо типи модулів
mem_types=$(sudo dmidecode -t memory | grep -i "Type:" | grep -E "DDR3|DDR4|DDR5" | sort -u | xargs)
echo "Тип модулів: $mem_types"

# ================== Мережа ==================
echo -e "\n${INFO}[МЕРЕЖА]${RESET}"
nic=$(lshw -class network -short | grep -v "lo" | awk '{print $2,$3,$4,$5,$6}')
iface=$(ls /sys/class/net | grep -v lo | head -n 1)
speed=$(ethtool $iface 2>/dev/null | grep "Speed:" | awk '{print $2}')
echo "Інтерфейс: $nic"
echo "Макс. пропускна здатність: ${speed:-невідомо}"

# ================== Інтернет / iperf3 ==================
echo -e "\n${INFO}[ІНТЕРНЕТ ТЕСТ]${RESET}"
IP=$(curl -s ifconfig.me)
COUNTRY=$(curl -s ipinfo.io/$IP | grep country | awk -F\" '{print $4}')
case $COUNTRY in
    "UA") SERVER="iperf.vsys.host" ;;
    "NL") SERVER="iperf-ams.vsys.host" ;;
    "US") SERVER="iperf-us.vsys.host" ;;
    "SG") SERVER="iperf-sin1.vsys.host" ;;
    *) SERVER="" ;;
esac

if [ -n "$SERVER" ]; then
    RAW=$(iperf3 -c $SERVER -P 10 -f m -t 10 2>/dev/null)
    RESULT=$(echo "$RAW" | grep "\[SUM\].*receiver" | tail -n1)
else
    RESULT="Локація не визначена або не підтримується"
fi

echo "IP: $IP ($COUNTRY)"
echo "Результат iperf3: $RESULT"

echo -e "\n${INFO}===== КІНЕЦЬ =====${RESET}"
