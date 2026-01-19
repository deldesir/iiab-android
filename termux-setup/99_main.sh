# shellcheck shell=bash
# Module file (no shebang). Bundled by build_bundle.sh

# iiab-termux
# - Termux bootstrap (packages, wakelock)
# - proot-distro + IIAB Debian bootstrap
# - ADB wireless pair/connect via Termux:API notifications (no Shizuku)
# - Optional PPK / phantom-process tweaks (best-effort)

# -------------------------
# Defaults
# -------------------------
# NOTE: Core defaults live in 00_lib_common.sh to guarantee availability for all modules.

# Ensure state directories exist (safe even if user overrides via environment).
mkdir -p "$STATE_DIR" "$ADB_STATE_DIR" "$LOG_DIR"

BASELINE_OK=0
BASELINE_ERR=""
RESET_IIAB=0
ONLY_CONNECT=0

CHECK_NO_ADB=0
CHECK_SDK=""
CHECK_MON=""
CHECK_PPK=""

# Modes are mutually exclusive (baseline is default)
MODE="baseline"      # baseline|with-adb|adb-only|connect-only|ppk-only|check|all|login
MODE_SET=0
CONNECT_PORT_FROM=""   # "", "flag", "positional"

usage() {
  cat <<'EOF'
Usage:
  iiab-termux
    -> Termux baseline + IIAB Debian bootstrap (idempotent). No ADB prompts.

  iiab-termux --login
    -> Login into IIAB Debian (proot-distro login iiab).

  iiab-termux --with-adb
    -> Termux baseline + IIAB Debian bootstrap + ADB pair/connect if needed (skips if already connected).

  iiab-termux  --adb-only [--connect-port PORT|IP:PORT]
    -> Only ADB pair/connect if needed (no IIAB Debian; skips if already connected).
       Tip: --connect-port skips the CONNECT PORT prompt (you’ll still be asked for PAIR PORT + PAIR CODE).

  iiab-termux --connect-only [PORT|IP:PORT]
    -> Connect-only (no pairing). Use this after the device was already paired before.

  iiab-termux --ppk-only
    -> Set PPK only: max_phantom_processes=256 (requires ADB already connected).
       Android 14-16 usually achieve this via "Disable child process restrictions" in Developer Options.

  iiab-termux --iiab-android
    -> Install/update 'iiab-android' command inside IIAB Debian (does NOT run it).

  iiab-termux --check
    -> Check readiness: developer options flag (if readable),
       (Android 14+) "Disable child process restrictions" proxy flag, and (Android 12-13) PPK effective value.

  iiab-termux --all
    -> baseline + IIAB Debian +
       (Android 12-13) ADB pair/connect + apply PPK + run --check
       (Android 14+) optionally skip ADB (reminds to disable child process restrictions).

  Optional:
    --connect-port [IP:PORT|PORT]  Skip CONNECT PORT prompt (ADB modes)
    --timeout 180                  Seconds to wait per prompt
    --reset-iiab                   Reset (reinstall) IIAB Debian in proot-distro
    --no-log                       Disable logging
    --log-file /path/file          Write logs to a specific file
    --debug                        Extra logs

Notes:
- ADB prompts require: `pkg install termux-api` + Termux:API app installed + notification permission.
- Wireless debugging must be enabled on Android 12 & 13
- This script doesn't use adb root.
EOF
}

trap 'cleanup_notif >/dev/null 2>&1 || true; release_wakelock >/dev/null 2>&1 || true' EXIT INT TERM

# NOTE: Termux:API prompts live in 40_mod_termux_api.sh

