#!/usr/bin/env bash
# Shared helpers for server-automation scripts. This file must be root-owned
# and must not be writable by group or other users.
set -euo pipefail

readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_RESET='\033[0m'

log_info()    { printf '%b[INFO]%b %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"; }
log_success() { printf '%b[SUCCESS]%b %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"; }
log_warn()    { printf '%b[WARN]%b %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2; }
log_error()   { printf '%b[ERROR]%b %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2; }
die()         { log_error "$*"; exit 1; }

require_root() {
  (( EUID == 0 )) || die 'This script must be run as root (use sudo).'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

# /run/systemd/system exists only when systemd is PID 1, which is a stronger
# guarantee than `command -v systemctl` (that only proves the binary exists).
require_systemd() {
  [[ -d /run/systemd/system ]] || die 'systemd is not the active init system (no /run/systemd/system).'
}

# Checks effective capabilities beyond EUID 0: root inside a restricted
# container may lack CAP_NET_ADMIN (bit 12) or CAP_SYS_ADMIN (bit 21).
require_capabilities() {
  local cap_hex mask
  cap_hex=$(awk '/^CapEff:/ {print $2}' /proc/self/status)
  [[ -n $cap_hex ]] || die 'Unable to read effective capabilities from /proc/self/status.'
  mask=$((16#$cap_hex))
  (( (mask >> 12) & 1 )) || die 'Missing CAP_NET_ADMIN; required for firewall and network configuration.'
  (( (mask >> 21) & 1 )) || die 'Missing CAP_SYS_ADMIN; required for system-level configuration.'
}

require_regular_secure_file() {
  local file=$1
  [[ -f $file && ! -L $file ]] || die "Required regular file not found: $file"
  local mode owner
  mode=$(stat -c '%a' "$file")
  owner=$(stat -c '%U' "$file")
  [[ $owner == root ]] || die "Security-sensitive file must be owned by root: $file"
  (( (8#$mode & 8#022) == 0 )) || die "Security-sensitive file is group/world-writable: $file"
}

# Normalizes one raw config line: strips CR, strips everything from the first
# '#' onward (inline and full-line comments), trims surrounding whitespace.
normalize_config_line() {
  local line=$1
  line=${line%$'\r'}
  line=${line%%#*}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  printf '%s' "$line"
}

read_os_release() {
  local os_file=/etc/os-release
  [[ -r $os_file ]] || die 'Cannot read /etc/os-release.'
  OS_ID=$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print tolower($2); exit}' "$os_file")
  OS_VERSION_ID=$(awk -F= '$1 == "VERSION_ID" {gsub(/"/, "", $2); print $2; exit}' "$os_file")
  OS_CODENAME=$(awk -F= '$1 == "VERSION_CODENAME" {gsub(/"/, "", $2); print $2; exit}' "$os_file")
  [[ -n ${OS_ID:-} && -n ${OS_VERSION_ID:-} ]] || die 'Incomplete /etc/os-release metadata.'
  # shellcheck disable=SC2034  # consumed by the scripts that source this file
  readonly OS_ID OS_VERSION_ID OS_CODENAME
}

is_supported_debian_family() {
  [[ ${OS_ID:-} == ubuntu || ${OS_ID:-} == debian ]]
}