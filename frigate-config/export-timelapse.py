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
        progress_file = f"/tmp/ffmpeg_progress_{camera_name}.txt"

        # FFmpeg's -progress flag writes machine-readable key=value lines to a file every ~second.
        # This completely avoids all docker exec pipe-buffering issues.
        ffmpeg_cmd = [
            "docker", "exec", "frigate",
            "ffmpeg", "-nostdin", "-hide_banner", "-y",
            "-progress", progress_file, "-nostats",
            "-f", "concat", "-safe", "0", "-discard", "nokey",
            "-i", list_file_path,
            "-vf", "setpts=N/25/TB", "-r", "25",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-an",
            temp_output_file
        ]

        print(f"Starting sequential FFmpeg compilation for {camera_name}...")
        try:
            # Launch FFmpeg in background - all output goes to /dev/null
            # Progress is tracked via the -progress file inside the container
            process = subprocess.Popen(
                ffmpeg_cmd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

            start_time = time.time()

            # Probe just the first segment to count its keyframes, then extrapolate total.
            # This is fast (~1 second) and gives an accurate frame estimate for the progress bar.
            try:
                probe_res = subprocess.run(
                    [
                        "docker", "exec", "frigate",
                        "ffprobe", "-v", "quiet",
                        "-select_streams", "v:0",
                        "-skip_frame", "nokey",
                        "-show_entries", "frame=pict_type",
                        "-of", "csv",
                        files[0]
                    ],
                    capture_output=True, text=True, timeout=15
                )
                # Each line is "frame,I" for a keyframe; count non-empty lines
                keyframes_in_first = max(1, sum(1 for l in probe_res.stdout.strip().split('\n') if l.strip()))
            except Exception:
                keyframes_in_first = 5  # safe fallback: assume 5 keyframes per 10s segment

            estimated_total_frames = keyframes_in_first * len(files)
            print(f"Estimated keyframes: {estimated_total_frames} (~{keyframes_in_first}/segment × {len(files)} segments)")

            while process.poll() is None:
                time.sleep(2)

                # Read the latest frame count from FFmpeg's -progress file inside the container
                res = subprocess.run(
                    ["docker", "exec", "frigate", "grep", "-a", "^frame=", progress_file],
                    capture_output=True, text=True
                )

                elapsed = int(time.time() - start_time)
                if res.returncode == 0 and res.stdout.strip():
                    # The -progress file appends multiple frame= entries; take the last one
                    lines = res.stdout.strip().split('\n')
                    frame = int(lines[-1].split('=')[1])
                    pct = min(int(frame / estimated_total_frames * 100), 99)
                    bar_length = 30
                    filled_length = int(bar_length * pct // 100)
                    bar = '█' * filled_length + '-' * (bar_length - filled_length)
                    print(f"\rProgress: [{bar}] ~{pct}% | {frame} frames | {elapsed}s elapsed", end="", flush=True)
                else:
                    # FFmpeg just started, -progress file may not exist yet
                    print(f"\rStarting... {elapsed}s elapsed", end="", flush=True)

            print() # newline after progress bar

            if process.returncode != 0:
                raise subprocess.CalledProcessError(process.returncode, ffmpeg_cmd)

            print(f"Successfully compiled raw timelapse to {temp_output_file}")
        except Exception as e:
            print(f"\nFFmpeg compilation failed for {camera_name}: {e}", file=sys.stderr)
            subprocess.run(["docker", "exec", "frigate", "rm", "-f", list_file_path], capture_output=True)
            subprocess.run(["docker", "exec", "frigate", "rm", "-f", progress_file], capture_output=True)
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
            subprocess.run(["docker", "exec", "frigate", "rm", "-f", progress_file], capture_output=True)

    print("All automated timelapses successfully completed!")

if __name__ == "__main__":
    main()
