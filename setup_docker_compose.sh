#!/bin/bash

# Print a message
echo "Installing dependencies..."

# Install Docker Compose
echo "Installing Docker Compose..."
sudo curl -L "https://github.com/docker/compose/releases/download/v2.32.1/docker-compose-linux-aarch64" -o /usr/local/bin/docker-compose

# Set execute permissions
echo "Setting execute permissions for Docker Compose..."
sudo chmod +x /usr/local/bin/docker-compose

# Verify installation
echo "Verifying Docker Compose installation..."
docker-compose --version

# Run docker-compose up -d
echo "Running 'docker-compose up -d'..."
docker-compose up -d

# Add entry to /etc/fstab if not exists
echo "Adding mount entry to /etc/fstab..."
FSTAB_ENTRY="/dev/nvme0n1          /media/nvme          auto       defaults              0  0"

if grep -Fxq "$FSTAB_ENTRY" /etc/fstab; then
    echo "Entry already exists in /etc/fstab, skipping..."
else
    echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
    echo "Entry added to /etc/fstab."
fi

# Create /etc/systemd/network/20-wired.network only if it doesn't exist
NETWORK_CONFIG_PATH="/etc/systemd/network/20-wired.network"

if [[ ! -f "$NETWORK_CONFIG_PATH" ]]; then
    echo "Creating $NETWORK_CONFIG_PATH..."
    sudo mkdir -p /etc/systemd/network  # Ensure directory exists

    cat <<EOL | sudo tee "$NETWORK_CONFIG_PATH" > /dev/null
[Match]

Name=eth0

[Network]

Address=192.168.2.1/24
EOL

    sudo chmod 644 "$NETWORK_CONFIG_PATH"
    echo "Network configuration file created."

    # Reload systemd-networkd to apply changes
    echo "Reloading systemd-networkd..."
    sudo systemctl restart systemd-networkd
else
    echo "Network configuration file already exists, skipping..."
fi

# Retrieve and display admin credentials from Frigate logs
echo "Fetching admin credentials from Frigate logs..."
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

echo "Installation and setup completed."
