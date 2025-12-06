#!/bin/bash

# Check SIM active state
SIM_ACTIVE=$(mmcli -i 0 --output-keyvalue 2>/dev/null \
    | grep "^sim.properties.active" \
    | awk -F':' '{gsub(/ /, "", $2); print $2}')

if [[ "$SIM_ACTIVE" != "yes" ]]; then
    echo "No SIM detected or SIM inactive. Exiting."
    exit 1
fi

echo "SIM detected."

# Check if modem is already connected
MODEM_STATE=$(mmcli -m 0 --output-keyvalue 2>/dev/null \
    | grep "^modem.generic.state[[:space:]]*:" \
    | awk -F': ' '{print $2}')

if [[ "$MODEM_STATE" == "connected" ]]; then
    echo "Modem already connected. Nothing to do."
    exit 0
fi

echo "Modem not connected. Bringing WWAN interface up..."

# Bring interface down
ip link set wwan0 down

# Enable raw IP mode
echo 'Y' | tee /sys/class/net/wwan0/qmi/raw_ip >/dev/null

# Bring interface up
ip link set wwan0 up

# Attempt connection with APN (setup.sh will replace placeholder)
mmcli -m 0 --simple-connect="apn=<APN_PLACEHOLDER>"

# Get IP
udhcpc -i wwan0

echo "WWAN connection process complete."
exit 0
