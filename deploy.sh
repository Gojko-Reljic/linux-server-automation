#!/usr/bin/env  bash
#
# deploy.sh
# ----------------------------------------------------------------------
# Purpose: Main orchestration. Runs all provisioning scripts in order on
#          a fresh server and prints a summary of what succeeded/failed.
#
# Usage:   sudo .\deploy.sh
# ----------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"


readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_RESET='\033[0m'

log_info() {

    echo -e "${COLOR_GREEN}[INFO]${COLOR_RESET} $*"

}

log_error() {

    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
    
}

STEP_ORDER=()

declare -A STEP_STATUS

run_step() {
    local step_name="$1"
    local script_path="$2"

    log_info "--- Running step: ${step_name} ---"

    STEP_ORDER+=("${step_name}")

    if bash "${script_path}"; then
        STEP_STATUS["${step_name}"]=OK
    else
        STEP_STATUS["${step_name}"]="FAIL"
        log_error "Step '${step_name}' failed"
    fi
}

print_summary() {
    echo ""
    echo "=================================================================="
    echo "        Linux Server Automation "
    echo "=================================================================="
    echo""

    local overall_success=true

    for step_name in "${STEP_ORDER[@]}"; do
        local status="${STEP_STATUS[${step_name}]}"

        printf "%-30s %s\n" "${step_name} ....................." "${status}"

        if [[ "${status}" == "FAIL" ]]; then
            overall_success=false
        fi
    done

    echo ""

    if [[ "${overall_success}" == true ]]; then
        echo "Server provisioning completed."
    else
        echo "Server provisioning completed with ERRORS."
    fi

}

main() {

     if (( EUID != 0 )); then
        log_error "deploy.sh must be run with root privileges (use sudo)."
        exit 1
    fi

    log_info "Starting Linux Server Automation..."

    run_step "System Check" "${SCRIPTS_DIR}/system_check.sh"

    run_step "System Update" "${SCRIPTS_DIR}/update_system.sh"
    run_step "Users" "${SCRIPTS_DIR}/create_users.sh"
    run_step "SSH Configuration" "${SCRIPTS_DIR}/configure_ssh.sh"
    run_step "Firewall" "${SCRIPTS_DIR}/configure_firewall.sh"
    run_step "Nginx" "${SCRIPTS_DIR}/install_nginx.sh"
    # TODO: run_step "Docker" "${SCRIPTS_DIR}/install_docker.sh"
    # TODO: run_step "Logging" "${SCRIPTS_DIR}/configure_logging.sh"
    # TODO: run_step "Backup" "${SCRIPTS_DIR}/backup.sh"
    # TODO: run_step "Health Check" "${SCRIPTS_DIR}/health_check.sh"

    print_summary

}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi


