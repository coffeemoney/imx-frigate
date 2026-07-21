#!/bin/bash

echo ""
echo "===== WWAN / APN Configuration ====="
read -p "Enter mobile APN for WWAN (e.g., m2minternet): " WWAN_APN

if [[ -z "$WWAN_APN" ]]; then
    echo "Error: APN cannot be empty. Exiting..."
    exit 1
fi

if [[ ! -f "connectivity-service/gateway-master-router.sh" ]]; then
    echo "ERROR: connectivity-service/gateway-master-router.sh not found!"
    exit 1
fi

echo "Updating APN in connectivity-service/gateway-master-router.sh..."

sudo sed -i "s|APN=\"[^\"]*\"|APN=\"$WWAN_APN\"|g" connectivity-service/gateway-master-router.sh

echo "APN successfully set in connectivity-service/gateway-master-router.sh!"
echo ""

echo ""
echo "===== Setting up Gateway Router Systemd Service ====="

# Ensure needed files exist
if [[ ! -f "connectivity-service/gateway-master-router.sh" ]]; then
    echo "ERROR: connectivity-service/gateway-master-router.sh not found!"
    exit 1
fi
if [[ ! -f "connectivity-service/gateway-router.service" ]]; then
    echo "ERROR: connectivity-service/gateway-router.service not found!"
    exit 1
fi

# Clean up legacy start_wwan service if it exists
if systemctl is-enabled start_wwan.timer >/dev/null 2>&1; then
    echo "Disabling legacy start_wwan.timer..."
    sudo systemctl disable --now start_wwan.timer >/dev/null 2>&1
fi
if systemctl is-enabled start_wwan.service >/dev/null 2>&1; then
    echo "Disabling legacy start_wwan.service..."
    sudo systemctl disable --now start_wwan.service >/dev/null 2>&1
fi
if [[ -f "/etc/systemd/system/start_wwan.timer" ]]; then
    echo "Removing legacy start_wwan.timer..."
    sudo rm -f /etc/systemd/system/start_wwan.timer
fi
if [[ -f "/etc/systemd/system/start_wwan.service" ]]; then
    echo "Removing legacy start_wwan.service..."
    sudo rm -f /etc/systemd/system/start_wwan.service
fi
if [[ -f "/usr/local/bin/start_wwan.sh" ]]; then
    echo "Removing legacy start_wwan.sh script..."
    sudo rm -f /usr/local/bin/start_wwan.sh
fi

echo "Copying gateway-master-router.sh to /usr/bin..."
sudo cp connectivity-service/gateway-master-router.sh /usr/bin/gateway-master-router.sh
sudo chmod +x /usr/bin/gateway-master-router.sh

echo "Copying gateway-router.service to /etc/systemd/system..."
sudo cp connectivity-service/gateway-router.service /etc/systemd/system/gateway-router.service

echo "Reloading systemd..."
sudo systemctl daemon-reload

echo "Enabling services..."
sudo systemctl enable --now gateway-router.service
sudo systemctl enable docker.service

echo "Gateway Router service setup complete!"
echo ""


echo "===== Installing Dependencies ====="

# Install Docker Compose
if [[ -f "/usr/local/bin/docker-compose" ]]; then
    echo "Docker Compose already exists. Skipping download..."
else
    echo "Installing Docker Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/download/v2.32.1/docker-compose-linux-aarch64" -o /usr/local/bin/docker-compose

    echo "Setting execute permissions for Docker Compose..."
    sudo chmod +x /usr/local/bin/docker-compose
fi

echo "Verifying Docker Compose installation..."
docker-compose --version || { echo "Docker Compose installation failed!"; exit 1; }

echo ""
echo "===== NVMe / PCIe SSD Storage Setup ====="

MOUNT_POINT="/media/nvme"
sudo mkdir -p "$MOUNT_POINT"

# If not mounted yet but listed in /etc/fstab, try mounting via fstab first
if ! mountpoint -q "$MOUNT_POINT" && grep -qs "$MOUNT_POINT" /etc/fstab; then
    echo "$MOUNT_POINT found in /etc/fstab. Attempting mount..."
    sudo mount "$MOUNT_POINT" 2>/dev/null || true
fi

if mountpoint -q "$MOUNT_POINT"; then
    echo "$MOUNT_POINT is already mounted. Skipping NVMe scanning and format."
    df -h "$MOUNT_POINT"
