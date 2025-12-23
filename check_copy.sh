#!/bin/bash

GREEN="\e[32m"
RED="\e[31m"
RESET="\e[0m"
INFO="\e[36m"

# ================== Функція встановлення з прогресом ==================
install_pkg() {
    local pkgs=("$@")
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        echo -ne "${INFO}[INFO] Installing packages... 0%${RESET}"
        
        # Використовуємо DEBIAN_FRONTEND та status-fd для відлову прогресу
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" -qq -o Dpkg::Use-Pty=0 2>&1 | \
        stdbuf -oL sed -n 's/^Progress: \[\([0-9]*\)%\].*/\1/p' | \
        while read prog; do
            echo -ne "\r${INFO}[INFO] Installing packages... ${prog}%${RESET}"
        done
        echo -e "\r${GREEN}[INFO] Installing packages... 100% - Done!${RESET}"
        
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${pkgs[@]}" --quiet
    else
        yum install -y "${pkgs[@]}" -q || pacman -Sy --noconfirm "${pkgs[@]}" >/dev/null 2>&1
    fi
}

# Встановлення необхідного софту
install_pkg iperf3 smartmontools curl lshw dmidecode ethtool

echo -e "\n${INFO}===== SERVER INFORMATION =====${RESET}"

# ================== OS Info (Без ядра) ==================
echo -e "${INFO}[OS INFO]${RESET}"
if [ -f /etc/os-release ]; then
    grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2
fi

# ================== Users ==================
echo -e "\n${INFO}[USERS]${RESET}"
awk -F: '$1 != "root" && $1 != "nobody" && $1 != "nogroup" && $6 ~ /^\/home\//' /etc/passwd \
| while IFS=: read -r username _ _ _ _ homedir shell; do
    echo -e "User: ${RED}$username${RESET}, Home: $homedir, Shell: $shell"
done

# ================== Disks ==================
echo -e "\n${INFO}[DISKS]${RESET}"
raid_disks=$(smartctl --scan | grep megaraid || true)

if [ -n "$raid_disks" ]; then
    echo "$raid_disks" | while read -r line; do
        dev=$(echo "$line" | awk '{print $1}')
        num=$(echo "$line" | grep -o 'megaraid,[0-9]\+' | cut -d, -f2)
        echo -e "\n=== RAID Physical Disk $num ==="
        model=$(smartctl -i -d megaraid,$num $dev | grep -E "Model|Device Model" | awk -F: '{print $2}' | xargs)
        health=$(smartctl -H -d megaraid,$num $dev | grep -iE "result|overall-health" | awk -F: '{print $2}' | xargs)
        echo "Model: ${model:-Virtual/Unknown}"
        [[ "$health" == "PASSED" || "$health" == "OK" ]] && echo -e "Health: ${GREEN}$health${RESET}" || echo -e "Health: ${RED}$health${RESET}"
    done
else
    for disk in $(lsblk -d -n -o NAME,TYPE | awk '$2=="disk"{print $1}'); do
        size=$(lsblk -dn -o SIZE /dev/$disk)
        echo -e "\n=== $disk ($size) ==="
        model=$(smartctl -i /dev/$disk 2>/dev/null | grep -E "Model|Device Model" | awk -F: '{print $2}' | xargs)
        [[ -z "$model" ]] && model=$(lsblk -dn -o MODEL /dev/$disk | xargs)
        echo "Model: ${model:-Virtual/Generic}"
        
        health=$(smartctl -H /dev/$disk 2>/dev/null | grep -iE "result|overall-health" | awk -F: '{print $2}' | xargs)
        if [ -n "$health" ]; then
            [[ "$health" == "PASSED" || "$health" == "OK" ]] && echo -e "Health: ${GREEN}$health${RESET}" || echo -e "Health: ${RED}$health${RESET}"
        fi
    done
fi

# ================== Mount Points (Лише SSD/NVMe/HDD) ==================
echo -e "\n${INFO}[MOUNT POINTS]${RESET}"
# Тільки фізичні диски та розділи, прибираємо loop, ram, sr
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT | grep -E "disk|part" | grep -vE "loop|ram|sr"

# ================== CPU ==================
echo -e "\n${INFO}[CPU]${RESET}"
cpu_model=$(lscpu | grep "Model name:" | sed 's/Model name:\s*//')
[[ -z "$cpu_model" ]] && cpu_model=$(lscpu | grep "BIOS" | sed 's/BIOS\s*//')
echo "Model: $cpu_model"
echo "Cores: $(lscpu | grep "^CPU(s):" | awk '{print $2}')"

# ================== RAM ==================
echo -e "\n${INFO}[RAM]${RESET}"
mem_total_mb=$(free -m | awk '/Mem:/ {print $2}')
mem_total_gb=$(( (mem_total_mb + 512) / 1024 ))
echo "Total RAM: ~${mem_total_gb} GB"

# ================== Network ==================
echo -e "\n${INFO}[NETWORK]${RESET}"
iface=$(ls /sys/class/net | grep -v lo | head -n 1)
speed=$(ethtool $iface 2>/dev/null | grep "Speed:" | awk '{print $2}')
echo "Interface: $iface"
echo "Max speed: ${speed:-Unknown}"

# ================== Internet / iperf3 з таймером ==================
echo -e "\n${INFO}[INTERNET TEST]${RESET}"
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
    echo "Server: $SERVER"
    # Запускаємо iperf3 у фоні
    iperf3 -c $SERVER -P 10 -f m -t 10 2>/dev/null > /tmp/iperf_res &
    iperf_pid=$!

    # Таймер зворотного відліку
    for i in {10..1}; do
        if ps -p $iperf_pid > /dev/null; then
            echo -ne "\rTesting speed... ${i}s left "
            sleep 1
        fi
    done
    wait $iperf_pid
    echo -e "\rTesting speed... Done!          "

    RESULT=$(grep "\[SUM\].*receiver" /tmp/iperf_res | tail -n1)
    rm -f /tmp/iperf_res
    
    echo "IP: $IP ($COUNTRY)"
    echo "iperf3 result: ${RESULT:-"Test failed"}"
else
    echo "IP: $IP ($COUNTRY)"
    echo "iperf3: No suitable server found for $COUNTRY"
fi

echo -e "\n${INFO}===== END =====${RESET}"
