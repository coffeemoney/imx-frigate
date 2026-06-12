#!/usr/bin/env python3
import subprocess
import json
import datetime
import sys
import re
import time
import os
import glob
import shutil

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Export CPU/Hardware-optimized timelapses.")
    parser.add_argument("--hour", type=str, default=None, help="Filter to a specific hour (00-23) for quick testing.")
    parser.add_argument("--date", type=str, default=None, help="Process a specific date (YYYY-MM-DD) instead of yesterday.")
    parser.add_argument("--cleanup-days", type=int, default=None,
                        help="Delete timelapse exports older than N days. Can be combined with export or used standalone.")
    parser.add_argument("--cleanup-only", action="store_true",
                        help="Only run cleanup (skip timelapse generation). Requires --cleanup-days.")
    args = parser.parse_args()

    if args.cleanup_only and args.cleanup_days is None:
        print("Error: --cleanup-only requires --cleanup-days", file=sys.stderr)
        sys.exit(1)

    # Configuration Constants
    SEGMENT_STRIDE = 6  # Process every N-th segment to speed up compilation. 1 = process all segments.
    OUTPUT_FPS = 25     # Target framerate for the timelapse video.
    NVME_TMP_DIR = "/media/nvme/tmp"

    # Ensure tmp directory exists on NVMe
    try:
        os.makedirs(NVME_TMP_DIR, exist_ok=True)
    except Exception as e:
        print(f"Error creating temp directory {NVME_TMP_DIR}: {e}", file=sys.stderr)
        sys.exit(1)

    # 1. Fetch live config from Frigate API via docker exec (only container call needed to get active config)
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

    # 2. Calculate target date in local time
    if args.date:
        date_str = args.date
        try:
            target_date = datetime.datetime.strptime(date_str, "%Y-%m-%d").date()
        except ValueError:
            print(f"Error: Date format must be YYYY-MM-DD, got '{date_str}'", file=sys.stderr)
            sys.exit(1)
    else:
        today = datetime.date.today()
        target_date = today - datetime.timedelta(days=1)
        date_str = target_date.strftime("%Y-%m-%d")
    
    start_dt = datetime.datetime.combine(target_date, datetime.time.min)
    start_ts = int(start_dt.timestamp())
    
    msg_suffix = f" (Hour: {args.hour})" if args.hour else ""
    print(f"Exporting CPU/HW-optimized timelapses for date: {date_str}{msg_suffix}")

    # 3. For each active camera, compile the timelapse sequentially (camera-by-camera)
    if args.cleanup_only:
        return  # Skip generation, cleanup runs after main() returns below

    for camera_name, camera_config in cameras.items():
        if not camera_config.get("enabled", True):
            print(f"Skipping disabled camera: {camera_name}")
            continue

        print(f"--- Processing camera: {camera_name} ---")
        
        # Discover yesterday's mp4 files for this camera directly on the host NVMe mount
        hour_pattern = f"{int(args.hour):02d}" if args.hour else "*"
        search_pattern = f"/media/nvme/recordings/{date_str}/{hour_pattern}/{camera_name}/*.mp4"
        files = sorted(glob.glob(search_pattern))

        if not files:
            print(f"No recordings found for {camera_name} on {date_str}. Skipping...")
            continue

        # Subsample segments to speed up compilation
        if SEGMENT_STRIDE > 1:
            processed_files = files[::SEGMENT_STRIDE]
            print(f"Found {len(files)} recording segments. Subsampling (stride={SEGMENT_STRIDE}) to {len(processed_files)} segments...")
        else:
            processed_files = files
            print(f"Found {len(files)} recording segments.")

        print("Creating concat file list...")
        # Create a text file list formatted for FFmpeg's concat demuxer
        file_list_content = "".join([f"file '{f}'\n" for f in processed_files])
        list_file_path = f"{NVME_TMP_DIR}/yesterday_files_{camera_name}.txt"
        
        try:
            with open(list_file_path, "w") as f:
                f.write(file_list_content)
        except Exception as e:
            print(f"Failed to write concat file list on host for {camera_name}: {e}", file=sys.stderr)
            continue

        # Compile the keyframe-only timelapse to a temporary file on NVMe
        # Uses -c:v copy (no decode/encode) + filter_units BSF to strip non-keyframe NAL units
        # at the bitstream level, then setts BSF to assign sequential timestamps for smooth playback
        temp_output_file = f"{NVME_TMP_DIR}/timelapse_temp_{camera_name}.mp4"
        progress_file = f"{NVME_TMP_DIR}/ffmpeg_progress_{camera_name}.txt"
        stderr_file = f"{NVME_TMP_DIR}/ffmpeg_stderr_{camera_name}.txt"

        # Clean up any stale files
        for fpath in (temp_output_file, progress_file, stderr_file):
            if os.path.exists(fpath):
                try:
                    os.remove(fpath)
                except Exception:
                    pass

        # Detect codec of the first segment to determine which NAL unit types are keyframes
        try:
            codec_res = subprocess.run(
                ["/usr/bin/ffprobe", "-v", "quiet", "-select_streams", "v:0",
                 "-show_entries", "stream=codec_name", "-of", "csv=p=0",
                 processed_files[0]],
                capture_output=True, text=True, timeout=10
            )
            codec_name = codec_res.stdout.strip().lower()
        except Exception:
            codec_name = "h264"  # safe fallback

        if codec_name in ("hevc", "h265"):
            # HEVC NAL types: IDR_W_RADL(19), IDR_N_LP(20), CRA_NUT(21), VPS(32), SPS(33), PPS(34)
            keyframe_bsf = "filter_units=pass_types=19|20|21|32|33|34"
        else:
            # H.264 NAL types: IDR(5), SPS(7), PPS(8)
            keyframe_bsf = "filter_units=pass_types=5|7|8"

        print(f"Detected codec: {codec_name} | BSF: {keyframe_bsf}")

        # Run host ffmpeg in copy-only mode (no decoding/encoding, split-second speed, 0% CPU)
        # filter_units strips non-keyframe packets, setts rewrites timestamps sequentially
        ffmpeg_cmd = [
            "/usr/bin/ffmpeg", "-nostdin", "-hide_banner", "-y",
            "-progress", progress_file, "-nostats",
            "-f", "concat", "-safe", "0",
            "-i", list_file_path,
            "-c:v", "copy", "-an",
            "-bsf:v", f"{keyframe_bsf},setts=pts=N/{OUTPUT_FPS}/TB:dts=N/{OUTPUT_FPS}/TB",
            temp_output_file
        ]

        print(f"Starting sequential FFmpeg HW compilation on host for {camera_name}...")
        try:
            # Launch FFmpeg on host in background, redirecting stderr to a debug file
            stderr_f = open(stderr_file, "w")
            process = subprocess.Popen(
                ffmpeg_cmd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=stderr_f,
            )

            start_time = time.time()

            # Probe just the first segment to count its keyframes, then extrapolate total.
            # Runs directly on host and is fast (~1 second).
            try:
                probe_res = subprocess.run(
                    [
                        "/usr/bin/ffprobe", "-v", "quiet",
                        "-select_streams", "v:0",
                        "-skip_frame", "nokey",
                        "-show_entries", "frame=pict_type",
                        "-of", "csv",
                        processed_files[0]
                    ],
                    capture_output=True, text=True, timeout=15
                )
                # Each line is "frame,I" for a keyframe; count non-empty lines
                keyframes_in_first = max(1, sum(1 for l in probe_res.stdout.strip().split('\n') if l.strip()))
            except Exception:
                keyframes_in_first = 5  # safe fallback: assume 5 keyframes per 10s segment

            estimated_total_frames = keyframes_in_first * len(processed_files)
            print(f"Estimated keyframes: {estimated_total_frames} (~{keyframes_in_first}/segment × {len(processed_files)} segments)")

            while process.poll() is None:
                time.sleep(2)

                # Read progress directly from host file
                if os.path.exists(progress_file):
                    try:
                        with open(progress_file, "r", errors="ignore") as pf:
                            content = pf.read().strip()
                        lines = [l for l in content.split('\n') if l.startswith("frame=")]
                        if lines:
                            frame = int(lines[-1].split('=')[1])
                            pct = min(int(frame / estimated_total_frames * 100), 99)
                            bar_length = 30
                            filled_length = int(bar_length * pct // 100)
                            bar = '█' * filled_length + '-' * (bar_length - filled_length)
                            elapsed = int(time.time() - start_time)
                            print(f"\rProgress: [{bar}] ~{pct}% | {frame} frames | {elapsed}s elapsed", end="", flush=True)
                    except Exception:
                        pass
                else:
                    elapsed = int(time.time() - start_time)
                    print(f"\rStarting... {elapsed}s elapsed", end="", flush=True)

            print() # newline after progress bar
            stderr_f.close()

            if process.returncode != 0:
                # Read and print the FFmpeg stderr log to reveal the exact error
                if os.path.exists(stderr_file):
                    with open(stderr_file, "r", errors="ignore") as f:
                        ffmpeg_error_output = f.read()
                    print(f"FFmpeg error output:\n{ffmpeg_error_output}", file=sys.stderr)
                raise subprocess.CalledProcessError(process.returncode, ffmpeg_cmd)

            print(f"Successfully compiled raw timelapse to {temp_output_file}")
        except Exception as e:
            print(f"\nFFmpeg compilation failed for {camera_name}: {e}", file=sys.stderr)
            for fpath in (list_file_path, progress_file, stderr_file):
                if os.path.exists(fpath):
                    try:
                        os.remove(fpath)
                    except Exception:
                        pass
            continue

        # 4. Trigger microscopic export in Frigate API to register the database record in SQLite
        # Extract starting timestamp of first recording to guarantee valid recording segment lookup
        first_file = processed_files[0]
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
        export_id = None
        try:
            res = subprocess.run(curl_cmd, capture_output=True, text=True, check=True)
            # Safe JSON parsing
            try:
                response_json = json.loads(res.stdout.strip())
                export_id = response_json.get("export_id")
            except Exception:
                # Regex fallback in case of non-clean JSON strings (e.g. metadata prefixing)
                match_id = re.search(r'"export_id"\s*:\s*"([^"]+)"', res.stdout)
                if match_id:
                    export_id = match_id.group(1)
            
            if not export_id:
                print(f"Warning: Frigate API did not return an export_id. Fallback naming will be used.", file=sys.stderr)
                export_id = f"timelapse_{camera_name}_{date_str}"
        except Exception as e:
            print(f"Failed to trigger export API for {camera_name}: {e}", file=sys.stderr)
            for fpath in (temp_output_file, list_file_path):
                if os.path.exists(fpath):
                    try:
                        os.remove(fpath)
                    except Exception:
                        pass
            continue

        # 5. Wait for the microscopic export file to be written by Frigate, then swap it with our real timelapse!
        export_file_path = f"/media/nvme/exports/{export_id}.mp4"
        print(f"Waiting for Frigate to complete writing the microscopic export: {export_id}.mp4...")
        success = False
        for _ in range(30):  # Wait up to 30 seconds
            if os.path.exists(export_file_path):
                success = True
                break
            time.sleep(1)

        if not success:
            print(f"Timed out waiting for export file: {export_file_path}", file=sys.stderr)
            for fpath in (temp_output_file, list_file_path):
                if os.path.exists(fpath):
                    try:
                        os.remove(fpath)
                    except Exception:
                        pass
            continue

        print("Overwriting microscopic export with real CPU-optimized timelapse...")
        try:
            shutil.move(temp_output_file, export_file_path)
            print(f"Successfully exported and registered in Frigate UI: {export_file_path}")
        except Exception as e:
            print(f"Failed to replace export file for {camera_name}: {e}", file=sys.stderr)
            if os.path.exists(temp_output_file):
                try:
                    os.remove(temp_output_file)
                except Exception:
                    pass
        finally:
            # Clean up files on host
            for fpath in (list_file_path, progress_file, stderr_file):
                if os.path.exists(fpath):
                    try:
                        os.remove(fpath)
                    except Exception:
                        pass

    if not args.cleanup_only:
        print("All automated timelapses successfully completed!")

    # Run cleanup if --cleanup-days was specified
    if args.cleanup_days is not None:
        cleanup_old_timelapses(args.cleanup_days)


def cleanup_old_timelapses(max_age_days):
    """Delete timelapse exports older than max_age_days via the Frigate API."""
    print(f"\n--- Cleaning up timelapse exports older than {max_age_days} days ---")

    cutoff_date = datetime.date.today() - datetime.timedelta(days=max_age_days)
    print(f"Cutoff date: {cutoff_date} (exports on or before this date will be deleted)")

    # Fetch all exports from Frigate API
    try:
        result = subprocess.run(
            ["docker", "exec", "frigate", "curl", "-s", "http://localhost:5000/api/exports/"],
            capture_output=True, text=True, check=True
        )
        exports = json.loads(result.stdout)
    except Exception as e:
        print(f"Error fetching exports from Frigate API: {e}", file=sys.stderr)
        return

    if not isinstance(exports, list):
        print(f"Unexpected API response format: {type(exports)}", file=sys.stderr)
        return

    # Filter for timelapse exports and check their date
    # Expected name pattern: timelapse_{camera}_{YYYY-MM-DD}
    timelapse_pattern = re.compile(r'^timelapse_.+_(\d{4}-\d{2}-\d{2})$')
    deleted_count = 0
    skipped_count = 0

    for export in exports:
        export_name = export.get("name", "")
        export_id = export.get("id", "")

        match = timelapse_pattern.match(export_name)
        if not match:
            continue  # Not a timelapse export, skip

        try:
            export_date = datetime.datetime.strptime(match.group(1), "%Y-%m-%d").date()
        except ValueError:
            continue

        if export_date > cutoff_date:
            skipped_count += 1
            continue  # Still within retention period

        # Delete via Frigate API (removes both DB record and file)
        print(f"Deleting: {export_name} (date: {export_date}, id: {export_id})")
        try:
            del_result = subprocess.run(
                ["docker", "exec", "frigate", "curl", "-s", "-X", "DELETE",
                 f"http://localhost:5000/api/exports/{export_id}"],
                capture_output=True, text=True, check=True
            )
            try:
                del_response = json.loads(del_result.stdout)
                if del_response.get("success"):
                    deleted_count += 1
                else:
                    print(f"  API returned failure: {del_response}", file=sys.stderr)
            except json.JSONDecodeError:
                # If API returns non-JSON (some versions just return 200 OK)
                deleted_count += 1
        except Exception as e:
            print(f"  Failed to delete {export_name}: {e}", file=sys.stderr)

    print(f"Cleanup complete: {deleted_count} deleted, {skipped_count} kept (within {max_age_days}-day retention)")


if __name__ == "__main__":
    main()
