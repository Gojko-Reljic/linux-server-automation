#!/usr/bin/env bash
#
# common.sh
# ---------------------------------------------------------------------
# Purpose: Shared helpers for all server-automation scripts: logging,
#          precondition checks, config-line parsing and OS detection.
# Called from: sourced by every script in scripts/ (never executed
#          directly).
# Usage:   source "${SCRIPT_DIR}/lib/common.sh"
# Env:     none
# ---------------------------------------------------------------------
# Security: this file runs with the privileges of whoever sources it
# (root). It must be root-owned and not writable by group or others.
# ---------------------------------------------------------------------

set -euo pipefail

# --- Colors and logging -----------------------------------------------

readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_RESET='\033[0m'

# %b interprets the escape codes in the color variables, %s prints the
# message literally. Warnings and errors go to stderr so they stay
# visible when stdout is redirected to a file.
log_info()    { printf '%b[INFO]%b %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"; }
log_success() { printf '%b[SUCCESS]%b %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"; }
log_warn()    { printf '%b[WARN]%b %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2; }
log_error()   { printf '%b[ERROR]%b %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2; }
die()         { log_error "$*"; exit 1; }

# --- Preconditions ----------------------------------------------------

require_root() {
  (( EUID == 0 )) || die 'This script must be run as root (use sudo).'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

# /run/systemd/system exists only when systemd is PID 1. This is a
# stronger guarantee than `command -v systemctl`, which only proves the
# binary is installed.
require_systemd() {
  [[ -d /run/systemd/system ]] || die 'systemd is not the active init system (no /run/systemd/system).'
}

# Checks effective capabilities, not just EUID 0: root inside a
# restricted container may lack CAP_NET_ADMIN (bit 12) or CAP_SYS_ADMIN
# (bit 21), and later steps would fail with confusing errors.
require_capabilities() {
  local cap_hex mask
  cap_hex=$(awk '/^CapEff:/ {print $2}' /proc/self/status)
  [[ -n $cap_hex ]] || die 'Unable to read effective capabilities from /proc/self/status.'
  mask=$((16#$cap_hex))
  (( (mask >> 12) & 1 )) || die 'Missing CAP_NET_ADMIN; required for firewall and network configuration.'
  (( (mask >> 21) & 1 )) || die 'Missing CAP_SYS_ADMIN; required for system-level configuration.'
}

# Rejects symlinks (a root script must not be redirected to another
# file) and files that are not root-owned or are writable by group or
# others. World-readable (0644) is accepted on purpose, so this also
# fits /etc/ssh/sshd_config.
require_regular_secure_file() {
  local file=$1
  [[ -f $file && ! -L $file ]] || die "Required regular file not found: $file"
  local mode owner
  mode=$(stat -c '%a' "$file")
  owner=$(stat -c '%U' "$file")
  [[ $owner == root ]] || die "Security-sensitive file must be owned by root: $file"
  (( (8#$mode & 8#022) == 0 )) || die "Security-sensitive file is group/world-writable: $file"
}

# --- Config file parsing ----------------------------------------------

# Normalizes one raw config line: strips CR (CRLF files), strips
# everything from the first '#' (inline and full-line comments) and
# trims surrounding whitespace. Callers keep their own read loop so
# error messages can include the line number.
normalize_config_line() {
  local line=$1
  line=${line%$'\r'}
  line=${line%%#*}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  printf '%s' "$line"
}
# --- OS detection -----------------------------------------------------

# /etc/os-release is parsed with awk and never sourced, so its content
# can never be executed as shell code under root. The variables are made
# readonly afterwards, which also means this function can run only once
# per process.
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