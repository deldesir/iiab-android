# shellcheck shell=bash
# Module file (no shebang). Bundled by build_bundle.sh

# -----------------------------------------------------------------------------
# IIAB Proxy (haproxy + privoxy) controlled by ADB global http_proxy
# - Configs come from repo folder: termux-setup/proxy/{haproxy.cfg,privoxy.config,user.action}
# - Runtime folder: ~/.iiab-android/proxy/
# - privoxy listens on 127.0.0.1:9050
# - haproxy listens on 127.0.0.1:8080 and forwards to IIAB origin (127.0.0.1:8085)
# -----------------------------------------------------------------------------

# Runtime dirs/state
PROXY_DIR="${HOME}/.iiab-android/proxy"
PROXY_STATE="${PROXY_DIR}/state"
PROXY_PIDDIR="${PROXY_STATE}/pids"

# Runtime config destinations
HAPROXY_CFG="${PROXY_DIR}/haproxy.cfg"
PRIVOXY_CFG="${PROXY_DIR}/privoxy.config"
USER_ACTION="${PROXY_DIR}/user.action"

# Fixed endpoints
PRIVOXY_LISTEN="127.0.0.1:9050"
HAPROXY_LISTEN="127.0.0.1:8080"

# IIAB origin for quick curl checks (inside Termux, IIAB web is usually on 127.0.0.1:8085)
IIAB_ORIGIN="http://127.0.0.1:8085/"
IIAB_PROXY_URL="http://${PRIVOXY_LISTEN}"

# -------------
# State helpers
# -------------
proxy_state_init() {
  mkdir -p "${PROXY_DIR}" "${PROXY_STATE}" "${PROXY_PIDDIR}" "${LOG_DIR:-${HOME}/.iiab-android/logs}" >/dev/null 2>&1 || true
}

proxy_is_enabled() { [[ -f "${PROXY_STATE}/enabled" ]]; }
proxy_enable_flag_on() { proxy_state_init; : > "${PROXY_STATE}/enabled"; }
proxy_disable_flag_off() { rm -f "${PROXY_STATE}/enabled" >/dev/null 2>&1 || true; }

proxy_prev_file() { echo "${PROXY_STATE}/prev_http_proxy"; }
proxy_restore_flag() { echo "${PROXY_STATE}/restore_needed"; }

proxy_write_prev_proxy() {
  local prev="$1"
  printf '%s\n' "${prev}" > "$(proxy_prev_file)"
  : > "$(proxy_restore_flag)"
}

proxy_clear_prev_proxy() {
  rm -f "$(proxy_prev_file)" "$(proxy_restore_flag)" >/dev/null 2>&1 || true
}

# -------------
# ADB helpers
# -------------
proxy_adb_alive() { adb get-state >/dev/null 2>&1; }

proxy_adb_serial_quiet() {
  adb start-server >/dev/null 2>&1 || true
  adb_pick_loopback_serial 2>/dev/null || return 1
}

proxy_get_http_proxy() {
  local s
  s="$(proxy_adb_serial_quiet)" || return 1
  adb -s "$s" shell settings get global http_proxy 2>/dev/null | tr -d '\r' || true
}

proxy_set_http_proxy() {
  # $1 = value, e.g. "127.0.0.1:9050" or ":0"
  local s
  s="$(proxy_adb_serial_quiet)" || return 1
  adb -s "$s" shell settings put global http_proxy "$1" >/dev/null 2>&1 || return 1
}

proxy_is_ours_value() {
  local cur="$1"
  [[ "${cur}" == "${PRIVOXY_LISTEN}" ]]
}

proxy_is_none_value() {
  local cur="$1"
  [[ -z "${cur}" || "${cur}" == "null" || "${cur}" == ":0" ]]
}

# -------------
# Package install
# -------------
proxy_ensure_pkgs() {
  # Install on-demand (do not bloat baseline if user never uses proxy)
  have haproxy && have privoxy && return 0
  log "Installing proxy packages in Termux: haproxy + privoxy ..."
  termux_apt update || true
  termux_apt install haproxy privoxy || return 1
  have haproxy && have privoxy
}