else
    echo "Scanning for NVMe / PCIe SSD devices..."
    
    PARTITIONS=$(lsblk -ln -o NAME,TYPE 2>/dev/null | awk '$2=="part" && $1~/^nvme/ {print $1}')
    DISKS=$(lsblk -ln -o NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1~/^nvme/ {print $1}')
    
    TARGET_DEV=""
    if [[ -n "$PARTITIONS" ]]; then
        FIRST_PART=$(echo "$PARTITIONS" | head -n1)
        TARGET_DEV="/dev/$FIRST_PART"
    elif [[ -n "$DISKS" ]]; then
        FIRST_DISK=$(echo "$DISKS" | head -n1)
        TARGET_DEV="/dev/$FIRST_DISK"
    fi
    
    if [[ -z "$TARGET_DEV" ]]; then
        echo "Warning: No NVMe / PCIe SSD detected."
        echo "Using directory $MOUNT_POINT on the local filesystem."
    else
        echo "Found NVMe / PCIe SSD device: $TARGET_DEV"
        
        FSTYPE=$(sudo blkid -s TYPE -o value "$TARGET_DEV" 2>/dev/null || true)
        
        if [[ -z "$FSTYPE" ]]; then
            echo "No filesystem found on $TARGET_DEV."
            read -p "Do you want to format $TARGET_DEV as ext4? (y/N): " FORMAT_CONFIRM
            if [[ "$FORMAT_CONFIRM" =~ ^[Yy]$ ]]; then
                echo "Formatting $TARGET_DEV with ext4..."
                sudo mkfs.ext4 -F "$TARGET_DEV"
                FSTYPE="ext4"
            else
                echo "Skipping formatting. NVMe drive will not be mounted."
                TARGET_DEV=""
            fi
        else
            echo "Detected existing filesystem '$FSTYPE' on $TARGET_DEV."
        fi
        
        if [[ -n "$TARGET_DEV" ]]; then
            echo "Mounting $TARGET_DEV to $MOUNT_POINT..."
            sudo mount "$TARGET_DEV" "$MOUNT_POINT"
            
            DEV_UUID=$(sudo blkid -s UUID -o value "$TARGET_DEV" 2>/dev/null || true)
            
            if grep -qs "$MOUNT_POINT" /etc/fstab; then
                echo "$MOUNT_POINT is already configured in /etc/fstab."
            else
                if [[ -n "$DEV_UUID" ]]; then
                    echo "Adding $TARGET_DEV (UUID=$DEV_UUID) to /etc/fstab..."
                    echo "UUID=$DEV_UUID $MOUNT_POINT $FSTYPE defaults,noatime,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
                else
                    echo "Adding $TARGET_DEV to /etc/fstab..."
                    echo "$TARGET_DEV $MOUNT_POINT $FSTYPE defaults,noatime,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
                fi
                echo "/etc/fstab updated successfully."
            fi
        fi
    fi
fi

sudo chmod 777 "$MOUNT_POINT"
echo "NVMe / PCIe SSD setup complete!"
echo ""

echo "===== Frigate Configuration Setup ====="

read -p "Enter retention days: " RETAIN_DAYS
read -p "Enter retention mode (all / motion / active_objects): " RETAIN_MODE
HIGH_CAMERA_RTSP="rtsp://127.0.0.1:554/high_res_rtsp"
LOW_CAMERA_RTSP="rtsp://127.0.0.1:554/low_res_rtsp"

if [[ -z "$RETAIN_DAYS" || -z "$RETAIN_MODE" ]]; then
    echo "Error: One or more required inputs are empty. Exiting..."
    exit 1
fi

CONFIG_FILE="frigate-config/config.yml"
CONFIG_TEMPLATE="frigate-config/config.template.yml"

if [[ -f "$CONFIG_TEMPLATE" ]]; then
    echo "Resetting config.yml from template..."
    cp "$CONFIG_TEMPLATE" "$CONFIG_FILE"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: $CONFIG_FILE not found!"
    exit 1
fi

echo "Updating Frigate config file..."

sudo sed -i "s|<retain days - to input>|$RETAIN_DAYS|g" "$CONFIG_FILE"
sudo sed -i "s|<retain mode - to input>|$RETAIN_MODE|g" "$CONFIG_FILE"
sudo sed -i "s|high_res_rtsp_here|$HIGH_CAMERA_RTSP|g" "$CONFIG_FILE"
sudo sed -i "s|low_res_rtsp_here|$LOW_CAMERA_RTSP|g" "$CONFIG_FILE"

echo "Frigate config updated successfully!"
echo ""

echo "===== Cloudflare Tunnel Setup ====="
echo ""
echo "Please follow these steps to create your Cloudflare Tunnel:"
echo "1. Go to: https://one.dash.cloudflare.com/"
echo "2. Select your account and domain."
echo "3. Navigate to: Access → Tunnels"
echo "4. Click “Create a Tunnel”"
echo "5. Choose a name (e.g., frigate-tunnel)"
echo "6. Choose “Docker” as the install method"
echo "7. Copy ONLY the token from the command:"
echo ""
echo "   cloudflared tunnel run --token <LONG_TOKEN>"
echo ""
echo "8. Paste the <LONG_TOKEN> below."
echo ""

read -p "Enter your Cloudflare Tunnel Token: " CF_TUNNEL_TOKEN

if [[ -z "$CF_TUNNEL_TOKEN" ]]; then
    echo "Error: No token entered. Exiting..."
    exit 1
fi

echo ""
echo "===== Cloudflare Tunnel Token ====="
echo "TOKEN: $CF_TUNNEL_TOKEN"
echo "==================================="
echo ""

# Inject token into docker-compose.yaml
echo "Updating docker-compose.yaml with your Cloudflare Tunnel token..."

DOCKER_COMPOSE_FILE="docker-compose.yaml"
DOCKER_COMPOSE_TEMPLATE="docker-compose.template.yaml"

if [[ -f "$DOCKER_COMPOSE_TEMPLATE" ]]; then
    echo "Resetting docker-compose.yaml from template..."
    cp "$DOCKER_COMPOSE_TEMPLATE" "$DOCKER_COMPOSE_FILE"
fi

if [[ ! -f "$DOCKER_COMPOSE_FILE" ]]; then
    echo "ERROR: $DOCKER_COMPOSE_FILE not found in this directory!"
    exit 1
fi

# Replace placeholder with actual token
sudo sed -i "s|<YOUR_TUNNEL_TOKEN>|$CF_TUNNEL_TOKEN|g" "$DOCKER_COMPOSE_FILE"

echo "Token successfully added to docker-compose.yaml!"
echo ""

# Start Docker Compose
echo "Running 'docker-compose up -d'..."
docker-compose up -d

#Wait for 1 min for frigate to bootup
echo "Waiting for 1 min for frigate to boot"
sleep 60

echo ""
echo "===== Setting up Automated Timelapse Exports ====="

read -p "Enter number of days to keep timelapse exports (e.g., 7): " TIMELAPSE_RETAIN_DAYS

if [[ -z "$TIMELAPSE_RETAIN_DAYS" ]]; then
    echo "No retention period set. Timelapses will NOT be auto-cleaned."
    CLEANUP_FLAG=""
else
    echo "Timelapse exports older than $TIMELAPSE_RETAIN_DAYS days will be auto-deleted."
    CLEANUP_FLAG=" --cleanup-days $TIMELAPSE_RETAIN_DAYS"
fi

echo "Installing automated timelapse export script: /usr/local/bin/export-timelapse.py"
sudo cp frigate-config/export-timelapse.py /usr/local/bin/export-timelapse.py
sudo chmod +x /usr/local/bin/export-timelapse.py

echo "Creating daily cron job at 2:00 AM in /etc/cron.d/frigate-timelapse..."
sudo bash -c "cat >/etc/cron.d/frigate-timelapse" <<EOF
# Daily cron job to export previous day's timelapse for all enabled cameras in Frigate
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 2 * * * root /usr/local/bin/export-timelapse.py${CLEANUP_FLAG} > /var/log/frigate-timelapse.log 2>&1
EOF
sudo chmod 644 /etc/cron.d/frigate-timelapse

echo "Automated timelapse export setup completed!"
echo ""

echo "===== Fetching Frigate Admin Credentials ====="
FRIGATE_LOGS=$(docker logs frigate 2>&1)

ADMIN_USER=$(echo "$FRIGATE_LOGS" | grep -oP '(?<=User: ).*')
ADMIN_PASS=$(echo "$FRIGATE_LOGS" | grep -oP '(?<=Password: ).*')

if [[ -n "$ADMIN_USER" && -n "$ADMIN_PASS" ]]; then
    echo "Admin credentials found:"
    echo "Username: $ADMIN_USER"
    echo "Password: $ADMIN_PASS"
else
    echo "Could not find admin credentials in Frigate logs."
fi

echo ""
echo "===== Installation and Setup Completed Successfully ====="
