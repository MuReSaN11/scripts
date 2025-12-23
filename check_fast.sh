#!/bin/bash

# CPU
CPU_COUNT=$(lscpu | grep "^Socket(s):" | awk '{print $2}')
CPU_MODEL=$(lscpu | grep "Model name:" | sed 's/Model name:[[:space:]]*//; s/(R)//g; s/(TM)//g' | awk '{print $1,$2,$3}')
echo "CPU : $CPU_COUNT x $CPU_MODEL"

# RAM
TOTAL_RAM=$(free -h --giga | awk '/^Mem:/ {print $2}' | sed 's/Gi/Gb/')
RAM_DETAILS=$(sudo dmidecode -t memory 2>/dev/null | grep -E "Size: [0-9]+" | grep -v "No Module Installed" | awk '{count++; sum=$2; unit=$3} END {print "("count"x"sum unit")"}')
echo "RAM : $TOTAL_RAM $RAM_DETAILS"

DISK_INFO=$(lsblk -dnio SIZE,TYPE,TRAN | grep "disk" | awk '{
    type=$3; 
    if(type=="") type="SATA/SAS"; 
    printf "%s %s\n", $1, toupper(type)
}' | sort | uniq -c | awk '{print $1 " x " $2 " " $3}')

echo "DISK: $DISK_INFO"

# NIC
NIC_COUNT=$(lspci | grep -i ethernet | wc -l)
NIC_MODEL=$(lspci | grep -i ethernet | head -n 1 | sed -E 's/.*: //; s/Ethernet Controller //; s/Network Connection //; s/Corporation //; s/Integrated Sensor Hub//' | awk '{print $1,$2,$3}')
INTERFACE=$(ls /sys/class/net | grep -E 'e|n' | head -n 1)
SPEED=$(ethtool $INTERFACE 2>/dev/null | grep "Speed:" | awk '{print $2}' | sed 's/Mb\/s/Mb/; s/Gb\/s/Gb/')
echo "NIC : $NIC_COUNT x $NIC_MODEL $SPEED"
