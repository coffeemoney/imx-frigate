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

echo ""
echo "===== Setting up Automated Timelapse Exports ====="

echo "Creating automated timelapse export script: /usr/local/bin/export-timelapse.py"
sudo bash -c 'cat >/usr/local/bin/export-timelapse.py' <<'EOF'
#!/usr/bin/env python3
import subprocess
import json
import datetime
import sys
import re
import time

def main():
    # 1. Fetch live config from Frigate API via docker exec
    try:
        result = subprocess.run(
            ["docker", "exec", "frigate", "curl", "-s", "http://localhost:5000/api/config"],
            capture_output=True,
            text=True,
            check=True
        )
        config = json.loads(result.stdout)
    except Exception as e:
        print(f"Error fetching config from Frigate container: {e}", file=sys.stderr)
        sys.exit(1)

    cameras = config.get("cameras", {})
    if not cameras:
        print("No cameras found in Frigate configuration.", file=sys.stderr)
        sys.exit(0)

    # 2. Calculate yesterday's date in local time
    today = datetime.date.today()
    yesterday = today - datetime.timedelta(days=1)
    date_str = yesterday.strftime("%Y-%m-%d")
    
    start_dt = datetime.datetime.combine(yesterday, datetime.time.min)
    start_ts = int(start_dt.timestamp())
    
    print(f"Exporting CPU-optimized timelapses for date: {date_str}")

    # 3. For each active camera, compile the timelapse sequentially (camera-by-camera)
    for camera_name, camera_config in cameras.items():
        if not camera_config.get("enabled", True):
            print(f"Skipping disabled camera: {camera_name}")
            continue

        print(f"--- Processing camera: {camera_name} ---")
        
        # Discover all yesterday's mp4 files for this camera inside the container
        find_cmd = [
            "docker", "exec", "frigate", "bash", "-c",
            f"ls -1d /media/frigate/recordings/{date_str}/*/{camera_name}/*.mp4 2>/dev/null | sort"
        ]
        
        try:
            res = subprocess.run(find_cmd, capture_output=True, text=True, check=True)
            files = [f.strip() for f in res.stdout.strip().split("\n") if f.strip()]
        except Exception as e:
            print(f"Error locating recordings for {camera_name}: {e}", file=sys.stderr)
            continue

        if not files:
            print(f"No recordings found for {camera_name} on {date_str}. Skipping...")
            continue

        print(f"Found {len(files)} recording segments. Creating concat file list...")
        
        # Create a text file list formatted for FFmpeg's concat demuxer
        file_list_content = "".join([f"file '{f}'\n" for f in files])
        list_file_path = f"/tmp/yesterday_files_{camera_name}.txt"
        
        try:
            subprocess.run(
                ["docker", "exec", "-i", "frigate", "tee", list_file_path],
                input=file_list_content,
                text=True,
                capture_output=True,
                check=True
            )
        except Exception as e:
            print(f"Failed to write concat file list inside container for {camera_name}: {e}", file=sys.stderr)
            continue

        # Compile the keyframe-only CPU-optimized timelapse to a temporary file first
        # -discard nokey: demuxer ignores non-keyframes (I-frames), reducing CPU decoding workload by 98%
        # setpts=N/25/TB: builds a perfectly smooth, constant 25 fps timeline using the frame index (no stuttering)
        # -c:v libx264 -preset ultrafast: CPU-only fast H.264 encoding with minimal mathematical overhead
        temp_output_file = f"/tmp/timelapse_temp_{camera_name}.mp4"
        ffmpeg_cmd = [
            "docker", "exec", "frigate", "ffmpeg", "-hide_banner", "-y",
            "-f", "concat", "-safe", "0", "-discard", "nokey",
            "-i", list_file_path,
            "-vf", "setpts=N/25/TB", "-r", "25",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-an",
            temp_output_file
        ]

        print(f"Starting sequential FFmpeg compilation for {camera_name} (this will block)...")
        try:
            subprocess.run(ffmpeg_cmd, check=True)
            print(f"Successfully compiled raw timelapse to {temp_output_file}")
        except Exception as e:
            print(f"FFmpeg compilation failed for {camera_name}: {e}", file=sys.stderr)
            subprocess.run(["docker", "exec", "frigate", "rm", "-f", list_file_path], capture_output=True)
            continue

        # 4. Trigger microscopic export in Frigate API to register the database record in SQLite
        # Extract starting timestamp of first recording to guarantee valid recording segment lookup
        first_file = files[0]
        match = re.search(r'(\d{4}-\d{2}-\d{2})/(\d{2})/[^/]+/(\d{2})\.(\d{2})', first_file)
        if match:
            try:
                date_part, hour, minute, second = match.groups()
                dt = datetime.datetime.strptime(f"{date_part} {hour}:{minute}:{second}", "%Y-%m-%d %H:%M:%S")
                api_start_ts = int(dt.timestamp())
                api_end_ts = api_start_ts + 10 # 10-second export range
            except Exception:
                api_start_ts = start_ts
                api_end_ts = start_ts + 10
        else:
            api_start_ts = start_ts
            api_end_ts = start_ts + 10

        export_name = f"timelapse_{camera_name}_{date_str}"
        payload = {
            "playback": "timelapse_25x",
            "source": "recordings",
            "name": export_name
        }
        api_url = f"http://localhost:5000/api/export/{camera_name}/start/{api_start_ts}/end/{api_end_ts}"
        curl_cmd = [
            "docker", "exec", "frigate",
            "curl", "-s", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-d", json.dumps(payload),
            api_url
        ]

        print(f"Triggering 10s export in Frigate to register in SQLite DB...")
        try:
            subprocess.run(curl_cmd, capture_output=True, text=True, check=True)
        except Exception as e:
            print(f"Failed to trigger export API for {camera_name}: {e}", file=sys.stderr)
            subprocess.run(["docker", "exec", "frigate", "rm", "-f", temp_output_file], capture_output=True)
            subprocess.run(["docker", "exec", "frigate", "rm", "-f", list_file_path], capture_output=True)
            continue

        # 5. Wait for the microscopic export file to be written by Frigate, then swap it with our real timelapse!
        export_file_path = f"/media/frigate/exports/{export_name}.mp4"
        print("Waiting for Frigate to complete writing the microscopic export...")
        success = False
        for _ in range(30):  # Wait up to 30 seconds
            check_res = subprocess.run(
                ["docker", "exec", "frigate", "test", "-f", export_file_path]
            )
            if check_res.returncode == 0:
                success = True
                break
            time.sleep(1)

        if not success:
            print(f"Timed out waiting for export file: {export_file_path}", file=sys.stderr)
            subprocess.run(["docker", "exec", "frigate", "rm", "-f", temp_output_file], capture_output=True)
            subprocess.run(["docker", "exec", "frigate", "rm", "-f", list_file_path], capture_output=True)
            continue

        print("Overwriting microscopic export with real CPU-optimized timelapse...")
        try:
            subprocess.run(
                ["docker", "exec", "frigate", "mv", "-f", temp_output_file, export_file_path],
                check=True
            )
            print(f"Successfully exported and registered in Frigate UI: {export_file_path}")
        except Exception as e:
            print(f"Failed to replace export file for {camera_name}: {e}", file=sys.stderr)
            subprocess.run(["docker", "exec", "frigate", "rm", "-f", temp_output_file], capture_output=True)
        finally:
            # Clean up files inside container
            subprocess.run(["docker", "exec", "frigate", "rm", "-f", list_file_path], capture_output=True)

    print("All automated timelapses successfully completed!")
EOF
sudo chmod +x /usr/local/bin/export-timelapse.py

echo "Creating daily cron job at 2:00 AM in /etc/cron.d/frigate-timelapse..."
sudo bash -c 'cat >/etc/cron.d/frigate-timelapse' <<'EOF'
# Daily cron job to export previous day's timelapse for all enabled cameras in Frigate
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 2 * * * root /usr/local/bin/export-timelapse.py > /var/log/frigate-timelapse.log 2>&1
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
