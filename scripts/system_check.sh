#!/usr/bin/env bash
#
# system_check.sh
# ---------------------------------------------------------------------
# Purpose: Detects the operating system and validates that the server
#          meets minimum requirements before provisioning continues.
# Called from: deploy.sh (as a separate process)
# Usage:   sudo ./scripts/system_check.sh
# Env:     MIN_RAM_MB   minimum usable RAM in MB (default 512)
#          MIN_DISK_GB  minimum free disk, GB (default 5)
# ---------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# --- Requirements -----------------------------------------------------

readonly MIN_RAM_MB="${MIN_RAM_MB:-512}"
readonly MIN_DISK_GB="${MIN_DISK_GB:-5}"
# Free inodes needed per mount point. A floor, not a measured need: low
# enough never to block a healthy server, high enough to catch exhaustion.
readonly MIN_FREE_INODES=1024
# /var holds packages and logs, /home user data. Missing mounts are skipped.
# /tmp is left out on purpose: it can be a small tmpfs (Debian 13 default)
# and would reject a healthy server.
readonly REQUIRED_MOUNTS=(/ /var /home)
# Releases that still get free security updates, Debian LTS included
# (checked 2026-10-11 on endoflife.date). Ubuntu: jammy to 2027-06,
# noble to 2029-05, resolute to 2031-05. Debian: bookworm to 2028-06,
# trixie to 2030-06.
readonly SUPPORTED_CODENAMES=(jammy noble resolute bookworm trixie)

# --- Checks -----------------------------------------------------------

# Thresholds can come from the environment and are used inside (( ))
# where bash evaluates their content as an expression. Accept digits only.
validate_thresholds() {

    local name
    for name in MIN_RAM_MB MIN_DISK_GB; do
        [[ ${!name} =~ ^[1-9][0-9]*$ ]] \
            || die "${name} must be a positive integer, got '${!name}'."
    done

}

# Reads os-release through read_os_release instead of `source`: sourcing would
# run the file as shell code with root privileges.
check_os() {

    read_os_release

    is_supported_debian_family \
        || die "Unsupported OS '${OS_ID}'. Supported: ubuntu, debian."

    [[ -n ${OS_CODENAME:-} ]] \
        || die "No VERSION_CODENAME found for ${OS_ID} ${OS_VERSION_ID}."

    [[ " ${SUPPORTED_CODENAMES[*]} " == *" ${OS_CODENAME} "* ]] \
        || die "Unsupported or EOL release: ${OS_ID} ${OS_VERSION_ID} (${OS_CODENAME}). Supported: ${SUPPORTED_CODENAMES[*]}"

    log_info "Detected supported OS: ${OS_ID} ${OS_VERSION_ID} (${OS_CODENAME})"

}

check_runtime() {

    require_command apt-get
    require_command systemctl
    require_systemd
    require_capabilities
    log_info "Runtime: apt-get, systemd and required capabilities: OK"

}

# Compares usable RAM with MIN_RAM_MB: MemTotal, or the cgroup limit if lower.
# MemTotal is below the nominal size, so a "512 MB" VM reports less than 512.
# Only the cgroup limit visible at /sys/fs/cgroup is read (a container's own
# limit); a systemd service MemoryMax= is not seen.
check_memory() {

    local host_kb limit cgroup_bytes=0 cgroup_kb effective_kb effective_mb

    host_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
    [[ $host_kb =~ ^[0-9]+$ ]] || die "Unable to read host memory from /proc/meminfo."

    # A container or VM can have a stricter limit than the host total.
    # cgroup v2 first, then v1. v2 says "max" for no limit; v1 uses a huge
    # number, which is harmless because the host total wins the comparison.
    if [[ -r /sys/fs/cgroup/memory.max ]]; then
        limit=$(< /sys/fs/cgroup/memory.max)
        [[ $limit == max ]] || cgroup_bytes=$limit
    elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
        cgroup_bytes=$(< /sys/fs/cgroup/memory/memory.limit_in_bytes)
    fi

    effective_kb=$host_kb
    if [[ $cgroup_bytes =~ ^[0-9]+$ ]]; then
        cgroup_kb=$(( cgroup_bytes / 1024 ))
        if (( cgroup_kb > 0 && cgroup_kb < effective_kb )); then
            effective_kb=$cgroup_kb
        fi
    fi

    effective_mb=$(( effective_kb / 1024 ))
    log_info "Effective RAM: ${effective_mb} MB"

    (( effective_mb >= MIN_RAM_MB )) \
        || die "Not enough RAM. Required: ${MIN_RAM_MB} MB, available: ${effective_mb} MB."

}

# Checks free space and free inodes on each required mount point.
check_storage() {

    local path available_kb available_inodes available_gb

    for path in "${REQUIRED_MOUNTS[@]}"; do
        [[ -d $path ]] || continue
        # -P gives one line per filesystem, so line 2 is always the data row.
        available_kb=$(df -Pk "$path" | awk 'NR == 2 {print $4}')
        available_inodes=$(df -Pi "$path" | awk 'NR == 2 {print $4}')
        [[ $available_kb =~ ^[0-9]+$ && $available_inodes =~ ^[0-9]+$ ]] \
            || die "Unable to inspect filesystem at ${path}."
        # GB is for display only; the decision below is made in KB.
        available_gb=$(( available_kb / 1024 / 1024 ))
        log_info "Free space at ${path}: ${available_gb} GB, ${available_inodes} inodes"

        (( available_kb >= MIN_DISK_GB * 1024 * 1024 )) \
            || die "Not enough disk space at ${path}. Required: ${MIN_DISK_GB} GB, available: ${available_gb} GB."

        (( available_inodes > MIN_FREE_INODES )) \
            || die "Not enough free inodes at ${path}."
    done

}

# --- Main -------------------------------------------------------------

main() {

    require_root
    validate_thresholds

    log_info "=== Running system check ==="

    check_os
    check_runtime
    check_memory
    check_storage

    log_success "=== System check completed successfully ==="

}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi