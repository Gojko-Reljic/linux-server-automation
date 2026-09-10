#!/usr/bin/env bash
#
#install_nginx.sh
#---------------------------------------------------------------------
#Purpose: Installs Nginx, ensures the service is running and enabled
#         at boot, and verifies it actually responds to HTTP requests.
#
#Called from:  deploy.sh
#---------------------------------------------------------------------

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

install_nginx_package() {

    if command -v nginx $>/dev/null; then
        log_info "Nginx is already installed"
    else
        log_info "Installing Nginx..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y nginx
        log_success "Nginx installed."
    fi

}

start_and_enable_nginx() {

    log_info "Starting and enabling Nginx service ..."
    systemctl enable --now nginx
    log_success "Nginx service started and enabled at boot."

}

verify_nginx_responds() {

    log_info "Verifying Nginx responds to HTTP requests ..."

    local http_status
    http_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost)

    if [[ "${http_status}" == "200" ]]; then
        log_success "Nginx responded with HTTP 200 ok."
    else
        log_error "Nginx did not respond as expended (got HTTP ${http_status})"
        exit 1
    fi

}

main() {

    if (( EUID != 0 )); then
        log_error "This scripts must be run with root privileges."
        exit 1
    fi

    log_info "=== Installing Nginx ==="

    install_nginx_package
    start_and_enable_nginx
    verify_nginx_responds

    log_info "=== Nginx installation completed successfully ==="

}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi