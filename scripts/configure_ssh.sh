#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

readonly SSH_CONFIG=/etc/ssh/sshd_config
readonly SSH_DROPIN_DIR=/etc/ssh/sshd_config.d
readonly SSH_DROPIN="$SSH_DROPIN_DIR/00-server-automation-hardening.conf"
readonly SSH_ACCESS_USERS=${SSH_ACCESS_USERS:-"$ROOT_DIR/config/ssh-access-users.conf"}

declare -a ACCESS_USERS=()
SSH_UNIT=""
BACKUP_FILE=""

cleanup() {
  [[ -z $BACKUP_FILE ]] || rm -f -- "$BACKUP_FILE"
}

load_access_users() {
  require_regular_secure_file "$SSH_ACCESS_USERS"
  local line lineno=0
  while IFS= read -r line || [[ -n $line ]]; do
    ((lineno += 1))
    line=$(normalize_config_line "$line")
    [[ -z $line ]] && continue
    [[ $line =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "Unsafe SSH access user on line $lineno: $line"
    id "$line" >/dev/null 2>&1 || die "SSH access user does not exist: $line"
    ACCESS_USERS+=("$line")
  done < "$SSH_ACCESS_USERS"
  ((${#ACCESS_USERS[@]} > 0)) || die 'No SSH access users were configured.'
}

assert_key_access_is_ready() {
  local user home key_file ssh_dir uid gid mode owner
  for user in "${ACCESS_USERS[@]}"; do
    uid=$(id -u "$user")
    gid=$(id -g "$user")
    home=$(getent passwd "$user" | awk -F: '{print $6}')
    ssh_dir="$home/.ssh"
    key_file="$ssh_dir/authorized_keys"
    [[ -d $ssh_dir && ! -L $ssh_dir ]] || die "Missing safe .ssh directory for '$user'."
    [[ -f $key_file && ! -L $key_file && -s $key_file ]] || die "'$user' needs a non-empty regular authorized_keys file before password SSH is disabled."
    owner=$(stat -c '%u:%g' "$ssh_dir")
    mode=$(stat -c '%a' "$ssh_dir")
    [[ $owner == "$uid:$gid" ]] || die "Incorrect .ssh ownership for '$user'."
    (( (8#$mode & 8#077) == 0 )) || die "Insecure .ssh permissions for '$user'."
    owner=$(stat -c '%u:%g' "$key_file")
    mode=$(stat -c '%a' "$key_file")
    [[ $owner == "$uid:$gid" ]] || die "Incorrect authorized_keys ownership for '$user'."
    (( (8#$mode & 8#077) == 0 )) || die "Insecure authorized_keys permissions for '$user'."
  done
}

assert_dropin_takes_effect() {
  grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSH_CONFIG" \
    || die "Main sshd_config does not Include sshd_config.d/*.conf; hardening would not take effect."
}

resolve_ssh_unit() {
  local unit
  for unit in ssh sshd; do
    if systemctl is-active --quiet "$unit"; then
      SSH_UNIT=$unit
      return 0
    fi
  done
  return 1
}

restore_dropin() {
  local backup=$1 existed=$2
  if [[ $existed == true ]]; then
    install -m 0600 "$backup" "$SSH_DROPIN"
  else
    rm -f -- "$SSH_DROPIN"
  fi
}

validate_effective_settings() {
  local effective
  sshd -t -f "$SSH_CONFIG" || return 1
  effective=$(sshd -T -f "$SSH_CONFIG") || return 1
  grep -qx 'permitrootlogin no' <<<"$effective" || return 1
  grep -qx 'passwordauthentication no' <<<"$effective" || return 1
  grep -qx 'kbdinteractiveauthentication no' <<<"$effective" || return 1
  grep -qx 'pubkeyauthentication yes' <<<"$effective" || return 1
  grep -qx 'authenticationmethods publickey' <<<"$effective" || return 1
}

reload_ssh() {
  systemctl reload "$SSH_UNIT"
}

main() {
  require_root
  require_command sshd
  require_command systemctl
  require_systemd
  require_regular_secure_file "$SSH_CONFIG"

  resolve_ssh_unit || die 'No active ssh/sshd systemd unit found; refusing to modify configuration.'
  if systemctl is-active --quiet ssh.socket; then
    log_warn 'ssh.socket is active (socket activation): the listening port is set by the socket unit, not by Port in sshd_config.'
  fi
  assert_dropin_takes_effect

  load_access_users
  assert_key_access_is_ready

  install -d -m 0755 "$SSH_DROPIN_DIR"
  local existed=false
  trap cleanup EXIT
  BACKUP_FILE=$(mktemp)

  if [[ -e $SSH_DROPIN ]]; then
    [[ -f $SSH_DROPIN && ! -L $SSH_DROPIN ]] || die "Managed SSH drop-in is not a regular file: $SSH_DROPIN"
    cp --preserve=mode,ownership "$SSH_DROPIN" "$BACKUP_FILE"
    [[ -s $BACKUP_FILE ]] || die 'Backup of existing SSH drop-in appears empty; aborting before modification.'
    existed=true
  fi

  umask 077
  cat > "$SSH_DROPIN" <<'EOF'
# Managed by server-automation. Do not edit manually.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitEmptyPasswords no
EOF
  chmod 0600 "$SSH_DROPIN"

  if ! validate_effective_settings; then
    log_error 'New SSH configuration did not validate or was overridden; restoring the prior drop-in.'
    restore_dropin "$BACKUP_FILE" "$existed"
    exit 1
  fi

  if ! reload_ssh; then
    log_error 'SSH reload failed; restoring the prior drop-in.'
    restore_dropin "$BACKUP_FILE" "$existed"
    reload_ssh || log_error 'Could not reload the restored SSH configuration; investigate from console access.'
    exit 1
  fi

  log_success 'SSH hardening is active; retain the current session and test a new key-based login before disconnecting.'
}

main "$@"