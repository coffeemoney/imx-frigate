#!/bin/bash

echo ""
echo "===== WWAN / APN Configuration ====="
read -p "Enter mobile APN for WWAN (e.g., m2minternet): " WWAN_APN

if [[ -z "$WWAN_APN" ]]; then
    echo "Error: APN cannot be empty. Exiting..."
    exit 1
fi

if [[ ! -f "start_wwan.sh" ]]; then
    echo "ERROR: start_wwan.sh not found!"
    exit 1
fi

echo "Updating APN in start_wwan.sh..."

sudo sed -i "s|apn=[^\"]*|apn=$WWAN_APN|g" start_wwan.sh

echo "APN successfully set in start_wwan.sh!"
echo ""

echo ""
echo "===== Setting up WWAN Systemd Service ====="

# Ensure start_wwan.sh exists
if [[ ! -f "start_wwan.sh" ]]; then
    echo "ERROR: start_wwan.sh not found in this directory!"
    exit 1
fi

echo "Moving start_wwan.sh to /usr/local/bin..."
sudo mv start_wwan.sh /usr/local/bin/start_wwan.sh
sudo chmod +x /usr/local/bin/start_wwan.sh

echo "Creating systemd service: /etc/systemd/system/start_wwan.service"

sudo bash -c 'cat >/etc/systemd/system/start_wwan.service' <<'EOF'
[Unit]
Description=Start WWAN interface when SIM is detected
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/start_wwan.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "Creating systemd timer: /etc/systemd/system/start_wwan.timer"

sudo bash -c 'cat >/etc/systemd/system/start_wwan.timer' <<'EOF'
[Unit]
Description=Retry WWAN startup every 30 seconds until SIM is detected

[Timer]
OnBootSec=15s
OnUnitActiveSec=30s
Unit=start_wwan.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo "Reloading systemd..."
sudo systemctl daemon-reload

echo "Enabling services..."
sudo systemctl enable start_wwan.service
sudo systemctl enable --now start_wwan.timer

echo "WWAN service + timer setup complete!"
echo ""


echo "===== Installing Dependencies ====="

# Install Docker Compose
echo "Installing Docker Compose..."
sudo curl -L "https://github.com/docker/compose/releases/download/v2.32.1/docker-compose-linux-aarch64" -o /usr/local/bin/docker-compose

echo "Setting execute permissions for Docker Compose..."
sudo chmod +x /usr/local/bin/docker-compose

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