# -------------------------
# Self-check
# -------------------------
self_check() {
  log "Self-check summary:"
  log " Android release=${ANDROID_REL:-?} sdk=${ANDROID_SDK:-?}"

  if have proot-distro; then
    log " proot-distro: present"
    log " proot-distro list:"
    proot-distro list 2>/dev/null | indent || true
    if iiab_exists; then ok " IIAB Debian: present"; else warn " IIAB Debian: not present"; fi
  else
    warn " proot-distro: not present"
  fi

  if have adb; then
    log " adb: present"
    adb devices -l 2>/dev/null | indent || true
    local serial
#    re-enable in need for verbose output.
#    if serial="$(adb_pick_loopback_serial 2>/dev/null)"; then
#      log " adb shell id (first device):"
#      adb -s "$serial" shell id 2>/dev/null | indent || true
#    fi
  else
    warn " adb: not present"
  fi
  # Quick Android flags check (best-effort; no prompts)
  self_check_android_flags || true

  if have termux-wake-lock; then ok " Termux:API wakelock: available"; else warn " Termux:API wakelock: not available"; fi
  if have termux-notification; then ok " Termux:API notifications: command present"; else warn " Termux:API notifications: missing"; fi
}

baseline_bail() {
  warn_red "Cannot continue: Termux baseline is incomplete."
  [[ -n "${BASELINE_ERR:-}" ]] && warn "Reason: ${BASELINE_ERR}"
  baseline_bail_details || true
  exit 1
}

final_advice() {
  if [[ "${BASELINE_OK:-0}" -ne 1 ]]; then
    warn_red "Baseline is not ready, so ADB prompts / IIAB Debian bootstrap may be unavailable."
    [[ -n "${BASELINE_ERR:-}" ]] && warn "Reason: ${BASELINE_ERR}"
    warn "Fix: check network + Termux repos, then re-run the script."
    return 0
  fi

  # 1) Android-related warnings (only meaningful if we attempted checks)
  local sdk="${CHECK_SDK:-${ANDROID_SDK:-}}"
  local _active=0
  case "${MODE:-}" in
    with-adb|adb-only|connect-only|ppk-only|check|all) _active=1 ;;
    *) _active=0 ;;
  esac

  local adb_connected=0
  local serial="" mon="" mon_fflag=""

  # Best-effort: detect whether an ADB loopback device is already connected.
  # (We do NOT prompt/pair here; we only check current state.)
  if have adb; then
    adb start-server >/dev/null 2>&1 || true
    if adb_pick_loopback_serial >/dev/null 2>&1; then
      adb_connected=1
      serial="$(adb_pick_loopback_serial 2>/dev/null || true)"
    fi
  fi
  # Escalate to red only when user is actively checking/fixing,
  # OR when we already have ADB connected (strong evidence).
  advice_warn_bad() {  # args: message
    if (( _active || adb_connected )); then
      warn_red "$*"
    else
      warn "$*"
    fi
  }

  # Baseline safety gate:
  # On Android 12-13 (SDK 31-33), IIAB/proot installs can fail if PPK is low (often 32).
  # Baseline mode does NOT force ADB pairing nor run check_readiness(), so PPK may be unknown.
  # If PPK is not determined, suggest running --all BEFORE telling user to proceed to proot-distro.
  if [[ "$MODE" == "baseline" ]]; then
    if [[ "$sdk" =~ ^[0-9]+$ ]] && (( sdk >= 31 && sdk <= 33 )); then
      # If we didn't run checks, CHECK_PPK will be empty. Even with adb_connected=1, baseline
      # still doesn't populate CHECK_PPK unless user ran --check/--all.
      if [[ "${CHECK_PPK:-}" != "" && "${CHECK_PPK:-}" =~ ^[0-9]+$ ]]; then
        : # PPK determined -> ok to continue with normal advice below
      else
        warn "Android 12-13: PPK value hasn't been verified (max_phantom_processes may be low, e.g. 32)."
        warn "Before starting the IIAB install, run the complete setup so it can apply/check PPK=256; otherwise the installation may fail:"
        ok   "  iiab-termux --all"
        return 0
      fi
    elif [[ "$sdk" =~ ^[0-9]+$ ]] && (( sdk >= 34 )); then
      # On Android 14+, rely on "Disable child process restrictions"
      # Proxy signals: settings_enable_monitor_phantom_procs (or the fflag override).
      # Baseline does not run check_readiness(), so CHECK_MON is usually empty.
      if [[ "${CHECK_MON:-}" == "false" ]]; then
        : # Verified OK (rare in baseline) -> continue
      else
        # If ADB is already connected, try to read the flag best-effort (no prompts).
        if [[ "$adb_connected" -eq 1 && -n "${serial:-}" ]]; then
          mon_fflag="$(adb_get_child_restrictions_flag "$serial")"
          if [[ "$mon_fflag" == "true" || "$mon_fflag" == "false" ]]; then
            mon="$mon_fflag"
          else
            mon="$(adb -s "$serial" shell settings get global settings_enable_monitor_phantom_procs 2>/dev/null | tr -d '\r' || true)"
          fi
        fi

        if [[ "${mon:-}" == "false" ]]; then
          : # Restrictions already disabled -> ok to continue
        else
          if [[ "${mon:-}" == "true" ]]; then
            advice_warn_bad "Android 14+: child process restrictions appear ENABLED (monitor=true)."
          else
            warn "Android 14+: child process restrictions haven't been verified (monitor flag unreadable/unknown)."
          fi
          warn "For Android 14 and later, there is no strict need to connect to ADB, on the other hand:"
          warn "Please make sure to set 'Disable child process restrictions' enabled; otherwise the installation may fail."
          return 0
        fi
      fi
    fi
  fi

  if [[ "${CHECK_NO_ADB:-0}" -eq 1 ]]; then
    # If we could not check, still warn on A12-13 because PPK is critical there
    if [[ "$sdk" =~ ^[0-9]+$ ]] && (( sdk >= 31 && sdk <= 33 )); then
      warn "A12-13: verify PPK=256 before installing IIAB."
    fi
  else
    # A14+ child restrictions proxy (only if readable)
    if [[ "$sdk" =~ ^[0-9]+$ ]] && (( sdk >= 34 )) && [[ "${CHECK_MON:-}" == "true" ]]; then
      advice_warn_bad "A14+: disable child process restrictions before installing IIAB."
    fi

    # Only warn about PPK on A12-13 (A14+ uses child restrictions)
    if [[ "$sdk" =~ ^[0-9]+$ ]] && (( sdk >= 31 && sdk <= 33 )); then
      if [[ "${CHECK_PPK:-}" =~ ^[0-9]+$ ]] && (( CHECK_PPK < 256 )); then
        advice_warn_bad "PPK is low (${CHECK_PPK}); consider --ppk-only."
      fi
    fi
  fi

  # 2) IIAB Debian "next step" should only be shown for modes that actually bootstrap IIAB
  case "$MODE" in
    baseline|with-adb|all)
      if iiab_exists; then
        ok "Next: proot-distro login iiab"
      else
        warn "IIAB Debian not present. Run:"
        warn "  proot-distro install --override-alias iiab debian"
      fi
      ;;
    *)
      # adb-only/connect-only/ppk-only/check: do not suggest Debian login as a generic ending
      ;;
  esac
}

