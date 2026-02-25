# shellcheck shell=bash
# Module file (no shebang). Bundled by build_bundle.sh

get_android_arch() {
  case "$(uname -m)" in
    aarch64)       echo "arm64-v8a" ;;
    armv7l|armv8l) echo "armeabi-v7a" ;;
    x86_64)        echo "x86_64" ;;
    i686)          echo "x86" ;;
    *)             echo "unknown" ;;
  esac
}

cmd_backup_rootfs() {
  local custom_path="${1:-}"
  local out_file

  have proot-distro || die "proot-distro is not installed. Run the baseline first."
  iiab_exists || die "IIAB Debian (alias 'iiab') is not installed. Nothing to backup."

  if [[ -n "$custom_path" ]]; then
    out_file="$custom_path"
  else
    local ts arch
    # Format: YYYY.DDD.HHMM (Day of year: %j)
    ts="$(date -u +"%Y.%j.%H%M")"
    arch="$(get_android_arch)"
    out_file="iiab-android_rootfs_${ts}_${arch}.tar.gz"
  fi

  log "Starting backup of IIAB Debian..."
  log "Destination: $out_file"

  if proot-distro backup iiab --output "$out_file"; then
    ok "Backup completed successfully: $out_file"
  else
    warn_red "Failed to create backup."
    return 1
  fi
}

cmd_restore_rootfs() {
  local backup_file="${1:-}"

  [[ -z "$backup_file" ]] && die "You must specify the path to the backup file to restore."
  [[ -f "$backup_file" ]] || die "Backup file does not exist: $backup_file"

  have proot-distro || die "proot-distro is not installed."

  log "Restoring IIAB Debian from: $backup_file"

  if iiab_exists; then
    log_yel "IIAB Debian already exists. Restoration will overwrite the current system."
    # Seems natural that we move forward once the download finish, we keep this for now.
    #tty_yesno_default_y "[iiab] Do you want to continue and overwrite IIAB Debian? [Y/n]: " || die "Restoration aborted by user."
  fi

  if proot-distro restore "$backup_file"; then
    ok "Restoration completed successfully."
    BASELINE_OK=1
  else
    warn_red "Failed to restore backup."
    return 1
  fi
}

cmd_pull_rootfs() {
  local target_url="${1:-}"
  local use_meta4="${2:-1}"  # 1 = yes, 0 = no (--no-meta4)
  local autoclean="${3:-0}"  # 1 = yes, 0 = no (--autoclean)

  [[ -z "$target_url" ]] && die "You must provide a URL to download the rootfs."

  # Ensure aria2c and curl are available
  have aria2c || { log "Installing aria2c..."; termux_apt update || true; termux_apt install aria2c || die "Failed to install aria2c."; }
  have curl || { log "Installing curl..."; termux_apt install curl || die "Failed to install curl."; }

  local dest_dir="${STATE_DIR}/downloads"
  mkdir -p "$dest_dir"

  local download_url="$target_url"

  # Meta4 Logic
  if [[ "$use_meta4" -eq 1 ]]; then
    if [[ "$target_url" == *.meta4 ]]; then
      log "URL directly provides a .meta4 file."
    else
      log "Checking for Metalink (.meta4) availability on the server..."
      if curl -Isf "${target_url}.meta4" > /dev/null 2>&1; then
        ok "Found .meta4 file. Distributed download will be prioritized."
        download_url="${target_url}.meta4"
      else
        log_yel "No .meta4 file found. Falling back to direct download."
      fi
    fi
  else
    log "Mode --no-meta4 is active. Skipping Metalink check."
  fi

  # Generate temporary file paths
  local file_name
  file_name="${target_url##*/}"     # Extract filename from URL
  file_name="${file_name%.meta4}"   # Strip .meta4 extension if present
  local out_path="${dest_dir}/${file_name}"
  local dht_file="${STATE_DIR}/dht.dat"

  # UX trick: "Preheat" DHT before execution.
  if [[ ! -f "$dht_file" ]]; then
    log "Define P2P network cache..."
    aria2c --enable-dht=true \
           --dht-file-path="$dht_file" \
           --stop=1 \
           "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567" \
           >/dev/null 2>&1 || true
  fi

  # Smart Toggle: verufy integrity only if available.
  local check_int="false"
  if [[ -f "$out_path" ]]; then
    log "Local file detected. Verifying integrity via P2P/Metalink..."
    check_int="true"
  fi

  log "Downloading rootfs..."

  # Mimic aria2 arguments in ansible playbooks
  local aria_args=(
    # --- Dirs and files ---
    "--dir=$dest_dir"
    "--continue=true"
    "--auto-file-renaming=false"

    # --- Connections and performance ---
    "--max-connection-per-server=4"
    "--file-allocation=falloc"
    "--enable-http-pipelining=true"
    "--async-dns=false"
    "--connect-timeout=60"

    # --- P2P & metalink ---
    "--follow-metalink=mem"
    "--enable-dht=true"
    "--dht-file-path=$dht_file"
    "--bt-enable-lpd=true"
    "--check-integrity=$check_int"
    "--seed-time=0"

    # --- Console output & logs ---
    "--log-level=warn"
    "--console-log-level=warn"
    "--summary-interval=0"
    "--show-console-readout=true"
    "--download-result=hide"

    # --- Target ---
    "$download_url"
  )

  # Run aria2c bypassing the log to maintain the interactive bar
  if : >&3 2>/dev/null && : >&4 2>/dev/null; then
    aria2c "${aria_args[@]}" >&3 2>&4 || die "aria2c download failed."
  else
    aria2c "${aria_args[@]}" || die "aria2c download failed."
  fi

  ok "Download finished: $out_path"

  # Proceed with restoration
  cmd_restore_rootfs "$out_path"

  # --- POST-RESTORE CLEANUP ---
  if [[ "$autoclean" -eq 1 ]]; then
    log "Cleaning up downloaded file to save space (--autoclean active)..."
    rm -f "$out_path" >/dev/null 2>&1 || true
  else
    # Get the disk amount used and ask about final cleaning
    local count=0 total_bytes=0
    for f in "$dest_dir"/*.tar.gz; do
      [[ -f "$f" ]] || continue
      count=$((count + 1))
      total_bytes=$((total_bytes + $(stat -c %s "$f" 2>/dev/null || echo 0)))
    done

    if (( count > 0 )); then
      local size_gb
      size_gb="$(awk "BEGIN {printf \"%.2f\", $total_bytes / 1073741824}")"
      log_yel "You have $count image file(s) in .iiab-android/downloads, using ${size_gb}GB."
      if tty_yesno_default_n "[iiab] Do you want to free up this space and delete them? [y/N]: "; then
        rm -f "$dest_dir"/*.tar.gz >/dev/null 2>&1 || true
        ok "Downloaded images deleted."
      else
        log "Keeping existing images."
      fi
    fi
  fi
}
