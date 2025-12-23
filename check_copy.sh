#!/bin/bash

# ================== Colors & Styles (Terminal Safe) ==================
BOLD=$(printf '\033[1m')
BLUE=$(printf '\033[34m')
CYAN=$(printf '\033[36m')
LIME=$(printf '\033[92m')
YELLOW=$(printf '\033[93m')
RED=$(printf '\033[31m')
MAGENTA=$(printf '\033[35m')
WHITE=$(printf '\033[97m')
RESET=$(printf '\033[0m')

# Helper Functions
print_header() {
    printf "\n${BOLD}${CYAN}┌──────────────────────────────────────────────────────────┐${RESET}\n"
    printf "${BOLD}${CYAN}│ %-56s │${RESET}\n" "$1"
    printf "${BOLD}${CYAN}└──────────────────────────────────────────────────────────┘${RESET}\n"
}

print_row() {
    printf "${BLUE}%-20s${RESET} : ${WHITE}%s${RESET}\n" "$1" "$2"
}

# ================== Package Manager (with Progress Bar) ==================
install_pkg() {
    local pkgs=("$@")
    printf "${CYAN}i Preparing system and installing dependencies...${RESET}\n"
    
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1
        (apt-get install -y "${pkgs[@]}" -qq > /dev/null 2>&1) &
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        PM=$(command -v dnf || command -v yum)
        if grep -qi "AlmaLinux" /etc/os-release; then
            [ -f /etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux ] && rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux || true
        fi
        ($PM install -y "${pkgs[@]}" -q > /dev/null 2>&1) &
    elif command -v pacman >/dev/null 2>&1; then
        (pacman -Sy --noconfirm "${pkgs[@]}" > /dev/null 2>&1) &
    fi

    pkg_pid=$!
    for i in {1..10}; do
        if ps -p $pkg_pid > /dev/null; then
            printf "\r  [${LIME}"; for j in $(seq 1 $i); do printf "#"; done; for j in $(seq $i 9); do printf "."; done; printf "${RESET}] ${i}0%%"
            sleep 0.5
        fi
    done
    wait $pkg_pid
    printf "\r  ${LIME}[OK] Components installed successfully!${RESET}               \n"
}

# ================== Main Execution ==================
clear
printf "${BOLD}${MAGENTA}    🚀 SERVER DIAGNOSTICS${RESET}\n"
printf "${CYAN}    Started: $(date '+%Y-%m-%d %H:%M:%S')${RESET}\n"

install_pkg iperf3 smartmontools curl lshw dmidecode ethtool bc

# --- System Info ---
print_header "💻 SYSTEM INFORMATION"
[ -f /etc/os-release ] && print_row "OS" "${YELLOW}$(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)${RESET}"
print_row "Kernel" "$(uname -r)"
print_row "Uptime" "$(uptime -p)"

# --- CPU & RAM ---
print_header "⚙️  CPU & MEMORY"
cpu_model=$(lscpu | grep "Model name:" | sed 's/Model name:\s*//' | head -n1 | xargs)
[[ -z "$cpu_model" ]] && cpu_model=$(lscpu | grep "BIOS" | sed 's/BIOS\s*//' | head -n1 | xargs)
print_row "CPU Model" "${YELLOW}${cpu_model}${RESET}"
print_row "Cores/Threads" "$(lscpu | grep "^CPU(s):" | awk '{print $2}')"

mem_mb=$(free -m | awk '/Mem:/ {print $2}')
print_row "Total RAM" "${YELLOW}$(echo "scale=1; $mem_mb/1024" | bc -l) GB${RESET}"

# --- Users ---
print_header "👤 REGISTERED USERS"
awk -F: '$1 != "root" && $1 != "nobody" && $1 != "nogroup" && $6 ~ /^\/home\// {printf "  '${LIME}'●'${RESET}' User: '${RED}'%-12s'${RESET}' Home: %-15s Shell: %s\n", $1, $6, $7}' /etc/passwd

# --- Disks Smart Scan ---
print_header "💾 STORAGE DEVICES (SMART)"
raid_disks=$(smartctl --scan | grep megaraid || true)