iiab_login() {
  local stamp="$STATE_DIR/stamp.termux_base"

  # Baseline stamp is advisory only for login (do not block).
  if [[ -f "$stamp" ]]; then
    ok "Baseline stamp found: $stamp"
  else
    warn_red "Baseline stamp not found ($stamp)."
    warn "Tip: run the baseline once: iiab-termux"
  fi

  have proot-distro || die "proot-distro not found. Install baseline first (pkg install proot-distro or run iiab-termux)."
  if ! iiab_exists; then
    warn_red "IIAB Debian is not installed in proot-distro (alias 'iiab' missing)."
    warn "Recommended: iiab-termux --all"
    warn "Or:          proot-distro install --override-alias iiab debian"
    return 1
  fi

  # Best-effort Android advice before user starts doing heavy installs inside proot.
  local sdk="${ANDROID_SDK:-}"
  if [[ "$sdk" =~ ^[0-9]+$ ]] && (( sdk >= 31 && sdk <= 33 )); then
    # Android 12-13: PPK is a common hard failure point.
    if have adb; then
      adb start-server >/dev/null 2>&1 || true
      if adb_pick_loopback_serial >/dev/null 2>&1; then
        check_readiness || true
      else
        warn_red "Android 12-13: ADB is not connected, so PPK=256 cannot be verified/applied."
        warn "Before running the IIAB installer inside proot, run:"
        ok   "  iiab-termux --all"
      fi
    else
      warn_red "Android 12-13: adb is missing, so PPK=256 cannot be verified/applied."
      warn "Install adb (android-tools) and run:"
      ok   "  iiab-termux --all"
    fi
  elif [[ "$sdk" =~ ^[0-9]+$ ]] && (( sdk >= 34 )); then
    # Android 14+: rely on 'Disable child process restrictions' (monitor=false).
    if have adb; then
      adb start-server >/dev/null 2>&1 || true
      if adb_pick_loopback_serial >/dev/null 2>&1; then
        check_readiness || true
      else
        warn "Android 14+: ensure 'Disable child process restrictions' is enabled in Developer Options."
      fi
    else
      warn "Android 14+: ensure 'Disable child process restrictions' is enabled in Developer Options."
    fi
  fi

  ok "Entering IIAB Debian: proot-distro login iiab"

  # Preserve interactivity even if logging is enabled (avoid pipes/tee issues).
  if [[ -r /dev/tty ]]; then
    proot-distro login iiab </dev/tty >&3 2>&4
  else
    proot-distro login iiab
  fi
}
# -------------------------
# Args
# -------------------------
set_mode() {
  local new="$1"
  if [[ "$MODE_SET" -eq 1 ]]; then
    die "Modes are mutually exclusive. Already set: --${MODE}. Tried: --${new}"
  fi
  MODE="$new"
  MODE_SET=1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-adb) set_mode "with-adb"; shift ;;
    --adb-only) set_mode "adb-only"; shift ;;
    --login) set_mode "login"; shift ;;
    --connect-only)
      set_mode "connect-only"
      ONLY_CONNECT=1
      # Optional positional connect spec (accept PORT or IP:PORT)
      if [[ -n "${2:-}" ]]; then
        local_norm=""
        if local_norm="$(normalize_port_5digits "${2:-}" 2>/dev/null)"; then
        [[ -n "${CONNECT_PORT_FROM:-}" && "${CONNECT_PORT_FROM}" != "positional" ]] && \
          die "CONNECT PORT specified twice (positional + --connect-port). Use only one."
        CONNECT_PORT="$local_norm"
        CONNECT_PORT_FROM="positional"
        shift 2
          continue
        fi
      fi
      shift
      ;;
    --ppk-only) set_mode "ppk-only"; shift ;;
    --iiab-android) set_mode "iiab-android"; shift ;;
    --check) set_mode "check"; shift ;;
    --all) set_mode "all"; shift ;;
    --connect-port)
      [[ -n "${CONNECT_PORT_FROM:-}" && "${CONNECT_PORT_FROM}" != "flag" ]] && \
        die "CONNECT PORT specified twice (positional + --connect-port). Use only one."
      CONNECT_PORT="$(normalize_port_5digits "${2:-}" 2>/dev/null)" || \
        die "Invalid --connect-port (must be 5 digits PORT or IP:PORT): '${2:-}'"
      CONNECT_PORT_FROM="flag"
      shift 2
      ;;
    --timeout) TIMEOUT_SECS="${2:-180}"; shift 2 ;;
    --host) HOST="${2:-127.0.0.1}"; shift 2 ;;
    --reset-iiab|--clean-iiab) RESET_IIAB=1; shift ;;
    --no-log) LOG_ENABLED=0; shift ;;
    --log-file) LOG_FILE="${2:-}"; shift 2 ;;
    --debug) DEBUG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) shift ;;
  esac
