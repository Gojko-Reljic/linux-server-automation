#!/usr/bin/env bash
#
#configure_ssh.sh
#-----------------------------------------------------------------------
#Purpose:   Hardens SSH configuration - disables root login and password
#           authentication, forcing key-based auth only. Validates the
#           new config before restarting ssh, to avoid locking ourselves
#           out on a syntax error.
#Called from: deploy.sh
#-----------------------------------------------------------------------

set -euo pipefail

readonly COLOR_GREEN="\033[0;32m"
readonly COLOR_RED="\033[0;31m"
readonly COLOR_RESET="\033[0m"

log_info() {
    echo -e "${COLOR_GREEN}[INFO]${COLOR_RESET} $*"
}
log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2 
}
log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*"
}

SSH_CONFIG="/etc/ssh/sshd_config"
readonly SSH_CONFIG
SSH_CONFIG_BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
readonly SSH_CONFIG_BACKUP

backup_ssh_config() {

    if [[ ! -f "$SSH_CONFIG" ]]; then
        log_error "SSH config file not found: ${SSH_CONFIG}"
        exit 1
    fi

    cp "${SSH_CONFIG}" "${SSH_CONFIG_BACKUP}"
    log_success "Backed up SSH config to ${SSH_CONFIG_BACKUP}"

}

set_ssh_option() {
    # Arguments: $1 = the SSH option name (e.g. "PermitRootLogin")
    #            $2 = the desired value (e.g. "no")

    local option="$1"
    local value="$2"

    if grep -qE "^#?${option}\s" "${SSH_CONFIG}"; then
        # The option already exists in the file  -
        # replace that whole line with our desired setting.
        sed -i "s|^#\?${option}\s.*|${option} ${value}|" "${SSH_CONFIG}"
    else
        # The option doesn't exist at all - append it to the end.
        echo "${option} ${value}" >> "${SSH_CONFIG}"
    fi

    log_info "Set '${option} ${value}' in SSH config."

}

validate_ssh_config() {

    # sshd -t tests the config file for syntax errors WITHOUT applying
    # it or restarting anything. This is our safety check before we
    # dare to restart the SSH service.

    if ! sshd -t; then
        log_error "SSH config validation failed! Restoring backup ..."
        cp "${SSH_CONFIG_BACKUP}" "${SSH_CONFIG}"
        log_error "Backup restored. SSH was NOT restored, original config is intact."
        exit 1
    fi

    log_success "SSH config validation passed."

}

restart_ssh_service() {

    if systemctl restart ssh 2>/dev/null; then
        log_success "SSH service restarted successfully."
    elif systemctl restart sshd 2>/dev/null; then
        log_success "SSH ervice (sshd) restarted successfully."
    else 
        log_error "Failed to restart SSH service."
        exit 1
    fi

}

main() {

    if (( EUID != 0 )); then
        log_error "This script must be run with root privileges."
        exit 1
    fi

    log_info "=== Configuring SSH ==="

    backup_ssh_config

    set_ssh_option "PermitRootLogin" "no"
    set_ssh_option "PasswordAuthentication" "no"

    validate_ssh_config
    restart_ssh_service

    log_info "=== SSH configuration completed successfully ==="

}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi