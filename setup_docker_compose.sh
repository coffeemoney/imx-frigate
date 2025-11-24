#!/bin/bash

echo "===== Installing Dependencies ====="

# Install Docker Compose
echo "Installing Docker Compose..."
sudo curl -L "https://github.com/docker/compose/releases/download/v2.32.1/docker-compose-linux-aarch64" -o /usr/local/bin/docker-compose

echo "Setting execute permissions for Docker Compose..."
sudo chmod +x /usr/local/bin/docker-compose

echo "Verifying Docker Compose installation..."
docker-compose --version || { echo "Docker Compose installation failed!"; exit 1; }

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

echo "===== Adding mount entry to /etc/fstab ====="
FSTAB_ENTRY="/dev/nvme0n1          /media/nvme          auto       defaults              0  0"

if grep -Fxq "$FSTAB_ENTRY" /etc/fstab; then
    echo "Entry already exists in /etc/fstab, skipping..."
else
    echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
    echo "Entry added."
fi

echo "===== Network Configuration ====="
NETWORK_CONFIG_PATH="/etc/systemd/network/20-wired.network"

if [[ ! -f "$NETWORK_CONFIG_PATH" ]]; then
    echo "Creating $NETWORK_CONFIG_PATH..."
    sudo mkdir -p /etc/systemd/network

    cat <<EOL | sudo tee "$NETWORK_CONFIG_PATH" > /dev/null
[Match]
Name=eth0

[Network]
Address=192.168.2.1/24
EOL

    sudo chmod 644 "$NETWORK_CONFIG_PATH"
    echo "Network configuration created."

    echo "Reloading systemd-networkd..."
    sudo systemctl restart systemd-networkd
else
    echo "Network config already exists, skipping..."
fi

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
