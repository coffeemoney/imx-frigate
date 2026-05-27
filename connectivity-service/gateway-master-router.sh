#!/bin/bash

# Configuration Variables
APN="m2minternet"
CELL_INTERFACE="wwan0"
BRIDGE_INTERFACE="br0"
PING_TARGET="1.1.1.1"

echo "========================================================"
echo " Starting i.MX8 IoT Gateway Master Routing Suite"
echo "========================================================"

# --------------------------------------------------
# PHASE 1: Local LAN Network Bridge Configuration
# --------------------------------------------------
# Check if the bridge profile already exists in NetworkManager, if not, build it.
if ! nmcli connection show "$BRIDGE_INTERFACE" >/dev/null 2>&1; then
    echo "[+] Creating NetworkManager Bridge configuration..."
    nmcli connection add type bridge con-name "$BRIDGE_INTERFACE" ifname "$BRIDGE_INTERFACE" ip4 192.168.0.1/24 gw4 192.168.0.1
    nmcli connection add type ethernet con-name br0-eth0 ifname eth0 master "$BRIDGE_INTERFACE"
    nmcli connection add type ethernet con-name br0-eth1 ifname eth1 master "$BRIDGE_INTERFACE"
    nmcli connection up "$BRIDGE_INTERFACE"
else
    echo "[*] NetworkManager Bridge profile already exists."
fi

# --------------------------------------------------
# PHASE 2: Firewall NAT and IP Forwarding Setup
# --------------------------------------------------
echo "[+] Activating Kernel IP Forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward

echo "[+] Flushing old firewall chains & building NAT rules..."
iptables -F FORWARD
iptables -t nat -F POSTROUTING

iptables -A FORWARD -i "$BRIDGE_INTERFACE" -o "$CELL_INTERFACE" -j ACCEPT
iptables -A FORWARD -i "$CELL_INTERFACE" -o "$BRIDGE_INTERFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -A POSTROUTING -o "$CELL_INTERFACE" -j MASQUERADE

# --------------------------------------------------
# PHASE 3: Cellular Connection & Monitoring Loop
# --------------------------------------------------
echo "[*] Entering cellular connection health monitor loop..."

while true; do
    # Verify if internet traffic is moving through the cellular link
    if ! ping -I "$CELL_INTERFACE" -c 1 -W 5 "$PING_TARGET" > /dev/null 2>&1; then
        echo "[!] Cellular link down or missing route. Initializing link..."
        
        # Reset the interface state
        ip link set dev "$CELL_INTERFACE" down
        sleep 1
        
        # Instruct ModemManager to build the mobile connection
        mmcli -m 0 --simple-connect="apn=$APN,ip-type=ipv4" > /dev/null 2>&1
        
        # Bring interface back up physically
        ip link set dev "$CELL_INTERFACE" up
        sleep 2
        
        # Dynamic IP lease negotiation from cellular tower via udhcpc
        echo "[+] Requesting network IP parameters via udhcpc..."
        if udhcpc -i "$CELL_INTERFACE" -n -q > /dev/null 2>&1; then
            echo "[+] Successfully established IP lease and routing tables via udhcpc!"
            
            # Extract carrier DNS information if available and update resolver configuration
            # This ensures your background containers or apps can resolve names cleanly
            DNS_SERVERS=$(mmcli -m 0 --bearer=0 --xml 2>/dev/null | grep -oPm1 '(?<=<dns>)[^<]+')
            if [ ! -z "$DNS_SERVERS" ]; then
                echo "nameserver $(echo $DNS_SERVERS | awk '{print $1}')" > /etc/resolv.conf
                echo "nameserver $(echo $DNS_SERVERS | awk '{print $2}')" >> /etc/resolv.conf
            fi
        else
            echo "[–] udhcpc failed to fetch parameters from the modem hardware. Retrying..."
        fi
    fi
    
    # Check link health every 30 seconds
    sleep 30
done