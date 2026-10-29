#!/usr/bin/env bash
#
# install_docker.sh
# ---------------------------------------------------------------------
# Purpose: Installs Docker CE from Docker's official APT repository and
#          checks that the daemon responds. No test image is pulled.
# Called from: deploy.sh
# Usage:   sudo ./install_docker.sh
# Env:     DOCKER_VERSION         optional; pins docker-ce and
#                                 docker-ce-cli (default: latest)
#          ALLOW_DOCKER_WITH_UFW  must be "true" to install while UFW is
#                                 active (default: false)
# ---------------------------------------------------------------------
# Security: runs as root and trusts only the Docker signing key whose
# fingerprint is hardcoded below; any other key aborts the install.
# ---------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# --- Configuration ----------------------------------------------------

readonly DOCKER_VERSION=${DOCKER_VERSION:-}
readonly ALLOW_DOCKER_WITH_UFW=${ALLOW_DOCKER_WITH_UFW:-false}
# Fingerprint of Docker's release signing key, as published in Docker's
# official installation documentation.
readonly DOCKER_KEY_FINGERPRINT='9DC858229FC7DD38854AE2D88D81803C0EBFCD88'
readonly DOCKER_KEYRING=/etc/apt/keyrings/docker.asc
readonly DOCKER_SOURCE=/etc/apt/sources.list.d/docker.list
# Wait up to 120 s for the dpkg lock; retry failed downloads 3 times.
readonly -a APT_OPTS=(-o Dpkg::Lock::Timeout=120 -o Acquire::Retries=3)

# --- Cleanup ----------------------------------------------------------

# Global on purpose: the EXIT trap runs after function locals are gone,
# and `set -u` would treat them as unset.
TMP_DIR=''

cleanup() {

    if [[ -n $TMP_DIR ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

trap cleanup EXIT

# --- Preconditions ----------------------------------------------------

# Stops if Ubuntu/Debian Docker packages are installed (they conflict
# with Docker CE and may hold data) or if UFW is active without explicit
# acknowledgement.
check_conflict_and_firewall() {

    local package pkg_status ufw_status

    for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
        pkg_status=$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)
        if [[ $pkg_status == ii* ]]; then
            die "Conflicting package installed: $package. Review its workloads/data and remove it explicitly before installing Docker CE."
        fi
    done

    if command -v ufw >/dev/null 2>&1; then
        # LC_ALL=C: ufw output is translated. A variable, not a pipe:
        # `grep -q` can end a pipe early (SIGPIPE) and pipefail would
        # then fail the check.
        ufw_status=$(LC_ALL=C ufw status)
        if [[ $ufw_status == 'Status: active'* ]]; then
            [[ $ALLOW_DOCKER_WITH_UFW == true ]] || die "UFW is active. Docker-published ports can bypass UFW; create and verify a DOCKER-USER chain policy, then set ALLOW_DOCKER_WITH_UFW=true."
            log_warn 'Proceeding with UFW and Docker only by explicit acknowledgement; DOCKER-USER chain policy remains your responsibility.'
        fi
    fi
}

# --- Installation -----------------------------------------------------

install_prerequisites() {

    apt-get "${APT_OPTS[@]}" update
    apt-get "${APT_OPTS[@]}" install -y --no-upgrade --no-install-recommends ca-certificates curl gnupg

}

install_repository() {

    require_command curl
    require_command gpg
    require_command dpkg
    install -d -m 0755 /etc/apt/keyrings

    local key_file source_file fingerprints arch

    TMP_DIR=$(mktemp -d)
    key_file="$TMP_DIR/docker.asc"
    source_file="$TMP_DIR/docker.list"

    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "https://download.docker.com/linux/$OS_ID/gpg" --output "$key_file"

    # APT trusts every key in a signed-by file, so the file must contain
    # exactly one primary key: the expected one. Only fpr lines right
    # after a pub line are printed, which skips subkey fingerprints.
    fingerprints=$(gpg --show-keys --with-colons "$key_file" \
        | awk -F: '$1 == "pub" {primary = 1; next} $1 == "fpr" && primary {print toupper($10); primary = 0}') \
        || die 'Could not read the downloaded Docker signing key.'
    [[ $fingerprints == "$DOCKER_KEY_FINGERPRINT" ]] || die "Downloaded Docker key does not contain exactly the expected signing key."
    arch=$(dpkg --print-architecture)
    printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/%s %s stable\n' \
    "$arch" "$DOCKER_KEYRING" "$OS_ID" "$OS_CODENAME" > "$source_file"

    if [[ -e $DOCKER_SOURCE ]] && ! cmp -s "$source_file" "$DOCKER_SOURCE"; then
        die "Existing Docker APT source differs: $DOCKER_SOURCE (refusing to overwrite it)."
    fi

    # Nothing is written under /etc until every check above has passed.
    install -m 0644 "$key_file" "$DOCKER_KEYRING"
    install -m 0644 "$source_file" "$DOCKER_SOURCE"

}

install_docker() {

    local -a packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
    local package installed

    if [[ -n $DOCKER_VERSION ]]; then
        # Docker publishes one Engine/CLI version string; plugin
        # versions differ.
        packages[0]="docker-ce=$DOCKER_VERSION"
        packages[1]="docker-ce-cli=$DOCKER_VERSION"
        log_info 'DOCKER_VERSION pins docker-ce and docker-ce-cli only; containerd.io, buildx and compose follow the repository candidate.'
    else
        log_warn 'DOCKER_VERSION is unset; installing the current repository candidate of every Docker package.'
    fi

    apt-get "${APT_OPTS[@]}" update
    # --no-upgrade stops a re-run from upgrading a running Docker.
    # The check below catches an installed version that differs from
    # the pin.
    apt-get "${APT_OPTS[@]}" install -y --no-upgrade "${packages[@]}"

    if [[ -n $DOCKER_VERSION ]]; then
        for package in docker-ce docker-ce-cli; do
            installed=$(dpkg-query -W -f='${Version}' "$package")
            [[ $installed == "$DOCKER_VERSION" ]] || die "Installed $package is $installed, expected $DOCKER_VERSION. No upgrade or downgrade was performed."
        done
    fi

}

# --- Verification -----------------------------------------------------

# No automatic `systemctl disable` on failure: it could switch off a
# service the admin enabled earlier. Full rollback is planned for V2.
verify_docker() {

    systemctl enable --now docker || die "Failed to enable/start docker. Inspect: systemctl status docker; journalctl -u docker."
    systemctl is-active --quiet docker || die "Docker service is not active."
    docker version --format '{{.Server.Version}}' >/dev/null || die "Docker daemon did not respond."

    log_success "Docker daemon responded; no remote test image was executed."

}

# --- Main -------------------------------------------------------------

# nothing on disk changes until they all pass.
main() {

    require_root
    read_os_release
    is_supported_debian_family || die "Unsupported OS for Docker: $OS_ID"
    [[ -n ${OS_CODENAME:-} ]] || die "Docker repository requires VERSION_CODENAME."

    require_systemd
    require_capabilities

    export DEBIAN_FRONTEND=noninteractive

    # Detach stdin from the terminal. With a terminal on stdin and
    # stdout piped, apt-get was stopped by SIGTTOU and the install
    # hung. The script never reads input.
    exec < /dev/null

    check_conflict_and_firewall
    install_prerequisites
    install_repository
    install_docker
    verify_docker
    log_success "=== Docker installation completed successfully ==="

}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi