#!/usr/bin/env bash
#
# install_nginx.sh
# ---------------------------------------------------------------------
# Purpose: Installs or updates Nginx, makes sure the service runs and is
#          enabled at boot, and verifies that it really answers HTTP.
# Called from: deploy.sh
# Usage:   sudo ./scripts/install_nginx.sh
# Env:     NGINX_PACKAGE_VERSION  pin nginx and nginx-common to this exact
#                                 APT version (default: newest available)
# ---------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# --- Configuration ----------------------------------------------------

# Empty means "install the newest version available". Set it to pin both
# packages to one exact APT version (see install_nginx_package).
readonly NGINX_PACKAGE_VERSION=${NGINX_PACKAGE_VERSION:-}

# --- Checks -----------------------------------------------------------

# The value ends up as an APT argument ("nginx=VERSION"). Allow only the
# characters that appear in Debian versions (letters, digits . + : ~ -),
# so a typo fails here with a clear message instead of inside apt-get.
validate_package_version() {

  if [[ -z $NGINX_PACKAGE_VERSION ]]; then
    return 0
  fi
  [[ $NGINX_PACKAGE_VERSION =~ ^[A-Za-z0-9.+:~-]+$ ]] \
    || die "Invalid NGINX_PACKAGE_VERSION: $NGINX_PACKAGE_VERSION"
  log_info "Nginx will be pinned to version $NGINX_PACKAGE_VERSION."

}

# Runs before the install, so a conflict is reported before anything changes.
# Nginx itself is allowed, so re-running the script on a working server does
# not fail. ss -p needs root to show the owner of each listener.
check_port_80(){

    local listeners foreign
    listeners=$(ss -Hltnp 'sport = :80')
    foreign=$(grep -v 'users:(("nginx"' <<<"$listeners" || true)
    [[ -z $foreign ]] || die "Port 80 is already in use by another process: $foreign"

}

# --- Installation -----------------------------------------------------

# nginx depends on nginx-common of exactly the same version, so a pin has to
# name both packages; pinning only nginx makes APT fail on that dependency.
# apt-get install is idempotent: it installs a missing package, upgrades an
# installed one and does nothing when it is current. With -y APT refuses a
# downgrade, so an old pin cannot silently downgrade a server.
# Dpkg::Lock::Timeout waits for a lock held by another process (for example
# unattended-upgrades), Acquire::Retries repeats failed downloads, and
# --force-confold keeps an edited nginx.conf instead of asking about it.
install_nginx_package() {

     # An array keeps each package a separate argument for apt-get.
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

# nginx -t runs first: a broken configuration stops the script before the
# service is enabled or touched. "enable --now" enables the unit at boot and
# starts it, and changes nothing when the service already runs.
start_and_enable_nginx() {

     log_info "Validating configuration and starting Nginx..."
     nginx -t
     systemctl enable --now nginx
     systemctl is-active --quiet nginx \
        || die "Nginx service is not active. Inspect: systemctl status nginx; journalctl -u nginx"
    log_success "Nginx service started and enabled at boot."

}

# --- Verification -----------------------------------------------------

# One HEAD request to 127.0.0.1 ("localhost" depends on name resolution).
# --noproxy '*' ignores proxy variables and the timeouts keep a hung server
# from blocking the script. Status 200 alone is not enough: any web server on
# port 80 would pass, so the Server header must say nginx.
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

# The check above goes through the loopback interface, which UFW does not
# filter, so it succeeds even when the firewall blocks port 80 for other
# hosts. This only warns; it never changes firewall rules.
# The status is kept in a variable instead of piped into grep -q, because
# grep -q can exit early and pipefail can then report a false failure.
warn_if_ufw_blocks_http() {

    command -v ufw >/dev/null 2>&1 || return 0
    local ufw_status
    ufw_status=$(ufw status)
    [[ $ufw_status == *'Status: active'* ]] || return 0
    # Matches "80/tcp", "80" and "80,443/tcp", but not "8080/tcp", and the
    # "Nginx ..." application profiles.
    grep -qE '^(80([/, ]|$)|Nginx)' <<< "$ufw_status" \
        || log_warn "UFW is active but no rule for port 80 was found; Nginx may be unreachable from other hosts."

}

# Every check runs before the first command that changes the system.
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

