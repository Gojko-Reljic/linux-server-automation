#!/usr/bin/env bash
#
# configure_firewall.sh
# ---------------------------------------------------------------------
# Purpose: Configures UFW from config/firewall.conf: allows the management
#          (SSH) rule first, then every other listed rule, then sets the
#          default policies, enables the firewall and verifies the result.
# Called from: deploy.sh (as a separate process)
# Usage:   sudo ./scripts/configure_firewall.sh
# Env:     FIREWALL_CONFIG               rules file
#                                        (default config/firewall.conf)
#          FIREWALL_MANAGEMENT_RULE      rule that must be in the file
#                                        (default 22/tcp)
#          FIREWALL_ALLOW_IPV6_DISABLED  true = only warn when IPv6 filtering
#                                        is off (default false)
# ---------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
#shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# --- Settings ---------------------------------------------------------
 
# Rules file: one rule per line, '#' starts a comment. It decides what the
# root-run script opens, so load_rules requires it to be root-owned and
# not writable by group or other users.
readonly FIREWALL_CONFIG=${FIREWALL_CONFIG:-"$ROOT_DIR/config/firewall.conf"}
# Rule that must appear in the rules file (matched as an exact string) and
# is applied first, so SSH stays reachable. Format: PORT/tcp, PORT/udp or
# START:END/proto. If sshd listens on a non-standard port, set this
# explicitly.
readonly FIREWALL_MANAGEMENT_RULE=${FIREWALL_MANAGEMENT_RULE:-22/tcp}
# Allow-list grammar for every rule, e.g. 22/tcp, 53/udp, 8000:8100/tcp.
# It checks the shape only; validate_rule checks the port range.
readonly RULE_REGEX='^[0-9]{1,5}(:[0-9]{1,5})?/(tcp|udp)$'
# Secure by default: the script stops when IPv6 filtering is off, unless
# this is explicitly set to true (see check_ipv6).
readonly ALLOW_IPV6_DISABLED=${FIREWALL_ALLOW_IPV6_DISABLED:-false}

# Filled by load_rules; read by apply_rules and verify_firewall.
declare -a FIREWALL_RULES=()

# --- Rule loading -----------------------------------------------------
 
