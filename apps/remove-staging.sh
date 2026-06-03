#!/usr/bin/env bash
#
# remove-staging.sh — registry-verified staging removal (Task P2.2, DESIGN §8.4)
#
# Drops the database that was VERIFIED at adoption time (registry), never the one
# the wp-config names at removal time. Same guards as remove-site.sh — it simply
# restricts removal to TYPE=staging sites (and reuses the shared removal core).
#
# USAGE:  ./apps/remove-staging.sh [--dry-run] [--force] <staging-domain>
#
set -uo pipefail
SCRIPT_NAME="remove-staging.sh"

_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${_DIR}/lib/common.sh"
source "${_DIR}/lib/registry.sh"
source "${_DIR}/lib/guards.sh"
source "${_DIR}/remove-site.sh"     # shared do_remove_site (its main() is guarded off)
require_lib 1

do_remove_staging() {   # <domain>
    local domain=$1
    registry_read "$domain" || { warning "'$domain' is not in the registry"; return 3; }
    if [ "${REG_TYPE-}" != "staging" ]; then
        warning "'$domain' is TYPE=${REG_TYPE-}, not staging — use remove-site.sh"; return 1
    fi
    do_remove_site "$domain"
}

main() {
    case "${1:-}" in -h|--help) show_help "${BASH_SOURCE[0]}"; exit 0 ;; esac
    local dry='' domain=''
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry=1; shift ;;
            --force) REMOVE_FORCE=1; shift ;;
            -*) error_exit "unknown option: $1" ;;
            *) domain=$1; shift ;;
        esac
    done
    [ -n "$domain" ] || error_exit "Usage: $0 [--dry-run] [--force] <staging-domain>"
    registry_exists "$domain" || error_exit "'$domain' is not registered."
    [ "$(registry_field "$domain" TYPE)" = staging ] || error_exit "'$domain' is not a staging site — use remove-site.sh."

    show_removal_plan "$domain" || exit 1
    if [ "$dry" = 1 ]; then echo ""; info "[dry-run] no changes made."; exit 0; fi

    acquire_lifecycle_lock
    if [ "${REMOVE_FORCE:-}" != 1 ]; then
        echo ""
        read -rp "$(printf '%sType the staging domain to confirm:%s ' "$C_RED" "$C_NC")" typed
        [ "$typed" = "$domain" ] || error_exit "confirmation did not match — aborted."
    fi
    do_remove_staging "$domain"
}

[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"