if [ -n "$raid_disks" ]; then
    echo "$raid_disks" | while read -r line; do
        dev=$(echo "$line" | awk '{print $1}')
        num=$(echo "$line" | grep -o 'megaraid,[0-9]\+' | cut -d, -f2)
        printf "\n${YELLOW}=== RAID Physical Disk $num ===${RESET}\n"
        model=$(smartctl -i -d megaraid,$num $dev | grep -E "Model|Device Model" | awk -F: '{print $2}' | xargs)
        health=$(smartctl -H -d megaraid,$num $dev | grep "overall-health" | awk -F: '{print $2}' | xargs)
        printf "Model: %s\n" "$model"
        [[ "$health" == "PASSED" ]] && printf "Health: ${LIME}%s${RESET}\n" "$health" || printf "Health: ${RED}%s${RESET}\n" "$health"
        
        smartctl -A -d megaraid,$num $dev | grep -E "Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable" | while read -r l; do
            [[ $(echo $l | awk '{print $10}') -eq 0 ]] && printf "${LIME}%s${RESET}\n" "$l" || printf "${RED}%s${RESET}\n" "$l"
        done
    done
else
    for disk in $(lsblk -d -n -o NAME,TYPE | awk '$2=="disk"{print $1}'); do
        size=$(lsblk -dn -o SIZE /dev/$disk)
        printf "\n${YELLOW}=== $disk ($size) ===${RESET}\n"
        model=$(smartctl -i /dev/$disk | grep -E "Model|Device Model" | awk -F: '{print $2}' | xargs)
        health=$(smartctl -H /dev/$disk | grep -E "overall-health|result" | awk -F: '{print $2}' | xargs)
        [[ "$health" == "PASSED" || "$health" == "OK" ]] && printf "Health: ${LIME}%s${RESET}\n" "$health" || printf "Health: ${RED}%s${RESET}\n" "$health"
        
        if [[ "$model" =~ "Samsung" && ("$model" =~ "980 PRO" || "$model" =~ "990 PRO") ]]; then
            fw=$(smartctl -i /dev/$disk | grep "Firmware Version" | awk -F: '{print $2}' | xargs)
            [[ "$fw" < "5B2QGXA7" ]] && printf "${RED}Firmware: %s — Update recommended!${RESET}\n" "$fw" || printf "${LIME}Firmware: %s — OK${RESET}\n" "$fw"
        fi
    done
fi

# --- Mount Points Check ---
print_header "📂 MOUNT POINTS & USAGE"
# Виводимо лише sda, nvme, hdd (vda для віртуалок)
lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT,PATH | grep -E "^NAME|sd|nvme|hd|vd" | while read -r line; do
    if [[ "$line" == *"/"* ]]; then
        printf "${LIME}%s${RESET}\n" "$line"
    else
        echo "$line"
    fi
done

# --- Network & iperf3 ---
print_header "🌐 NETWORK & SPEED"
iface=$(ls /sys/class/net | grep -v lo | head -n 1)
IP=$(curl -s --max-time 5 ifconfig.me)
GEO=$(curl -s --max-time 5 ipinfo.io/$IP)
COUNTRY=$(echo "$GEO" | grep country | awk -F\" '{print $4}')
print_row "External IP" "${LIME}$IP${RESET} (${COUNTRY})"

case $COUNTRY in
    "UA") SERVER="iperf.vsys.host" ;;
    "NL") SERVER="iperf-ams.vsys.host" ;;
    "US") SERVER="iperf-us.vsys.host" ;;
    *)    SERVER="iperf.he.net" ;;
esac

if [ -n "$SERVER" ]; then
    printf "\n${CYAN}🚀 Running bandwidth test via $SERVER...${RESET}\n"
    iperf3 -c $SERVER -P 10 -f m -t 10 > /tmp/iperf_res 2>&1 &
    iperf_pid=$!

    for i in {1..10}; do
        if ps -p $iperf_pid > /dev/null; then
            printf "\r  ["; for j in $(seq 1 $i); do printf "#"; done; for j in $(seq $i 9); do printf "."; done; printf "] ${i}0%%"
            sleep 1
        fi
    done
    wait $iperf_pid
    printf "\r  ${LIME}[OK] Test completed!                      \n"

    RAW_DATA=$(grep "receiver" /tmp/iperf_res | tail -n1)
    if [[ "$RAW_DATA" =~ ([0-9.]+)[[:space:]]Mbits/sec ]]; then
        GBITS=$(echo "scale=2; ${BASH_REMATCH[1]} / 1000" | bc -l)
        print_row "Speed" "${YELLOW}${GBITS} Gbits/sec${RESET}"
    fi
    rm -f /tmp/iperf_res
fi

printf "\n${BOLD}${MAGENTA}================== END OF REPORT ==================${RESET}\n\n"