done

tty_yesno_default_y() {
  # args: prompt
  # Returns 0 for Yes, 1 for No. Default is Yes.
  local prompt="$1" ans="Y"
  if [[ -r /dev/tty ]]; then
    printf "%s" "$prompt" > /dev/tty
    if ! read -r ans < /dev/tty; then
      ans="Y"
    fi
  else
    warn "No /dev/tty available; defaulting to YES."
    ans="Y"
  fi
  ans="${ans:-Y}"
  [[ "$ans" =~ ^[Nn]$ ]] && return 1
  return 0
}

tty_yesno_default_n() {
  # args: prompt
  # Returns 0 for Yes, 1 for No. Default is No.
  local prompt="$1" ans="N"
  if [[ -r /dev/tty ]]; then
    printf "%s" "$prompt" > /dev/tty
    read -r ans < /dev/tty || ans="N"
  else
    warn "No /dev/tty available; defaulting to NO."
    ans="N"
  fi
  ans="${ans:-N}"
  [[ "$ans" =~ ^[Yy]$ ]] && return 0
  return 1
}

install_iiab_android_cmd() {
  have proot-distro || die "proot-distro not found"
  iiab_exists || { warn_red "IIAB Debian (alias 'iiab') not installed."; return 1; }

  local url="${IIAB_ANDROID_URL:-https://raw.githubusercontent.com/iiab/iiab-android/main/iiab-android}"
  local dest="${IIAB_ANDROID_DEST:-/usr/local/sbin/iiab-android}"
  local tmp="/tmp/iiab-android.$$"

  local meta old new rc=0
  set +e
  meta="$(proot-distro login iiab -- env URL="$url" DEST="$dest" TMP="$tmp" bash -lc '
    set -e
    old=""
    if [ -r "$DEST" ]; then old="$(sha256sum "$DEST" 2>/dev/null | cut -d" " -f1 || true)"; fi
    if ! command -v curl >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install ca-certificates curl coreutils
    fi
    curl -fsSL --retry 5 --retry-connrefused --retry-delay 2 "$URL" -o "$TMP"
    head -n1 "$TMP" | grep -q "bash" || { echo "BAD_SHEBANG"; exit 2; }
    new="$(sha256sum "$TMP" | cut -d" " -f1)"
    echo "OLD=$old"
    echo "NEW=$new"
  ' 2>&1)"
  rc=$?
  set -e

  if (( rc != 0 )); then
    if printf '%s\n' "$meta" | grep -q 'BAD_SHEBANG'; then
      warn_red "Downloaded iiab-android does not look like a bash script (bad shebang)."
    else
      warn_red "Failed to fetch/install iiab-android in proot (rc=$rc)."
      printf "%s\n" "$meta" | indent >&2
    fi
    return 1
  fi

  old="$(printf '%s\n' "$meta" | sed -n 's/^OLD=//p' | head -n1)"
  new="$(printf '%s\n' "$meta" | sed -n 's/^NEW=//p' | head -n1)"

  if [[ -n "$old" && "$old" == "$new" ]]; then
    ok "iiab-android already up to date inside proot."
    proot-distro login iiab -- env TMP="$tmp" bash -lc 'rm -f "$TMP" >/dev/null 2>&1 || true' || true
    return 0
  fi

  if [[ -n "$old" && "$old" != "$new" ]]; then
    warn "iiab-android exists and differs inside proot."
    if ! tty_yesno_default_n "[iiab] Replace existing iiab-android inside proot? [y/N]: "; then
      warn "Keeping existing iiab-android."
      proot-distro login iiab -- env TMP="$tmp" bash -lc 'rm -f "$TMP" >/dev/null 2>&1 || true' || true
     return 0
    fi
  fi

  proot-distro login iiab -- env DEST="$dest" TMP="$tmp" bash -lc '
    set -e
    mkdir -p "$(dirname "$DEST")"
    if [ -f "$DEST" ]; then
      ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
      mv -f "$DEST" "${DEST}.old.${ts}" 2>/dev/null || true
    fi
    install -m 0755 "$TMP" "$DEST"
    rm -f "$TMP" >/dev/null 2>&1 || true
  ' || { warn_red "Failed to finalize iiab-android install inside proot."; return 1; }

  ok "Installed inside proot: $dest"
  ok "Next (inside proot): iiab-android"
}

