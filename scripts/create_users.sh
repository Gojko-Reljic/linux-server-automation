#!/usr/bin/env bash
#
#create_users.sh
#---------------------------------------------------------------------------
# Purpose:  Creates system users listed in config/users.conf, adds them
#           to the sudo group, and prepares their .ssh directory.
#           Safe to run multiple times -existing users are skipped,
#           not recreated.
#
# Called from:  deploy.sh
#---------------------------------------------------------------------------

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
USERS_CONFIG="${SCRIPT_DIR}/../config/users.conf"


check_config_exists() {
    if [[ ! -f "${USERS_CONFIG}" ]]; then
        log_error "Config file not found: ${USERS_CONFIG}"
        exit 1
    fi
}

create_single_user() {

    local username="$1"

    if id -u "${username}" &>/dev/null; then
        log_info "User '${username}' already exists, skipping creation."
    else
        useradd -m -s /bin/bash "${username}"
        log_success "Created user '${username}'."
    fi

    usermod -aG sudo "${username}"

    local ssh_dir="/home/${username}/.ssh"
    if [[ ! -d "${ssh_dir}" ]]; then
        mkdir -p "${ssh_dir}"
        chmod 700 "${ssh_dir}"
        chown "${username}:${username}" "${ssh_dir}"
        log_info "Created .ssh directory for '${username}'."
    fi
}

create_all_users() {

    log_info "Reading users from ${USERS_CONFIG}..."

    while IFS= read -r username || [[ -n "${username}" ]]; do
        [[ -z "${username}" ]] && continue
        [[ "${username}" == \#* ]] && continue

        create_single_user "${username}"
    done<"${USERS_CONFIG}" 
}

main() {

    if (( EUID !=0 )); then
        log_error "This sript must be run with root privileges."
        exit 1
    fi

    log_info "=== Creating users ==="
    
    check_config_exists
    create_all_users

    log_info "=== User creation completed successfully ==="

}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

