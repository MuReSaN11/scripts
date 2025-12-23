#!/bin/bash

# Кольори
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"
INFO="\e[36m"

# ================== Функція встановлення з очікуванням lock та прогресом ==================
install_pkg() {
    local pkgs=("$@")
    if command -v apt-get >/dev/null 2>&1; then
        # Перевірка на блокування apt
        while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 ; do
            echo -ne "\r${RED}[WAIT]${RESET} Waiting for other package manager to finish..."
            sleep 2
        done

        apt-get update -qq
        echo -ne "${INFO}[INFO] Installing packages... 0%${RESET}"
        
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" -qq -o Dpkg::Use-Pty=0 2>&1 | \
        stdbuf -oL sed -n 's/^Progress: \[\([0-9]*\)%\].*/\1/p' | \
        while read prog; do
            echo -ne "\r${INFO}[INFO] Installing packages... ${prog}%${RESET}"
        done
        echo -e "\r${YELLOW}[INFO] Installing packages... 100% - Done!${RESET}"
        
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${pkgs[@]}" --quiet
    else
        yum install -y "${pkgs[@]}" -q || pacman -Sy --noconfirm "${pkgs[@]}" >/dev/null 2>&1
    fi
}

# Встановлення необхідного софту
install_pkg iperf3 smartmontools curl lshw dmidecode ethtool

echo -e "\n${INFO}===== SERVER INFORMATION =====${RESET}"

# ================== OS Info ==================
echo -e "${INFO}[OS INFO]${RESET}"
if [ -f /etc/os-release ]; then
    OS_PRETTY=$(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)
    echo -e "${YELLOW}${OS_PRETTY}${RESET}"
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
        echo -e "\n${YELLOW}=== RAID Physical Disk $num ===${RESET}"
        model=$(smartctl -i -d megaraid,$num $dev | grep -E "Model|Device Model" | awk -F: '{print $2}' | xargs)
        echo "Model: ${model:-Virtual/Unknown}"
    done
else
    for disk in $(lsblk -d -n -o NAME,TYPE | awk '$2=="disk"{print $1}'); do
        size=$(lsblk -dn -o SIZE /dev/$disk)
        echo -e "\n${YELLOW}=== $disk ( $size) ===${RESET}"
        model=$(smartctl -i /dev/$disk 2>/dev/null | grep -E "Model|Device Model" | awk -F: '{print $2}' | xargs)
        [[ -z "$model" ]] && model=$(lsblk -dn -o MODEL /dev/$disk | xargs)
        echo "Model: ${model:-Virtual/Generic}"
    done
fi

# ================== Mount Points ==================
echo -e "\n${INFO}[MOUNT POINTS]${RESET}"
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT | grep -E "disk|part" | grep -vE "loop|ram|sr"

# ================== CPU ==================
echo -e "\n${INFO}[CPU]${RESET}"
cpu_model=$(lscpu | grep "Model name:" | sed 's/Model name:\s*//')
[[ -z "$cpu_model" ]] && cpu_model=$(lscpu | grep "BIOS" | sed 's/BIOS\s*//')
echo -e "Model: ${YELLOW}$cpu_model${RESET}"
echo "Cores: $(lscpu | grep "^CPU(s):" | awk '{print $2}')"

# ================== RAM ==================
echo -e "\n${INFO}[RAM]${RESET}"
mem_total_mb=$(free -m | awk '/Mem:/ {print $2}')
mem_total_gb=$(( (mem_total_mb + 512) / 1024 ))
echo -e "Total RAM: ${YELLOW}~${mem_total_gb} GB${RESET}"

# ================== Network ==================
echo -e "\n${INFO}[NETWORK]${RESET}"
iface=$(ls /sys/class/net | grep -v lo | head -n 1)
speed=$(ethtool $iface 2>/dev/null | grep "Speed:" | awk '{print $2}')
echo "Interface: $iface"
echo "Max speed: ${speed:-Unknown}"

# ================== Internet / iperf3 ==================
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
    iperf3 -c $SERVER -P 10 -f m -t 10 2>/dev/null > /tmp/iperf_res &
    iperf_pid=$!

    for i in {10..1}; do
        if ps -p $iperf_pid > /dev/null; then
            echo -ne "\rTesting speed... ${i}s left "
            sleep 1
        fi
    done
    wait $iperf_pid
    echo -e "\rTesting speed... Done!          "

    RAW_RESULT=$(grep "\[SUM\].*receiver" /tmp/iperf_res | tail -n1)
    
    # Підсвітка GBytes у жовтий
    if [[ "$RAW_RESULT" =~ ([0-9.]+[[:space:]]GBytes) ]]; then
        VALUE="${BASH_REMATCH[1]}"
        RESULT=$(echo "$RAW_RESULT" | sed "s/$VALUE/${YELLOW}$VALUE${RESET}/")
    else
        RESULT="$RAW_RESULT"
    fi

    rm -f /tmp/iperf_res
    echo "IP: $IP ($COUNTRY)"
    echo -e "iperf3 result: ${RESULT:-"Test failed"}"
else
    echo "IP: $IP ($COUNTRY)"
    echo "iperf3: No suitable server found"
fi

echo -e "\n${INFO}===== END =====${RESET}"