all_a14plus_optional_adb() {
  # Android 14+: ADB is optional. If already connected, run checks (no prompts).
  local serial=""

  if have adb; then
    adb start-server >/dev/null 2>&1 || true
    if serial="$(adb_pick_loopback_serial 2>/dev/null)"; then
      ok "ADB already connected: $serial (running checks, no prompts)."
      check_readiness || true
      return 0
    fi
  fi

  # Not connected -> ask whether to skip ADB flows
  if tty_yesno_default_y "[iiab] Android 14+: Skip ADB pairing/connect steps? [Y/n]: "; then
    warn "Skipping ADB steps (Android 14+)."
    warn "Reminder: enable Developer Options -> 'Disable child process restrictions' (otherwise installs may fail)."
    CHECK_NO_ADB=1
    CHECK_SDK="${ANDROID_SDK:-}"
    return 0
  fi

  # User wants ADB even on A14+: proceed
  adb_pair_connect_if_needed
  check_readiness || true
  return 0
}

validate_args() {
  if [[ -n "${CONNECT_PORT:-}" ]]; then
    local raw="$CONNECT_PORT" norm=""
    norm="$(normalize_port_5digits "$raw" 2>/dev/null)" || \
      die "Invalid --connect-port (must be 5 digits PORT or IP:PORT): '$raw'"
    CONNECT_PORT="$norm"
    case "$MODE" in
      adb-only|with-adb|connect-only|ppk-only|check|all) : ;;
      baseline)
        log "--connect-port requires an ADB mode."
        die "Use along with: --adb-only / --with-adb / --connect-only / --check / --ppk-only / --all"
        ;;
      *)
        die "--connect-port is not valid with mode=$MODE"
        ;;
    esac
  fi
}

