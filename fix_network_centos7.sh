#!/bin/bash

# Check for root privileges
if [ "$EUID" -ne 0 ]; then 
  echo "Error: Please run as root."
  exit 1
fi

PRIMARY_IFACE=$1

# Check if primary interface argument is provided
if [ -z "$PRIMARY_IFACE" ]; then
    echo "Usage: $0 <primary_interface>"
    echo "Example: $0 eth0"
    exit 1
fi

# Validate if the primary interface exists
if ! ip link show "$PRIMARY_IFACE" > /dev/null 2>&1; then
    echo "Error: Interface $PRIMARY_IFACE not found."
    exit 1
fi

echo "--- Starting Universal Network Fix ---"
echo "Primary Interface: $PRIMARY_IFACE (will keep DEFROUTE=yes)"

# 1. Global sysctl configuration to disable Reverse Path Filtering
# This prevents the kernel from dropping packets arriving on secondary interfaces
echo "Applying sysctl tweaks..."
cat <<EOF > /etc/sysctl.d/99-multihome-routing.conf
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF

# 2. Get a list of all Ethernet interfaces except 'lo' and the primary one
INTERFACES=$(ls /sys/class/net | grep -vE "lo|$PRIMARY_IFACE")

for IFACE in $INTERFACES; do
    echo "Processing secondary interface: $IFACE"

    # Get IP address and Network prefix
    IP_ADDR=$(ip -4 addr show "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    
    if [ -z "$IP_ADDR" ]; then
        echo "Skipping $IFACE: No IP address assigned."
        continue
    fi

    # Determine Network and Gateway (assuming .1 of the current subnet if not found)
    PREFIX=$(ip -4 addr show "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | cut -d/ -f2)
    NETWORK=$(echo $IP_ADDR | cut -d. -f1-3).0
    GATEWAY=$(grep 'GATEWAY' /etc/sysconfig/network-scripts/ifcfg-$IFACE | cut -d= -f2 | tr -d '"')
    
    if [ -z "$GATEWAY" ]; then
        GATEWAY="$(echo $IP_ADDR | cut -d. -f1-3).1"
    fi

    # Define Routing Table Name and ID
    TABLE_ID=$((100 + $(echo $IFACE | grep -o '[0-9]\+' | head -n1 || echo 99)))
    TABLE_NAME="${IFACE}_table"

    # 3. Add routing table to /etc/iproute2/rt_tables if not exists
    if ! grep -q "$TABLE_NAME" /etc/iproute2/rt_tables; then
        echo "$TABLE_ID $TABLE_NAME" >> /etc/iproute2/rt_tables
    fi

    # 4. Update ifcfg file: Disable DEFROUTE to prevent gateway conflicts
    # Only the Primary interface should have DEFROUTE=yes
    sed -i 's/DEFROUTE=yes/DEFROUTE=no/g' /etc/sysconfig/network-scripts/ifcfg-$IFACE
    if ! grep -q "DEFROUTE" /etc/sysconfig/network-scripts/ifcfg-$IFACE; then
        echo "DEFROUTE=no" >> /etc/sysconfig/network-scripts/ifcfg-$IFACE
    fi

    # 5. Create static route and rule files for CentOS network service
    # Route: Tells packets in this table to use the specific interface gateway
    cat <<EOF > /etc/sysconfig/network-scripts/route-$IFACE
default via $GATEWAY dev $IFACE table $TABLE_NAME
$NETWORK/$PREFIX dev $IFACE src $IP_ADDR table $TABLE_NAME
EOF

    # Rule: Tells the system to use the table if the source IP matches this interface
    cat <<EOF > /etc/sysconfig/network-scripts/rule-$IFACE
from $IP_ADDR lookup $TABLE_NAME
EOF

    # Add interface specific sysctl tweak
    echo "net.ipv4.conf.$IFACE.rp_filter=0" >> /etc/sysctl.d/99-multihome-routing.conf
done

# 6. Apply sysctl changes and restart network
sysctl -p /etc/sysctl.d/99-multihome-routing.conf > /dev/null
echo "Restarting network service..."
systemctl restart network

echo "--- Fix Applied Successfully ---"
echo "Primary: $PRIMARY_IFACE"
echo "Secondaries configured: $INTERFACES"
