#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
#shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

readonly FIREWALL_CONFIG=${FIREWALL_CONFIG:-"$ROOT_DIR/config/firewall.conf"}
# Management (SSH) rule that must be present in firewall.conf and is applied first.
# Format: PORT/tcp or PORT/udp (or START:END/proto), If ssh listens on a non-standard port
# set this explicitly.
readonly FIREWALL_MANAGEMENT_RULE=${FIREWALL_MANAGEMENT_RULE:-22/tcp}
#Allow-list grammer for every rule: 22/tcp, 53/udp, 800:8100/tcp
readonly RULE_REGEX='^[0-9]{1,5}(:[0-9]{1,5})?/(tcp|udp)$'
readonly ALLOW_IPV6_DISABLED=${FIREWALL_ALLOW_IPV6_DISABLED:-false}

declare -a FIREWALL_RULES=()

validate_rule() {
    local rule=$1 label=$2 safe ports start end 
    printf -v safe '%q' "$rule"
    [[ $rule =~ $RULE_REGEX ]] || die "Invalid firewall rule $safe ($label): expected PORT/tcp, PORT/udp or START:END/proto"
    ports=${rule%/*}
    start=${ports%%:*}
    end=${ports##*:}
    (( 10#$start >= 1 && 10#$end <= 65535 && 10#$start <= 10#$end )) || die "Port out of range in rule $safe ($label)"
}

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

ensure_ufw() {
    if ! command -v ufw >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o Dpkg::Lock::Timeout=120 update
        apt-get -o Dpkg::Lock::Timeout=120 install -y ufw
    fi

    require_command ufw
}

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

apply_rules() {
    local rule
    #Apply management access first. This matters when changing an already-active UFW.
    ufw allow "$FIREWALL_MANAGEMENT_RULE"
    for rule in "${FIREWALL_RULES[@]}";do
        [[ $rule == "$FIREWALL_MANAGEMENT_RULE" ]] && continue
        ufw allow "$rule"
    done
}

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