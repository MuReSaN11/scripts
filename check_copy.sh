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

# Icons
CHECK="OK"
INFO_ICON="i"

# ================== Helper Functions ==================
print_header() {
    printf "\n${BOLD}${CYAN}┌──────────────────────────────────────────────────────────┐${RESET}\n"
    printf "${BOLD}${CYAN}│ %-56s │${RESET}\n" "$1"
    printf "${BOLD}${CYAN}└──────────────────────────────────────────────────────────┘${RESET}\n"
}

print_row() {
    # Perfect alignment with 20 chars for the label
    printf "${BLUE}%-20s${RESET} : ${WHITE}%s${RESET}\n" "$1" "$2"
}

# ================== Package Installation ==================
install_pkg() {
    local pkgs=("$@")
    if command -v apt-get >/dev/null 2>&1; then
        # Check for apt locks
        while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 ; do
            printf "\r${RED}[WAIT]${RESET} Other package manager is busy..."
            sleep 2
        done

        apt-get update -qq
        printf "${CYAN}${INFO_ICON} Installing dependencies...${RESET}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" -qq -o Dpkg::Use-Pty=0 > /dev/null 2>&1
        printf "\r${LIME}[${CHECK}] System utilities are ready!${RESET}                \n"
        
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${pkgs[@]}" --quiet
    else
        yum install -y "${pkgs[@]}" -q || pacman -Sy --noconfirm "${pkgs[@]}" >/dev/null 2>&1
    fi
}

# ================== Main Script Execution ==================
clear
printf "${BOLD}${MAGENTA}   🚀 SERVER DIAGNOSTICS${RESET}\n"
printf "${CYAN}   Report generated: $(date '+%Y-%m-%d %H:%M:%S')${RESET}\n"

# Install all needed tools including 'bc' for calculations
install_pkg iperf3 smartmontools curl lshw dmidecode ethtool bc

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
# Fixed CPU Model: prioritizes model name and prevents duplicates
cpu_model=$(lscpu | grep "Model name:" | sed 's/Model name:\s*//' | head -n1 | xargs)
[[ -z "$cpu_model" ]] && cpu_model=$(lscpu | grep "BIOS" | sed 's/BIOS\s*//' | head -n1 | xargs)

cores=$(lscpu | grep "^CPU(s):" | awk '{print $2}')
print_row "CPU Model" "${YELLOW}${cpu_model}${RESET}"
print_row "Cores/Threads" "$cores"

mem_total_mb=$(free -m | awk '/Mem:/ {print $2}')
mem_total_gb=$(echo "scale=1; $mem_total_mb/1024" | bc -l)
print_row "Total RAM" "${YELLOW}${mem_total_gb} GB${RESET}"

# ================== Storage (Disks) ==================
print_header "💾 STORAGE DEVICES"
raid_disks=$(smartctl --scan | grep megaraid || true)

if [ -n "$raid_disks" ]; then
    echo "$raid_disks" | while read -r line; do
        dev=$(echo "$line" | awk '{print $1}')
        num=$(echo "$line" | grep -o 'megaraid,[0-9]\+' | cut -d, -f2)
        model=$(smartctl -i -d megaraid,$num $dev | grep -E "Model|Device Model" | awk -F: '{print $2}' | xargs)
        print_row "RAID Disk $num" "${YELLOW}${model:-Unknown}${RESET}"
    done
else
    # Simple list using lsblk for non-RAID systems
    lsblk -dn -o NAME,SIZE,MODEL,TYPE | awk '$4=="disk"{printf "  %s %-10s %-10s %s\n", "'"${LIME}"'●'"${RESET}"'", $1, $2, $3}'
fi

# ================== Network & Internet ==================
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

# ================== iperf3 Bandwidth Test ==================
case $COUNTRY in
    "UA") SERVER="iperf.vsys.host" ;;
    "NL") SERVER="iperf-ams.vsys.host" ;;
    "US") SERVER="iperf-us.vsys.host" ;;
    "SG") SERVER="iperf-sin1.vsys.host" ;;
    *)    SERVER="iperf.he.net" ;;
esac

if [ -n "$SERVER" ]; then
    printf "\n${CYAN}🚀 Running bandwidth test via $SERVER...${RESET}\n"
    
    # Execute test and capture the summary row for the receiver
    RAW_DATA=$(iperf3 -c $SERVER -P 10 -f m -t 10 | grep "receiver" | tail -n1)
    
    if [[ "$RAW_DATA" =~ ([0-9.]+)[[:space:]]Mbits/sec ]]; then
        MBITS=${BASH_REMATCH[1]}
        # Convert Mbits to Gbits (divide by 1000)
        GBITS=$(echo "scale=2; $MBITS / 1000" | bc -l)
        print_row "Speed (iperf3)" "${BOLD}${YELLOW}${GBITS} Gbits/sec${RESET}"
    elif [[ "$RAW_DATA" =~ ([0-9.]+)[[:space:]]Gbits/sec ]]; then
        GBITS=${BASH_REMATCH[1]}
        print_row "Speed (iperf3)" "${BOLD}${YELLOW}${GBITS} Gbits/sec${RESET}"
    else
        printf "  ${RED}! Test failed: server unreachable or busy.${RESET}\n"
    fi
else
    printf "  ${RED}! Speedtest server not available for your region.${RESET}\n"
fi

printf "\n${BOLD}${MAGENTA}================== END OF REPORT ==================${RESET}\n\n"
