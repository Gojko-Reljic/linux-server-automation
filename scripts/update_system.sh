#!/usr/bin/env bash
#
# update_system.sh
# -----------------------------------------------------------------------
# Purpose: Updates the package list and upgrades all installed packages
#          to their latest available versions. Runs non-interactively,
#          since this must work unattended during automated provisioning.
#
# Called from: deploy.sh 
# -----------------------------------------------------------------------

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


update_package_list() {

    log_info "Updating package list ..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y

}

upgrade_packages() {

    log_info "Upgrading intalled packages ..."

    if ! apt-get upgrade -y \
        -o 'Dpkg::Options::=--force-confdef' \
        -o 'Dpkg::Options::=--force-confold'; then

        log_error "Package upgrade failed ..."
        return 1
    fi

    log_success "Packages upgraded successfully. "
    
}

cleanup_packages() {
    log_info "Removing unused packages ..."
    apt-get autoremove -y

}

main() {

    log_info "=== Starting system update ==="

    update_package_list
    upgrade_packages
    cleanup_packages

    log_info "=== System update completed successfully ==="

}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
    