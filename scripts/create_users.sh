#!/usr/bin/env bash
#
#create_users.sh
#--------------------------------------------------------
# Purpose: Create the system users listed in config/users.conf
#          and grants or removes the sudo role as the config
#          declares. Safe to run multiple times.
# Called from: deploy.sh
# Usage:   sudo ./scripts/create_users.sh
# Env:     USERS_CONFIG path to the users file
#                       (default: config/users.conf)
#--------------------------------------------------------

set -euo pipefail

#--- Paths and shared library ---------------------------

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)

#shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly USERS_CONFIG=${USERS_CONFIG:-"${ROOT_DIR}/config/users.conf"}

#--- Config loading and validation -----------------------

declare -a USERS=() ROLES=()

load_and_validate_config() {

    require_regular_secure_file "$USERS_CONFIG"

    local raw line username role existing lineno=0
    while IFS= read -r raw || [[ -n $raw ]]; do
        lineno=$((lineno+1))
        line=$(normalize_config_line "$raw")
        [[ -n $line ]] || continue

        [[ $line != *:*:* ]] || die "Invalid users.conf line $lineno: too many ':' separators."
        IFS=: read -r username role <<<"$line"

        [[ -n ${username:-} && -n ${role:-} ]] || die "Invalid users.conf line $lineno; expected username:role."
        [[ $username =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "Unsafe username on line $lineno: $username"
        [[ $username != root ]] || die "Managing root through users.conf is forbidden."
        [[ $role == sudo || $role == user ]] || die "Unsupported role on line $lineno: $role"

        for existing in "${USERS[@]}"; do
            [[ $existing != "$username" ]] || die "Duplicate username on line $lineno: $username"
        done

        USERS+=("$username")
        ROLES+=("$role")
    done < "$USERS_CONFIG"

    (( ${#USERS[@]} > 0 )) || die "users.conf contains no users."

    if [[ " ${ROLES[*]} " == *' sudo '* ]]; then
        getent group sudo >/dev/null || die "The requested sudo role requires a 'sudo' group."
    fi

}

# --- Account provisioning ------------------------------------------------------------------

ensure_account() {

    local username=$1
    local entry uid home shell

    if entry=$(getent passwd "$username"); then
        IFS=: read -r _ _ uid _ _ home shell <<<"$entry"
        (( uid >= 1000 )) || die "Refusing to manage existing system account: $username"
        [[ $home == "/home/$username" && $shell == /bin/bash ]] \
            || die "Existing account '$username' violates the managed-account policy (home /home/$username, shell /bin/bash)."
        log_info "Managed user '$username' already exists."
    else
        useradd --create-home --home-dir "/home/$username" --shell /bin/bash "$username"
        passwd --lock "$username" >/dev/null
        log_success "Created locked user '$username'; add an authorized key before interactive use."
    fi

}

ensure_ssh_dir() {

    local username=$1
    local ssh_dir="/home/$username/.ssh"
    local group
    group=$(id -gn "$username")

    if [[ -L $ssh_dir ]]; then
        die "Refusing to touch $ssh_dir: it is a symlink."
    elif [[ -e $ssh_dir && ! -d $ssh_dir ]]; then
        die "$ssh_dir exists but is not a directory."
    elif [[ -d $ssh_dir ]]; then
        chown "$username:$group" "$ssh_dir"
        chmod 0700 "$ssh_dir"
        log_info "Verified owner and mode of $ssh_dir."
    else
        install -d -m 0700 -o "$username" -g "$group" "$ssh_dir"
        log_info "Created $ssh_dir."
    fi

}

apply_role() {

    local username=$1 role=$2
    local user_groups
    user_groups=$(id -nG "$username")

    if [[ $role == sudo ]]; then
        if [[ " $user_groups " == *' sudo '* ]]; then
            log_info "'$username' already has the sudo role."
        else
            usermod -aG sudo "$username"
            log_warn "Granted sudo role to '$username'."
        fi
    elif [[ " $user_groups " == *' sudo '* ]]; then
        gpasswd -d "$username" sudo >/dev/null
        log_warn "Removed sudo role from '$username' (config says 'user')."
    else
        log_info "'$username' has no sudo role."
    fi

}

ensure_user() {

    local username=$1 role=$2
    ensure_account "$username"
    ensure_ssh_dir "$username"
    apply_role "$username" "$role"

}

# --- Main ----------------------------------------------------------------------------------

main() {

    require_root
    read_os_release
    is_supported_debian_family || die "Unsupported OS for user provisioning: ${OS_ID}"

    local cmd
    for cmd in getent useradd usermod gpasswd passwd install id; do
        require_command "$cmd"
    done

    load_and_validate_config

    local i
    for i in "${!USERS[@]}"; do
        ensure_user "${USERS[$i]}" "${ROLES[$i]}"
    done

    log_success "=== User provisioning completed successfully ==="

}

main "$@"
