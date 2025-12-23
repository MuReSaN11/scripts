#!/bin/bash

GREEN="\e[32m"
RED="\e[31m"
RESET="\e[0m"
INFO="\e[36m"

# ================== Функція встановлення з прогресом ==================
install_pkg() {
    echo -e "${INFO}[INFO] Встановлення пакетів: $@...${RESET}"
    
    if command -v apt-get >/dev/null 2>&1; then
        # Оновлення списків (без зайвого тексту)
        apt-get update -qq
        # Встановлення з виводом лише відсотків прогресу
        # Використовуємо status-fd для отримання точних даних від dpkg
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" -o Dpkg::Progress-Fancy="0" -q | \
        awk '
        BEGIN { FS=" "; }
        /Progress: \[/ { 
            split($0, a, "["); 
            split(a[2], b, "%"); 
            printf "\rProgress: %d%%", b[1];
        }
        END { print "\n"; }'
        
    elif command -v dnf >/dev/null 2>&1; then
        if grep -qi "AlmaLinux" /etc/os-release; then
            [ -f /etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux ] && rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux || true
        fi
        dnf install -y "$@" --quiet --refresh
        echo -e "${GREEN}Done!${RESET}"
        
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$@" -q
        echo -e "${GREEN}Done!${RESET}"
        
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm "$@" --quiet >/dev/null
        echo -e "${GREEN}Done!${RESET}"
        
    else
        echo -e "${RED}❌ No supported package manager found!${RESET}" >&2
        exit 1
    fi
}

# ================== Початок роботи ==================
# Спочатку ставимо пакети, щоб далі все працювало
install_pkg iperf3 smartmontools curl lshw dmidecode ethtool

echo -e "\n${INFO}===== SERVER INFORMATION =====${RESET}"

# ================== OS Info ==================
echo -e "${INFO}[OS INFO]${RESET}"
if [ -f /etc/os-release ]; then
    OS_NAME=$(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)
    KERNEL=$(uname -r)
    echo "OS: $OS_NAME"
    echo "Kernel: $KERNEL"
fi

# ================== Users ==================
echo -e "\n${INFO}[USERS]${RESET}"
awk -F: '$1 != "root" && $1 != "nobody" && $1 != "nogroup" && $6 ~ /^\/home\//' /etc/passwd \
| while IFS=: read -r username _ _ _ _ homedir shell; do
    echo -e "User: ${RED}$username${RESET}, Home: $homedir, Shell: $shell"
done

# ================== Disks & Mount Points ==================
echo -e "\n${INFO}[DISKS]${RESET}"

raid_disks=$(smartctl --scan | grep megaraid || true)

if [ -n "$raid_disks" ]; then
    echo -e "${INFO}MegaRAID detected — scanning physical drives...${RESET}"
    echo "$raid_disks" | while read -r line; do
        dev=$(echo "$line" | awk '{print $1}')
        num=$(echo "$line" | grep -o 'megaraid,[0-9]\+' | cut -d, -f2)
        echo -e "\n=== RAID Physical Disk $num ==="
        model=$(smartctl -i -d megaraid,$num $dev | grep -E "Model|Device Model" | awk -F: '{print $2}' | xargs)
        health=$(smartctl -H -d megaraid,$num $dev | grep "overall-health" | awk -F: '{print $2}' | xargs)
        [[ "$health" == "PASSED" ]] && echo -e "Health: ${GREEN}$health${RESET}" || echo -e "Health: ${RED}$health${RESET}"
        smartctl -A -d megaraid,$num $dev | grep -E "Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable" | while read -r line; do
            val=$(echo $line | awk '{print $10}')
            [[ "$val" -eq 0 ]] && echo -e "${GREEN}$line${RESET}" || echo -e "${RED}$line${RESET}"
        done
    done
else
    for disk in $(lsblk -d -n -o NAME,TYPE | awk '$2=="disk"{print $1}'); do
        type="HDD/SSD"; [[ "$disk" == nvme* ]] && type="NVMe"
        size=$(lsblk -dn -o SIZE /dev/$disk)
        echo -e "\n=== $disk ($type) - $size ==="
        model=$(smartctl -i /dev/$disk | grep -E "Model|Device Model" | awk -F: '{print $2}' | xargs)
        health=$(smartctl -H /dev/$disk | grep "overall-health" | awk -F: '{print $2}' | xargs)
        [[ "$health" == "PASSED" ]] && echo -e "Health: ${GREEN}$health${RESET}" || echo -e "Health: ${RED}$health${RESET}"
    done
fi

echo -e "\n${INFO}[MOUNT POINTS]${RESET}"
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT | grep -v "loop"

# ================== CPU ==================
echo -e "\n${INFO}[CPU]${RESET}"
cpu_model=$(lscpu | grep "Model name:" | sed 's/Model name:\s*//')
echo "Model: $cpu_model"
echo "Cores: $(lscpu | grep "^CPU(s):" | awk '{print $2}')"

# ================== RAM ==================
echo -e "\n${INFO}[RAM]${RESET}"
mem_total_gb=$(free -g | awk '/Mem:/ {print $2}')
mem_types=$(dmidecode -t memory | grep -i "Type:" | grep -E "DDR3|DDR4|DDR5" | sort -u | xargs)
echo "Total RAM: ~${mem_total_gb} GB"
echo "Type: $mem_types"

# ================== Network & iperf3 ==================
echo -e "\n${INFO}[NETWORK]${RESET}"
iface=$(ls /sys/class/net | grep -v lo | head -n 1)
speed=$(ethtool $iface 2>/dev/null | grep "Speed:" | awk '{print $2}')
IP=$(curl -s ifconfig.me)
COUNTRY=$(curl -s ipinfo.io/$IP | grep country | awk -F\" '{print $4}')

echo "Interface: $iface ($speed)"
echo "IP: $IP ($COUNTRY)"

case $COUNTRY in
    "UA") SERVER="iperf.vsys.host" ;;
    "NL") SERVER="iperf-ams.vsys.host" ;;
    "US") SERVER="iperf-us.vsys.host" ;;
    "SG") SERVER="iperf-sin1.vsys.host" ;;
    *) SERVER="" ;;
esac

if [ -n "$SERVER" ]; then
    echo "Running iperf3 test to $SERVER..."
    RESULT=$(iperf3 -c $SERVER -P 10 -f m -t 10 2>/dev/null | grep "\[SUM\].*receiver" | tail -n1)
    echo "Result: $RESULT"
else
    echo "iperf3: No suitable server for $COUNTRY"
fi

echo -e "\n${INFO}===== END =====${RESET}"
