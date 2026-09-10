#!/usr/bin/env bash
#
# install_docker.sh
# -----------------------------------------------------------------------
# Purpose: Installs Docker CE from Docker's official APT repository
#          (not Ubuntu's, which often lags behind). Verifies the
#          installation by running the hello-world test container.
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

setup_docker_repository() {
    if command -v docker &>/dev/null; then
        log_info "Docker is already installed, skipping repository setup."
        return 0
    fi

    log_info "Setting up Docker's official APT repository..."

    export DEBIAN_FRONTEND=noninteractive


    # Prerequisites needed to add an HTTPS-based APT repository
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg


    # Create the directory for APT keyrings if it doesn't already exist
    install -m 0755 -d /etc/apt/keyrings


    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    
    local ubuntu_codename
    #shellcheck disable=SC1091
    ubuntu_codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${ubuntu_codename} stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y

    log_success "Docker repository configured."
}

install_docker_packages() {

    log_info "Installing Docker packages..."

    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    log_success "Docker packages installed."

}

start_and_enable_docker() {

    log_info "Starting and enabling Docker service..."
    systemctl enable --now docker
    log_success "Docker service started and enabled at boot."

}

verify_docker_works() {

    log_info "Verifying Docker works by running the hello-world container..."

    if docker run --rm hello-world &>/dev/null; then
        log_success "Docker successfully ran the hello-world container."
    else
        log_error "Docker failed to run the hello-world test container."
        exit 1
    fi

}

main() {
    
    if (( EUID != 0 )); then
        log_error "This script must be run with root privileges (use sudo)."
        exit 1
    fi

    log_info "=== Installing Docker ==="

    setup_docker_repository
    install_docker_packages
    start_and_enable_docker
    verify_docker_works

    log_info "=== Docker installation completed successfully ==="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi