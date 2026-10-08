#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

readonly NGINX_PACKAGE_VERSION=${NGINX_PACKAGE_VERSION:-}

validate_package_version() {

  if [[ -z $NGINX_PACKAGE_VERSION ]]; then
    return 0
  fi
  [[ $NGINX_PACKAGE_VERSION =~ ^[A-Za-z0-9.+:~-]+$ ]] \
    || die "Invalid NGINX_PACKAGE_VERSION: $NGINX_PACKAGE_VERSION"
  log_info "Nginx will be pinned to version $NGINX_PACKAGE_VERSION."

}

check_port_80(){

    local listeners foreign
    listeners=$(ss -Hltnp 'sport = :80')
    foreign=$(grep -v 'users:(("nginx"' <<<"$listeners" || true)
    [[ -z $foreign ]] || die "Port 80 is already in use by another process: $foreign"

}


install_nginx_package() {

    local -a packages=(nginx)
    if [[ -n $NGINX_PACKAGE_VERSION ]]; then
        packages=("nginx=$NGINX_PACKAGE_VERSION" "nginx-common=$NGINX_PACKAGE_VERSION")
    fi

    log_info "Installing or updating Nginx..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o Dpkg::Lock::Timeout=120 -o Acquire::Retries=3 update
    apt-get -o Dpkg::Lock::Timeout=120 -o Acquire::Retries=3 \
        -o Dpkg::Options::=--force-confold install -y "${packages[@]}"
    log_success "Nginx package installed."

}

start_and_enable_nginx() {

     log_info "Validating configuration and starting Nginx..."
     nginx -t
     systemctl enable --now nginx
     systemctl is-active --quiet nginx \
        || die "Nginx service is not active. Inspect: systemctl status nginx; journalctl -u nginx"
    log_success "Nginx service started and enabled at boot."

}

verify_nginx_responds() {

    log_info "Verifying Nginx responds to HTTP requests ..."

    local response
    response=$(curl --noproxy '*' --connect-timeout 3 --max-time 5 --silent --show-error \
        --head http://127.0.0.1/) \
        || die "Local HTTP check failed. Nginx is installed and enabled; inspect: journalctl -u nginx"

    local ok_pattern='^HTTP/[0-9.]+ 200'
    [[ $response =~ $ok_pattern ]] \
        || die "Local HTTP check did not return HTTP 200. Nginx is installed and enabled; inspect: journalctl -u nginx"
    grep -qi '^server: nginx' <<<"$response" \
        || die "Response has no nginx Server header; another service may be answering on port 80."

    log_success "Nginx responded with HTTP 200."

}

warn_if_ufw_blocks_http() {

    command -v ufw >/dev/null 2>&1 || return 0
    local ufw_status
    ufw_status=$(ufw status)
    [[ $ufw_status == *'Status: active'* ]] || return 0
    grep -qE '^(80([/, ]|$)|Nginx)' <<< "$ufw_status" \
        || log_warn "UFW is active but no rule for port 80 was found; Nginx may be unreachable from other hosts."

}

main() {

    require_root
    read_os_release
    is_supported_debian_family || die "Unsupported OS for Nginx: $OS_ID"
    require_systemd
    require_command curl
    require_command ss
    validate_package_version
    check_port_80


    log_info "=== Installing Nginx ==="

    install_nginx_package
    start_and_enable_nginx
    verify_nginx_responds
    warn_if_ufw_blocks_http

    log_success "=== Nginx installation completed successfully ==="

}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