# -------------
# Config deploy (PoC: heredoc; later download from URL)
# -------------
proxy_install_configs_from_repo() {
   proxy_state_init

  cat > "${HAPROXY_CFG}" <<'EOF'
global
    log stdout format raw local0
    maxconn 256

defaults
    mode http
    log global
    option httplog
    option dontlognull
    timeout connect 5s
    timeout client  60s
    timeout server  60s

frontend fe_boxlan
    bind 127.0.0.1:8080
    http-request set-uri %[req.uri,regsub(^https?://[^/]+,)] if { req.uri -m reg ^https?:// }
    http-request set-header Host box.lan
    http-request del-header Proxy-Connection
    default_backend be_iiab

backend be_iiab
    server iiab 127.0.0.1:8085
    http-response replace-header Location ^(https?://)box\.lan:8085(.*)$ \1box.lan\2
    http-response replace-header Location ^(https?://)127\.0\.0\.1:8085(.*)$ \1box.lan\2
EOF

  cat > "${PRIVOXY_CFG}" <<'EOF'
listen-address  127.0.0.1:9050

toggle 1
enable-remote-toggle 0
enable-remote-http-toggle 0
enable-edit-actions 0
enforce-blocks 0
debug 0

confdir /data/data/com.termux/files/home/.iiab-android/proxy
logdir  /data/data/com.termux/files/home/.iiab-android/logs

actionsfile user.action
EOF

  cat > "${USER_ACTION}" <<'EOF'
{+forward-override{forward 127.0.0.1:8080}}
box.lan/
EOF


}

# NOTE: For now, we generate configs here. Later we will copy from:
waiting_on_commit() {
  have curl || { log "Installing curl (needed to fetch proxy configs)"; termux_apt update || true; termux_apt install curl || return 1; }

  # Expected raw URLs (enable once committed upstream)
  # PROXY_RAW_BASE="https://raw.githubusercontent.com/iiab/iiab-android/refs/heads/main/termux-setup/proxy"
  # HAPROXY_RAW_URL="${PROXY_RAW_BASE}/haproxy.cfg"
  # PRIVOXY_RAW_URL="${PROXY_RAW_BASE}/privoxy.config"
  # USER_ACTION_RAW_URL="${PROXY_RAW_BASE}/user.action"

  # If URLs not configured yet, fail with a clear hint (so we don't silently continue).
  if [[ -z "${HAPROXY_RAW_URL:-}" || -z "${PRIVOXY_RAW_URL:-}" || -z "${USER_ACTION_RAW_URL:-}" ]]; then
    warn_red "Proxy raw URLs are not configured yet (HAPROXY/PRIVOXY/USER_ACTION)."
    return 1
  fi

  log "Downloading proxy configs (raw) into: ${PROXY_DIR}"
  if ! curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 8 --max-time 30 "$HAPROXY_RAW_URL" -o "${HAPROXY_CFG}"; then
    warn_red "Failed downloading haproxy.cfg from: $HAPROXY_RAW_URL"; return 1
  fi
  if ! curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 8 --max-time 30 "$PRIVOXY_RAW_URL" -o "${PRIVOXY_CFG}"; then
    warn_red "Failed downloading privoxy.config from: $PRIVOXY_RAW_URL"; return 1
  fi
  if ! curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 8 --max-time 30 "$USER_ACTION_RAW_URL" -o "${USER_ACTION}"; then
    warn_red "Failed downloading user.action from: $USER_ACTION_RAW_URL"; return 1
  fi

  chmod 600 "${HAPROXY_CFG}" "${PRIVOXY_CFG}" "${USER_ACTION}" >/dev/null 2>&1 || true
  ok "Proxy configs installed (raw) to: ${PROXY_DIR}"
  return 0
}

# -------------
# Process management
# -------------
proxy_pidfile_privoxy() { echo "${PROXY_PIDDIR}/privoxy.pid"; }
proxy_pidfile_haproxy() { echo "${PROXY_PIDDIR}/haproxy.pid"; }

proxy_is_pid_running() {
  local pidfile="$1" pid=""
  [[ -r "$pidfile" ]] || return 1
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

proxy_start_privoxy() {
  proxy_state_init
  proxy_is_pid_running "$(proxy_pidfile_privoxy)" && { ok "privoxy already running."; return 0; }

  # Privoxy foreground mode is --no-daemon (varies by build). Use it if present, else fall back.
  local logf="${LOG_DIR:-${HOME}/.iiab-android/logs}/privoxy.log"
  if privoxy --help 2>&1 | grep -q -- '--no-daemon'; then
    nohup privoxy --no-daemon "${PRIVOXY_CFG}" >>"$logf" 2>&1 &
  else
    nohup privoxy "${PRIVOXY_CFG}" >>"$logf" 2>&1 &
  fi
  echo $! >"$(proxy_pidfile_privoxy)"
  sleep 0.2
  proxy_is_pid_running "$(proxy_pidfile_privoxy)" || { warn_red "privoxy failed to start (see $logf)"; return 1; }
  ok "privoxy started (pid=$(cat "$(proxy_pidfile_privoxy)"))."
  return 0
}

proxy_start_haproxy() {
  proxy_state_init
  proxy_is_pid_running "$(proxy_pidfile_haproxy)" && { ok "haproxy already running."; return 0; }

  local logf="${LOG_DIR:-${HOME}/.iiab-android/logs}/haproxy.log"
  # -db keeps in foreground; we background via nohup
  nohup haproxy -db -f "${HAPROXY_CFG}" >>"$logf" 2>&1 &
  echo $! >"$(proxy_pidfile_haproxy)"
  sleep 0.2
  proxy_is_pid_running "$(proxy_pidfile_haproxy)" || { warn_red "haproxy failed to start (see $logf)"; return 1; }
  ok "haproxy started (pid=$(cat "$(proxy_pidfile_haproxy)"))."
  return 0
}

proxy_stop_one() {
  local name="$1" pidfile="$2"
  if proxy_is_pid_running "$pidfile"; then
    local pid
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    kill "$pid" >/dev/null 2>&1 || true
    sleep 0.2
    kill -0 "$pid" >/dev/null 2>&1 && kill -9 "$pid" >/dev/null 2>&1 || true
    rm -f "$pidfile" >/dev/null 2>&1 || true
    ok "$name stopped."
  else
    rm -f "$pidfile" >/dev/null 2>&1 || true
  fi
}

proxy_stop_all() {
  proxy_stop_one "haproxy" "$(proxy_pidfile_haproxy)"
  proxy_stop_one "privoxy" "$(proxy_pidfile_privoxy)"
}

proxy_start_all() {
  proxy_ensure_pkgs || { warn_red "Cannot install haproxy/privoxy"; return 1; }
  proxy_install_configs_from_repo || return 1
  proxy_start_haproxy || return 1
  proxy_start_privoxy || return 1
  return 0
}

# -------------
# Enable/Disable (ADB global http_proxy)
# -------------
proxy_enable() {
  proxy_state_init
  require_adb_connected || return 1

  proxy_start_all || return 1

  local cur
  cur="$(proxy_get_http_proxy 2>/dev/null || true)"
  cur="${cur:-:0}"
  if proxy_is_ours_value "$cur"; then
    ok "Android http_proxy already set to our proxy: ${PRIVOXY_LISTEN}"
  else
    # Save previous only if it was meaningful and not ":0"
    if ! proxy_is_none_value "$cur"; then
      proxy_write_prev_proxy "$cur"
      log "Saved previous Android http_proxy: $cur"
    else
      # Treat "none" as ":0" so restore_best_effort can revert it.
      proxy_write_prev_proxy ":0"
    fi
    proxy_set_http_proxy "${PRIVOXY_LISTEN}" || {
      warn_red "Failed to set Android http_proxy"
      proxy_clear_prev_proxy
      return 1
    }
    ok "Android http_proxy set to: ${PRIVOXY_LISTEN}"
  fi

  proxy_enable_flag_on
  ok "Proxy enabled."
}

proxy_disable() {
  proxy_state_init
  require_adb_connected || return 1

  local cur
  cur="$(proxy_get_http_proxy)"

  if proxy_is_ours_value "$cur"; then
    # Restore if we saved something
    if [[ -f "$(proxy_restore_flag)" && -r "$(proxy_prev_file)" ]]; then
      local prev
      prev="$(cat "$(proxy_prev_file)" 2>/dev/null || true)"
      if [[ -n "$prev" ]]; then
        if proxy_set_http_proxy "$prev"; then
          ok "Restored previous Android http_proxy: $prev"
        else
          warn_red "Failed to restore Android http_proxy. Keeping services running; try --proxy-reset again."
          return 1
        fi
      else
        if proxy_set_http_proxy ":0"; then
          ok "Cleared Android http_proxy (:0)"
        else
          warn_red "Failed to clear Android http_proxy. Keeping services running; try --proxy-reset again."
          return 1
        fi
      fi
    else
      if proxy_set_http_proxy ":0"; then
        ok "Cleared Android http_proxy (:0)"
      else
        warn_red "Failed to clear Android http_proxy. Keeping services running; try --proxy-reset again."
        return 1
      fi
    fi
  else
    warn "Android http_proxy is not ours (current='$cur'); not changing it."
  fi

  proxy_disable_flag_off
  proxy_stop_all
  proxy_clear_prev_proxy
  ok "Proxy disabled."
}

proxy_status() {
  proxy_state_init
  local cur
  cur="$(proxy_get_http_proxy 2>/dev/null || true)"

  echo "[proxy] enabled_flag=$(proxy_is_enabled && echo yes || echo no)"
  echo "[proxy] android_http_proxy=${cur:-<empty>}"
  echo "[proxy] haproxy_running=$(proxy_is_pid_running "$(proxy_pidfile_haproxy)" && echo yes || echo no)"
  echo "[proxy] privoxy_running=$(proxy_is_pid_running "$(proxy_pidfile_privoxy)" && echo yes || echo no)"
}

# -------------
# Start proxy hooks
# -------------
# Start proxy daemons only (no Android settings changes)
proxy_start_services() {
  proxy_start_all
}

# Stop proxy daemons best-effort (never fail callers)
proxy_stop_services_best_effort() {
  proxy_stop_all || true
  return 0
}

# IMPORTANT: do NOT stop privoxy/haproxy if we cannot restore Android http_proxy,
# otherwise the phone may lose Internet connectivity.
proxy_cleanup_on_exit() {
  # Run only once even if trap fires multiple times (INT/TERM + EXIT).
  [[ "${_PROXY_TRAP_DONE:-0}" -eq 1 ]] && return 0
  _PROXY_TRAP_DONE=1

  proxy_feature_enabled || return 0
  proxy_state_init

  # If we changed Android http_proxy and ADB is alive, restore it first.
  if [[ -f "${PROXY_STATE}/restore_needed" ]] && proxy_adb_alive; then
    proxy_restore_android_http_proxy_best_effort >/dev/null 2>&1 || true
    proxy_stop_services_best_effort >/dev/null 2>&1 || true
    return 0
  fi

  # If ADB is alive, we can check whether Android http_proxy is still ours.
  # If it's NOT ours, it is safe to stop services.
  if proxy_adb_alive; then
    local cur=""
    cur="$(proxy_get_http_proxy 2>/dev/null || true)"
    if ! proxy_is_ours_value "$cur"; then
      proxy_stop_services_best_effort >/dev/null 2>&1 || true
    fi
    return 0
  fi

  # No ADB + restore_needed may still be set -> keep services running to avoid cutting connectivity.
  return 0
}

# Enable proxy feature best-effort (used during service startup)
# Only acts if user enabled it previously (state flag exists).
proxy_maybe_enable_feature() {
  [[ "${PROXY_ADB:-0}" -eq 1 ]] || return 0
  proxy_is_enabled || return 0
  proxy_enable || true
  return 0
}

# Placeholder: we can implement the real Android 14 phantom-process mitigation later.
proxy_android14_disable_phantom_monitor_or_fail() {
  [[ "${PROXY_ADB:-0}" -eq 1 ]] || return 0
  require_adb_connected >/dev/null 2>&1 || return 0
  local sdk
  sdk="$(adb shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r' || true)"
  if [[ "$sdk" =~ ^[0-9]+$ ]] && (( sdk >= 34 )); then
    warn "Android SDK $sdk detected (Android 14+). Phantom process monitor handling is not implemented yet; continuing."
  fi
  return 0
}

proxy_reconcile_on_startup() {
  proxy_state_init

  # We only want to auto-recover when we have evidence that Android http_proxy was changed
  # and we didn't restore it (e.g., Termux crash). "enabled" alone is not enough.
  if [[ ! -f "$(proxy_restore_flag)" ]]; then
    return 0
  fi

  warn_red "Proxy recovery: it looks like the previous proxy session did not exit cleanly (restore_needed)."

  local hap_ok=0 pri_ok=0
  proxy_is_pid_running "$(proxy_pidfile_haproxy)" && hap_ok=1
  proxy_is_pid_running "$(proxy_pidfile_privoxy)" && pri_ok=1

  if require_adb_connected >/dev/null 2>&1; then
    local cur
    cur="$(proxy_get_http_proxy 2>/dev/null || true)"
    cur="${cur:-:0}"
    ok "Android global http_proxy: ${cur}"

    if proxy_is_ours_value "$cur"; then
      if (( hap_ok == 0 || pri_ok == 0 )); then
        warn "Android http_proxy points to the local proxy, but haproxy/privoxy are not running. Attempting emergency restore..."
        if proxy_start_services; then
          ok "Emergency services restored (Privoxy/HAProxy)."
        else
          warn "Could not start services. The phone may have no Internet connectivity."
        fi
      else
        ok "haproxy/privoxy are already running."
      fi

      warn "To return to normal (remove Android global proxy): iiab-termux --proxy-reset"
      warn "For a full diagnosis: iiab-termux --proxy-status"
    else
      # Android proxy is not ours anymore; state is stale -> clean up.
      ok "Android global proxy no longer points to the local proxy. Clearing stale recovery state."
      proxy_clear_prev_proxy
    fi
    return 0
  fi

  # No ADB: best-effort recovery. We have restore_needed, so try to keep connectivity.
  warn "ADB is not connected: cannot confirm Android global http_proxy."

  if (( hap_ok == 0 || pri_ok == 0 )); then
    warn "restore_needed is set; attempting to start services to avoid leaving you without Internet."
    if proxy_start_services; then
      ok "Emergency services restored (Privoxy/HAProxy)."
    else
      warn "Could not start services. The phone may have no Internet connectivity."
    fi
  else
    ok "haproxy/privoxy are already running."
  fi

  warn "Connect ADB and run: iiab-termux --proxy-status"
  warn "If it confirms the global proxy is still active, run: iiab-termux --proxy-reset"
}
