#!/usr/bin/env bash
#
#configure_firewall.sh
#-------------------------------------------------------------------
#Purpose:  Installs and configures ufw. Denies all incoming traffic 
#          by default, then explicitly allows the ports listed in 
#          config/firewall.conf (SSH is allowed FIRST,
#          before the firewall is enabled, to avoid locking 
#          ourselves out).
#Called from: deploy.sh
#-------------------------------------------------------------------

set -euo pipefail

readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_RESET='\033[0m'

log_info() {
    echo -e "${COLOR_GREEN}[INFO]${COLOR_RESET} $*"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIREWALL_CONFIG="${SCRIPT_DIR}/../config/firewall.conf"

ensure_ufw_installed() {

    if command -v ufw &>/dev/null; then
        log_info "ufw is already installed."
    else
        log_info "Installing ufw..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y ufw
        log_success "ufw installed."
    fi

}

set_default_policies() {

    log_info "Setting default firewall policies..."
    ufw default deny incoming
    ufw default allow outgoing

}

allow_configured_ports() {

    if [[ ! -f "${FIREWALL_CONFIG}" ]]; then
        log_error "Firewall config files not found: ${FIREWALL_CONFIG}"
        exit 1
    fi

    log_info "Allowing ports from ${FIREWALL_CONFIG}..."

    while IFS= read -r port_rule || [[ -n "${port_rule}" ]]; do
        #skip blank lines
        [[ -z "${port_rule}" ]] && continue

        #skip comment lines
        [[ "${port_rule}" == \#* ]] && continue

        ufw allow "${port_rule}"
        log_info "Allowed port rule: ${port_rule}"
    done < "${FIREWALL_CONFIG}"

}

enable_firewall() {

    ufw --force enable
    log_success "Firewall enabled."

}

main() {

    if (( EUID != 0)); then
        log_error "This script must be run with root privileges."
        exit 1
    fi

    log_info "=== Configuring firewall ==="

    ensure_ufw_installed
    set_default_policies
    allow_configured_ports
    enable_firewall

    log_info "=== Firewall configuration completed successfully ==="

}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
