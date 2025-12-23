#!/bin/bash

# ================== Кольори та Стилі ==================
BOLD="\e[1m"
BLUE="\e[34m"
CYAN="\e[36m"
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
MAGENTA="\e[35m"
RESET="\e[0m"

# Іконки
CHECK="✔"
INFO_ICON="ℹ"
CPU_ICON="󰻠"
RAM_ICON="󰍛"
DISK_ICON="󰋊"
NET_ICON="󰖩"

# ================== Функції-помічники ==================
print_header() {
    echo -e "\n${BOLD}${CYAN}┌──────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${BOLD}${CYAN}│ %-56s │${RESET}" "$1"
    echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────────────────┘${RESET}"
}

print_row() {
    printf "${BLUE}%-20s${RESET} : %s\n" "$1" "$2"
}

# ================== Встановлення пакетів ==================
install_pkg() {
    local pkgs=("$@")
    if command -v apt-get >/dev/null 2>&1; then
        while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 ; do
            echo -ne "\r${RED}[WAIT]${RESET} Waiting for other package manager..."
            sleep 2
        done

        apt-get update -qq
        echo -ne "${CYAN}${INFO_ICON} [1/2] Preparing system...${RESET}"
        
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" -qq -o Dpkg::Use-Pty=0 2>&1 | \
        stdbuf -oL sed -n 's/^Progress: \[\([0-9]*\)%\].*/\1/p' | \
        while read prog; do
            echo -ne "\r${CYAN}${INFO_ICON} [2/2] Installing packages... ${prog}%${RESET}"
        done
        echo -e "\r${GREEN}${CHECK} Packages installed successfully!${RESET}             "
        
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${pkgs[@]}" --quiet
    else
        yum install -y "${pkgs[@]}" -q || pacman -Sy --noconfirm "${pkgs[@]}" >/dev/null 2>&1
    fi
}

clear
echo -e "${BOLD}${MAGENTA}   🚀 SERVER DIAGNOSTIC TOOL${RESET}"
echo -e "${CYAN}   $(date '+%Y-%m-%d %H:%M:%S')${RESET}"

# Встановлення необхідних утиліт
install_pkg iperf3 smartmontools curl lshw dmidecode ethtool > /dev/null

# ================== OS Info ==================
print_header "💻 SYSTEM INFORMATION"
if [ -f /etc/os-release ]; then
    OS_PRETTY=$(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)
    print_row "Operating System" "${YELLOW}${OS_PRETTY}${RESET}"
fi
print_row "Kernel" "$(uname -r)"
print_row "Uptime" "$(uptime -p)"

# ================== CPU & RAM ==================
print_header "${CPU_ICON} CPU & ${RAM_ICON} MEMORY"
cpu_model=$(lscpu | grep "Model name:" | sed 's/Model name:\s*//')
[[ -z "$cpu_model" ]] && cpu_model=$(lscpu | grep "BIOS" | sed 's/BIOS\s*//')
cores=$(lscpu | grep "^CPU(s):" | awk '{print $2}')
print_row "CPU Model" "${YELLOW}$cpu_model${RESET}"
print_row "Cores/Threads" "$cores"

mem_total_mb=$(free -m | awk '/Mem:/ {print $2}')
mem_total_gb=$(printf "%.1f" $(echo "$mem_total_mb/1024" | bc -l))
print_row "Total RAM" "${YELLOW}${mem_total_gb} GB${RESET}"

# ================== Disks ==================
print_header "${DISK_ICON} STORAGE DEVICES"
raid_disks=$(smartctl --scan | grep megaraid || true)

if [ -n "$raid_disks" ]; then
    echo "$raid_disks" | while read -r line; do
        dev=$(echo "$line" | awk '{print $1}')
        num=$(echo "$line" | grep -o 'megaraid,[0-9]\+' | cut -d, -f2)
        model=$(smartctl -i -d megaraid,$num $dev | grep -E "Model|Device Model" | awk -F: '{print $2}' | xargs)
        print_row "RAID Disk $num" "${YELLOW}${model:-Unknown}${RESET}"
    done
else
    # Використовуємо lsblk для красивої таблиці
    lsblk -dn -o NAME,SIZE,MODEL,TYPE | awk '$4=="disk"{printf "  %-10s %-10s %s\n", $1, $2, $3}' | while read -r line; do
        echo -e "  ${YELLOW}→${RESET} $line"
    done
fi

# ================== Users ==================
print_header "👤 ACTIVE USERS (HOME)"
awk -F: '$1 != "root" && $1 != "nobody" && $1 != "nogroup" && $6 ~ /^\/home\// {printf "  %-12s %-15s %s\n", $1, $7, $6}' /etc/passwd | while read -r u s h; do
    echo -e "  ${RED}●${RESET} ${BOLD}$u${RESET} ($s) → $h"
done

# ================== Network ==================
print_header "${NET_ICON} NETWORK & INTERNET"
iface=$(ls /sys/class/net | grep -v lo | head -n 1)
speed=$(ethtool $iface 2>/dev/null | grep "Speed:" | awk '{print $2}')
print_row "Interface" "$iface"
print_row "Max Speed" "${speed:-Unknown}"

IP=$(curl -s --max-time 5 ifconfig.me)
GEO=$(curl -s --max-time 5 ipinfo.io/$IP)
COUNTRY=$(echo "$GEO" | grep country | awk -F\" '{print $4}')
CITY=$(echo "$GEO" | grep city | awk -F\" '{print $4}')

print_row "External IP" "${BOLD}$IP${RESET} ($CITY, $COUNTRY)"

# ================== iperf3 Test ==================
case $COUNTRY in
    "UA") SERVER="iperf.vsys.host" ;;
    "NL") SERVER="iperf-ams.vsys.host" ;;
    "US") SERVER="iperf-us.vsys.host" ;;
    "SG") SERVER="iperf-sin1.vsys.host" ;;
    *) SERVER="" ;;
esac

if [ -n "$SERVER" ]; then
    echo -e "\n${CYAN}🚀 Running Speedtest via $SERVER...${RESET}"
    iperf3 -c $SERVER -P 10 -f m -t 10 2>/dev/null > /tmp/iperf_res &
    iperf_pid=$!

    # Візуальний прогрес-бар
    for i in {1..10}; do
        if ps -p $iperf_pid > /dev/null; then
            echo -ne "\r  ["; for j in $(seq 1 $i); do echo -ne "#"; done; for j in $(seq $i 9); do echo -ne "."; done; echo -ne "] ${i}0%"
            sleep 1
        fi
    done
    wait $iperf_pid
    echo -e "\r  ${GREEN}${CHECK} Test Completed!                      ${RESET}"

    RAW_RESULT=$(grep "\[SUM\].*receiver" /tmp/iperf_res | tail -n1)
    
    if [[ "$RAW_RESULT" =~ ([0-9.]+[[:space:]][MG]bits/sec) ]]; then
        VALUE="${BASH_REMATCH[1]}"
        print_row "iperf3 Bandwidth" "${BOLD}${YELLOW}$VALUE${RESET}"
    else
        echo -e "  ${RED}⚠ iperf3 test failed or timed out${RESET}"
    fi
    rm -f /tmp/iperf_res
else
    echo -e "  ${RED}⚠ No speedtest server for your region${RESET}"
fi

echo -e "\n${BOLD}${MAGENTA}================== END OF REPORT ==================${RESET}\n"
