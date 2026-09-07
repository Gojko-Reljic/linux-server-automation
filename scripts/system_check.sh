#!/usr/bin/env bash
#
#system_check.sh
#---------------------------------------------------------------------
# Purpose: Detects the operating system and validates that the server
#          meets minimum requirements before provisioning continues.
# Called from: deploy.sh
#---------------------------------------------------------------------

set -euo pipefail

# --- Minimum requirements for the server

MIN_RAM_MB=512
MIN_DISK_GB=5
SUPPORTED_OS=("ubuntu" "debian")

readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_RESET='\033[0m'

log_info() {
    echo -e "${COLOR_GREEN}[INFO]${COLOR_RESET} $*"
}
log_error(){
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

detect_os() {

    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot find /etc/os-release. Unknown OS."
        exit 1
    fi 

    # shellcheck disable=SC1091
    source /etc/os-release

    OS_NAME="${ID}"
    OS_VERSION="${VERSION_ID}"

    log_info "Detected OS: ${OS_NAME} ${OS_VERSION}"

    local is_supported=false

    for os in "${SUPPORTED_OS[@]}"; do
        if [[ "${OS_NAME}" == "${os}" ]]; then
            is_supported=true
            break
        fi
    done

    if [[ "${is_supported}" == false ]]; then
        log_error " OS '${OS_NAME}' is not supported. Supported: ${SUPPORTED_OS[*]}"
        exit 1
    fi
}

check_ram() {

    local total_ram_kb
    total_ram_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)

    local total_ram_mb=$((total_ram_kb/1024))

    log_info "Total RAM: ${total_ram_mb} MB"

    if (( total_ram_mb < MIN_RAM_MB )); then
        log_error "Not enough RAM. Required: ${MIN_RAM_MB}MB, available: ${total_ram_mb}MB"
        exit 1
    fi
}

check_disk_space() {

    local available_kb
    available_kb=$(df --output=avail / | tail -n 1 | tr -d ' ')

    local available_gb=$(( available_kb /1024 /1024 ))

    log_info "Free disk space: ${available_gb} GB"

    if (( available_gb < MIN_DISK_GB )); then
        log_error "Not enough disk space. Required: ${MIN_DISK_GB}GB, available: ${available_gb}GB"
        exit 1
    fi
}

check_root_privileges() {

    if(( EUID != 0 )); then
        log_error "This script must be run with root privilages."
        exit 1
    fi
    log_info "Root privileges: OK"

}

main() {

    log_info "=== Running system check ==="

    check_root_privileges
    detect_os
    check_ram
    check_disk_space

    log_info "=== System check completed successfully ==="

}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 