#!/bin/bash

# Check if SIM is present
SIM_PATH=$(mmcli -m 0 --output-keyvalue | grep modem.generic.sim | awk -F= '{print $2}')

if [[ -z "$SIM_PATH" || "$SIM_PATH" == "none" ]]; then
    echo "No SIM detected. Exiting."
    exit 1
fi

echo "SIM detected: $SIM_PATH"

# Bring interface down
ip link set wwan0 down

# Enable raw IP mode
echo 'Y' | tee /sys/class/net/wwan0/qmi/raw_ip

# Bring interface up
ip link set wwan0 up

# Singtel Prepaid APN
mmcli -m 0 --simple-connect="apn=m2minternet"

# Obtain IP via dhcp
udhcpc -i wwan0

exit 0