# Android 12-13 only (SDK 31-33): apply PPK tuning automatically
attempt_auto_apply_ppk() {
  local sdk="${ANDROID_SDK:-}"
  if [[ "$sdk" =~ ^[0-9]+$ ]] && (( sdk >= 31 && sdk <= 33 )); then
    log "Android SDK=${sdk} detected -> applying --ppk automatically (12-13 rule)."
    ppk_fix_via_adb || true
  else
    log "Android SDK=${sdk:-?} -> skipping auto-PPK (only for Android 12-13)."
  fi
}

# -------------------------
# Main flows
# -------------------------
main() {
  setup_logging "$@"
  validate_args
  sanitize_timeout
  acquire_wakelock

  case "$MODE" in
    login)
      iiab_login
      return $?
      ;;
    baseline)
      step_termux_repo_select_once
      step_termux_base || baseline_bail
      step_iiab_bootstrap_default
      install_iiab_android_cmd || true
      ;;

    with-adb)
      step_termux_repo_select_once
      step_termux_base || baseline_bail
      step_iiab_bootstrap_default
      install_iiab_android_cmd || true
      adb_pair_connect_if_needed
      ;;

    adb-only)
      step_termux_base || baseline_bail
      adb_pair_connect_if_needed
      ;;

    connect-only)
      step_termux_base || baseline_bail
      adb_pair_connect
      ;;

    ppk-only)
      # No baseline, no IIAB Debian. Requires adb already available + connected.
      require_adb_connected || exit 1
      ppk_fix_via_adb || true
      ;;

    iiab-android)
      step_termux_repo_select_once
      step_termux_base || baseline_bail
      step_iiab_bootstrap_default
      install_iiab_android_cmd || true
      ;;

    check)
      step_termux_base || baseline_bail
      check_readiness || true
      ;;

    all)
      step_termux_repo_select_once
      step_termux_base || baseline_bail
      step_iiab_bootstrap_default
      install_iiab_android_cmd || true
      if [[ "${ANDROID_SDK:-}" =~ ^[0-9]+$ ]] && (( ANDROID_SDK >= 34 )); then
        all_a14plus_optional_adb
      else
        adb_pair_connect
        attempt_auto_apply_ppk
        check_readiness || true
      fi
      ;;

    *)
      die "Unknown MODE='$MODE'"
      ;;
  esac

  self_check
  ok "iiab-termux completed (mode=$MODE)."
  log "---- Mode list ----"
  log "Connect-only             --connect-only [PORT]"
  log "Pair+connect             --adb-only [--connect-port PORT]"
  log "Login (proot)            --login"
  log "Check                    --check"
  log "Apply PPK                --ppk-only"
  log "Base+IIAB Debian+Pair+connect --with-adb"
  log "Full run                 --all"
  log "Reset IIAB Debian env    --reset-iiab"
  log "-------------------"
  final_advice
}

main "$@"