# Accepts only the PORT/proto forms of RULE_REGEX. Anything else (a leading
# dash, spaces, ';') is rejected before ufw sees it, so a bad line can
# neither be read as a ufw option nor abort the script halfway through a
# change. %q prints the rule shell-quoted, so control characters cannot
# corrupt the terminal or the logs. 10# forces decimal, so a leading zero
# is not read as octal.
# Arguments: rule, label (where it came from, used in the error message).
validate_rule() {
    local rule=$1 label=$2 safe ports start end 
    printf -v safe '%q' "$rule"
    [[ $rule =~ $RULE_REGEX ]] || die "Invalid firewall rule $safe ($label): expected PORT/tcp, PORT/udp or START:END/proto"
    ports=${rule%/*}
    start=${ports%%:*}
    end=${ports##*:}
    (( 10#$start >= 1 && 10#$end <= 65535 && 10#$start <= 10#$end )) || die "Port out of range in rule $safe ($label)"
}

# Reads and validates the whole file before the firewall is touched. Dies
# when the file is empty or the management rule is missing, so a bad config
# can never lock out SSH. '|| [[ -n $raw ]]' keeps a last line that has no
# trailing newline.
load_rules() {
    require_regular_secure_file "$FIREWALL_CONFIG"
    validate_rule "$FIREWALL_MANAGEMENT_RULE" 'FIREWALL_MANAGEMENT_RULE'

    local raw line lineno=0 has_management=false 
    while IFS= read -r raw || [[ -n $raw ]]; do
        (( lineno +=1 ))
        line=$(normalize_config_line "$raw")
        [[ -n $line ]] || continue
        validate_rule "$line" "$FIREWALL_CONFIG:$lineno"
        FIREWALL_RULES+=("$line")
        if [[ $line == "$FIREWALL_MANAGEMENT_RULE" ]]; then
            has_management=true
        fi
    done < "$FIREWALL_CONFIG"

    (( ${#FIREWALL_RULES[@]} > 0 )) || die "firewall.conf contains no rules."
    [[ $has_management == true ]] || die "Required management rule '$FIREWALL_MANAGEMENT_RULE' is absent from firewall.conf."
}

# --- Firewall setup ---------------------------------------------------
 
# Installs ufw only when it is missing. apt-get update comes first because
# a fresh machine may have no package index. Dpkg::Lock::Timeout makes apt
# wait for another apt/dpkg process instead of failing at once, and
# noninteractive prevents prompts. require_command confirms the install
# really produced the binary.
ensure_ufw() {
    if ! command -v ufw >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o Dpkg::Lock::Timeout=120 update
        apt-get -o Dpkg::Lock::Timeout=120 install -y ufw
    fi

    require_command ufw
}

# UFW filters IPv6 only when IPV6=yes in /etc/default/ufw. With IPV6=no it
# creates no v6 rules, so the host would be open on IPv6 while the script
# reports success. Stop unless the operator opted out explicitly. Must run
# before ufw is enabled.
check_ipv6() {
    local defaults_file=/etc/default/ufw
    [[ -r $defaults_file ]] || die "Cannot read $defaults_file."

    if grep -qi '^IPV6=yes[[:space:]]*$' "$defaults_file"; then
        return 0
    fi 
    
    if [[ $ALLOW_IPV6_DISABLED == true ]]; then 
        log_warn "IPv6 filtering is disabled in $defaults_file (allowed by FIREWALL_ALLOW_IPV6_DISABLED=true)."
        return 0
    fi 
    
    die "IPv6 is not enabled in $defaults_file. Set IPV6=yes, or run with FIREWALL_ALLOW_IPV6_DISABLED=true if this host intentionally has no IPv6."
}

# Adds every rule from the config. ufw skips rules that already exist, so
# re-running the script is safe.
apply_rules() {
    local rule
    # Management rule first. On an already-active UFW it must exist before
    # the default policy turns to deny (main does that after this function),
    # so there is never a moment when SSH is blocked.
    ufw allow "$FIREWALL_MANAGEMENT_RULE"
    for rule in "${FIREWALL_RULES[@]}";do
        [[ $rule == "$FIREWALL_MANAGEMENT_RULE" ]] && continue
        ufw allow "$rule"
    done
}

# --- Verification -----------------------------------------------------
 
# Checks the real state instead of trusting exit codes. LC_ALL=C keeps the
# ufw output untranslated so the greps work on any locale. Each rule is
# matched at the start of a line, so 22/tcp cannot match 122/tcp.
verify_firewall() {
    local status rule
    status=$(LC_ALL=C ufw status verbose)

    grep -q '^Status: active' <<< "$status" || die 'UFW is not active after configuration.'
    grep -q '^Default: deny (incoming)' <<< "$status" || die 'Default incoming policy is not deny.'
    grep -q '^Default:.*allow (outgoing)' <<< "$status" || die 'Default outgoing policy is not allow.'
    
    # Safe to interpolate into a regex: validate_rule only admits digits, ':' and '/tcp|udp'.
    for rule in "${FIREWALL_RULES[@]}"; do
         grep -qE "^${rule}[[:space:]]+ALLOW" <<< "$status" \
        || die "Rule '$rule' is missing from ufw status after configuration."
    done
}

# --- Main -------------------------------------------------------------
 
# Order matters: everything is validated (load_rules) before the first
# change, allow rules are applied before the default policy turns to deny,
# and the state is verified last. Existing UFW rules are preserved on
# purpose; the warning at the end reminds the operator to audit stale ones.
main() {
    require_root
    read_os_release
    is_supported_debian_family || die "Unsupported OS for UFW: $OS_ID"
    load_rules
    ensure_ufw
    check_ipv6

    log_info "Ensuring management access is allowed: $FIREWALL_MANAGEMENT_RULE"
    apply_rules
    ufw default deny incoming
    ufw default allow outgoing
    ufw --force enable
    verify_firewall

    log_warn 'Existing UFW rules were intentionally preserved; audit ufw status numbered for stale rules.'
    log_success '=== Firewall configuration completed successfully ==='
}

main "$@"