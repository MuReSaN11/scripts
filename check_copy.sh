#!/bin/bash

# ================== Colors & Styles (Safe Format) ==================
BOLD=$(printf '\033[1m')
BLUE=$(printf '\033[34m')
CYAN=$(printf '\033[36m')
LIME=$(printf '\033[92m')
YELLOW=$(printf '\033[93m')
RED=$(printf '\033[31m')
MAGENTA=$(printf '\033[35m')
WHITE=$(printf '\033[97m')
RESET=$(printf '\033[0m')

# Helper for rows
print_header() {
    printf "\n${BOLD}${CYAN}┌──────────────────────────────────────────────────────────┐${RESET}\n"
    printf "${BOLD}${CYAN}│ %-56s │${RESET}\n" "$1"
    printf "${BOLD}${CYAN}└──────────────────────────────────────────────────────────┘${RESET}\n"
}

print_row() {
    printf "${BLUE}%-20s${RESET} : ${WHITE}%s${RESET}\n" "$1" "$2"
}

# ================== Package Manager (Multi-OS) ==================
install_pkg() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y "$@" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        PM=$(command -v dnf || command -v yum)
        if grep -qi "AlmaLinux" /etc/os-release; then
            if [ -f /etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux ]; then
                rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux || true
            fi
        fi
        $PM install -y "$@" >/dev/null 2>&1
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install "$@" >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm "$@" >/dev/null 2>&1
    else
        printf "${RED}❌ No supported package manager found!${RESET}\n" >&2
        exit 1
    fi
}

# ================== Initialization ==================
clear
printf "${BOLD}${MAGENTA}   🚀 SERVER DIAGNOSTICS${RESET}\n"
printf "${CYAN}   Started: $(date '+%Y-%m-%d %H:%M:%S')${RESET}\n"

install_pkg iperf3 smartmontools curl lshw dmidecode ethtool bc > /dev/null 2>&1

# ================== OS Info ==================
print_header "💻 SYSTEM INFORMATION"
if [ -f /etc/os-release ]; then
    OS_PRETTY=$(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)
    print_row "OS" "${YELLOW}${OS_PRETTY}${RESET}"
fi
print_row "Kernel" "$(uname -r)"
print_row "Uptime" "$(uptime -p)"

# ================== CPU & RAM ==================
print_header "⚙️  CPU & MEMORY"
cpu_model=$(lscpu | grep "Model name:" | sed 's/Model name:\s*//' | head -n1 | xargs)
[[ -z "$cpu_model" ]] && cpu_model=$(lscpu | grep "BIOS" | sed 's/BIOS\s*//' | head -n1 | xargs)
cores=$(lscpu | grep "^CPU(s):" | awk '{print $2}')
print_row "CPU Model" "${YELLOW}${cpu_model}${RESET}"
print_row "Cores/Threads" "$cores"

mem_total_mb=$(free -m | awk '/Mem:/ {print $2}')
mem_total_gb=$(echo "scale=1; $mem_total_mb/1024" | bc -l)
print_row "Total RAM" "${YELLOW}${mem_total_gb} GB${RESET}"

# ================== Users ==================
print_header "👤 REGISTERED USERS"
user_found=false
while IFS=: read -r username _ _ _ _ homedir shell; do
    printf "  ${LIME}●${RESET} User: ${RED}%-12s${RESET} Home: %-15s Shell: %s\n" "$username" "$homedir" "$shell"
    user_found=true
done < <(awk -F: '$1 != "root" && $1 != "nobody" && $1 != "nogroup" && $6 ~ /^\/home\//' /etc/passwd)
[[ "$user_found" == false ]] && printf "  No regular users found.\n"

# ================== Disks ==================
print_header "💾 STORAGE DEVICES"
raid_disks=$(smartctl --scan | grep megaraid || true)

if [ -n "$raid_disks" ]; then
    printf "${CYAN}MegaRAID detected — scanning physical drives...${RESET}\n"
    echo "$raid_disks" | while read -r line; do
        dev=$(echo "$line" | awk '{print $1}')
        num=$(echo "$line" | grep -o 'megaraid,[0-9]\+' | cut -d, -f2)
        
        printf "\n${YELLOW}=== RAID Physical Disk $num ===${RESET}\n"
        model=$(smartctl -i -d megaraid,$num $dev | grep -E "Model|Device Model" | awk -F: '{print $2}' | xargs)
        serial=$(smartctl -i -d megaraid,$num $dev | grep "Serial Number" | awk -F: '{print $2}' | xargs)
        health=$(smartctl -H -d megaraid,$num $dev | grep "overall-health" | awk -F: '{print $2}' | xargs)
        temp=$(smartctl -A -d megaraid,$num $dev | grep -i Temperature | awk '{print $10}' | head -n1)

        printf "Model: %s\nSerial: %s\n" "$model" "$serial"
        [[ "$health" == "PASSED" ]] && printf "Health: ${LIME}%s${RESET}\n" "$health" || printf "Health: ${RED}%s${RESET}\n" "$health"
        [[ -n "$temp" ]] && printf "Temperature: %s°C\n" "$temp"

        smartctl -A -d megaraid,$num $dev | grep -E "Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable" | while read -r l; do
            val=$(echo $l | awk '{print $10}')
            [[ "$val" -eq 0 ]] && printf "${LIME}%s${RESET}\n" "$l" || printf "${RED}%s${RESET}\n" "$l"
        done
    done
