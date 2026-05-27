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
echo "===== Frigate Configuration Setup ====="

read -p "Enter retention days: " RETAIN_DAYS
read -p "Enter retention mode (all / motion / active_objects): " RETAIN_MODE
read -p "Enter camera High Resolution RTSP stream URL (rtsp://...): " HIGH_CAMERA_RTSP
read -p "Enter camera Lower Resolution RTSP stream URL (rtsp://...): " LOW_CAMERA_RTSP

if [[ -z "$RETAIN_DAYS" || -z "$RETAIN_MODE" || -z "$HIGH_CAMERA_RTSP" || -z "$LOW_CAMERA_RTSP" ]]; then
    echo "Error: One or more required inputs are empty. Exiting..."
    exit 1
fi

CONFIG_FILE="frigate-config/config.yml"

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

if [[ ! -f "docker-compose.yaml" ]]; then
    echo "ERROR: docker-compose.yaml not found in this directory!"
    exit 1
fi

# Replace placeholder with actual token
sudo sed -i "s|<YOUR_TUNNEL_TOKEN>|$CF_TUNNEL_TOKEN|g" docker-compose.yaml

echo "Token successfully added to docker-compose.yaml!"
echo ""

# Start Docker Compose
echo "Running 'docker-compose up -d'..."
docker-compose up -d

#Wait for 1 min for frigate to bootup
echo "Waiting for 1 min for frigate to boot"
sleep 60

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
