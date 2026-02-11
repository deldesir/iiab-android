# shellcheck shell=bash
# Module file (no shebang). Bundled by build_bundle.sh

# Arch specific helpers to manage broader phone support for IIAB on Android.
# This is a best-effort approach, as 32 bits might hit hardwalls on the future.

# -------------------------
# Detect 32bits processor
# -------------------------
is_32bits() {
  local bits
  bits="$(getconf LONG_BIT 2>/dev/null || true)"
  [ "$bits" = "32" ]
}

# -------------------------
# Enable deb-src repositories for apt 3.0+ on Debian like OS.
# -------------------------
apt3_enable_sources() {
  # Require apt >= 3.0
  local apt_ver
  apt_ver="$(apt -v 2>/dev/null | awk '{print $2}' | cut -d. -f1-2)"
  if [ -z "$apt_ver" ]; then
    echo "ERROR: couldn't detect apt version" >&2
    return 1
  fi
  if ! dpkg --compare-versions "$apt_ver" ge "3.0"; then
    echo "ERROR: apt >= 3.0 required (found $apt_ver)" >&2
    return 1
  fi

  local apt_src_dir="/etc/apt/sources.list.d"
  local distro="" f=""

  # Load /etc/os-release
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    distro="${ID:-}"
  fi
  if [ -z "$distro" ]; then
    echo "ERROR: couldn't determine ID from /etc/os-release" >&2
    return 1
  fi

  apt modernize-sources -y

  # Prefer /etc/apt/sources.list.d/<ID>.sources, else fallback to first *.sources
  if [ -f "$apt_src_dir/$distro.sources" ]; then
    f="$apt_src_dir/$distro.sources"
  else
    f="$(ls -1 "$apt_src_dir"/*.sources 2>/dev/null | head -n 1 || true)"
  fi
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    echo "ERROR: no .sources file found under $apt_src_dir" >&2
    return 1
  fi

  # Backup
  cp -a "$f" "$f.bak"

  # Add deb-src to any Types: line that has deb but not deb-src
  sed -i -E '/^[[:space:]]*Types:[[:space:]]*/{
    /deb-src/! s/\bdeb\b/& deb-src/
  }' "$f"

  apt-get update
}