else
    for disk in $(lsblk -d -n -o NAME,TYPE | awk '$2=="disk"{print $1}'); do
        type="HDD/SSD"; [[ "$disk" == nvme* ]] && type="NVMe"
        size=$(lsblk -dn -o SIZE /dev/$disk)
        printf "\n${YELLOW}=== $disk ($type) ===${RESET}\n"
        printf "Size: %s\n" "$size"
        
        model=$(smartctl -i /dev/$disk | grep -E "Model|Device Model" | awk -F: '{print $2}' | xargs)
        printf "Model: %s\n" "$model"
        
        health=$(smartctl -H /dev/$disk | grep -E "overall-health|result" | awk -F: '{print $2}' | xargs)
        [[ "$health" == "PASSED" || "$health" == "OK" ]] && printf "Health: ${LIME}%s${RESET}\n" "$health" || printf "Health: ${RED}%s${RESET}\n" "$health"

        if [[ "$type" == "NVMe" ]]; then
            smartctl -a /dev/$disk | grep -E "Reallocated|Current_Pending|Offline_Uncorrectable|Power_On|Temperature" | while read -r l; do
                value=$(echo $l | awk '{print $NF}')
                [[ "$value" =~ ^[0-9]+$ && "$value" -eq 0 ]] && printf "${LIME}%s${RESET}\n" "$l" || printf "${RED}%s${RESET}\n" "$l"
            done
        else
            smartctl -A /dev/$disk | grep -E "Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|Power_On_Hours|Temperature_Celsius" | while read -r l; do
                attr=$(echo $l | awk '{print $2}'); val=$(echo $l | awk '{print $10}')
                if [[ "$attr" =~ Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable ]]; then
                    [[ "$val" -eq 0 ]] && printf "${LIME}%s${RESET}\n" "$l" || printf "${RED}%s${RESET}\n" "$l"
                else
                    echo "$l"
                fi
            done
        fi

        # Firmware check for Samsung
        if [[ "$model" =~ "Samsung" && ("$model" =~ "980 PRO" || "$model" =~ "990 PRO") ]]; then
            printf "${BOLD}${CYAN}[Firmware Check]${RESET} "
            fw=$(smartctl -i /dev/$disk | grep "Firmware Version" | awk -F: '{print $2}' | xargs)
            min_fw="5B2QGXA7"
            if [[ "$fw" < "$min_fw" ]]; then
                printf "${RED}%s — Update recommended!${RESET}\n" "$fw"
            else
                printf "${LIME}%s — Up-to-date${RESET}\n" "$fw"
            fi
        fi
    done
fi

# ================== Network ==================
print_header "🌐 NETWORK & INTERNET"
iface=$(ls /sys/class/net | grep -v lo | head -n 1)
speed_raw=$(ethtool $iface 2>/dev/null | grep "Speed:" | awk '{print $2}')
print_row "Interface" "$iface"
print_row "Max Speed" "${speed_raw:-Unknown}"

IP=$(curl -s --max-time 5 ifconfig.me)
GEO=$(curl -s --max-time 5 ipinfo.io/$IP)
COUNTRY=$(echo "$GEO" | grep country | awk -F\" '{print $4}')
CITY=$(echo "$GEO" | grep city | awk -F\" '{print $4}')
print_row "External IP" "${BOLD}${LIME}$IP${RESET} ($CITY, $COUNTRY)"

case $COUNTRY in
    "UA") SERVER="iperf.vsys.host" ;;
    "NL") SERVER="iperf-ams.vsys.host" ;;
    "US") SERVER="iperf-us.vsys.host" ;;
    *)    SERVER="iperf.he.net" ;;
esac

if [ -n "$SERVER" ]; then
    printf "\n${CYAN}🚀 Running iperf3 via $SERVER...${RESET}\n"
    RAW_DATA=$(iperf3 -c $SERVER -P 10 -f m -t 10 | grep "receiver" | tail -n1)
    if [[ "$RAW_DATA" =~ ([0-9.]+)[[:space:]]Mbits/sec ]]; then
        GBITS=$(echo "scale=2; ${BASH_REMATCH[1]} / 1000" | bc -l)
        print_row "Speed (iperf3)" "${BOLD}${YELLOW}${GBITS} Gbits/sec${RESET}"
    elif [[ "$RAW_DATA" =~ ([0-9.]+)[[:space:]]Gbits/sec ]]; then
        print_row "Speed (iperf3)" "${BOLD}${YELLOW}${BASH_REMATCH[1]} Gbits/sec${RESET}"
    else
        printf "  ${RED}! Test failed or server busy.${RESET}\n"
    fi
fi

printf "\n${BOLD}${MAGENTA}================== END OF REPORT ==================${RESET}\n\n"
