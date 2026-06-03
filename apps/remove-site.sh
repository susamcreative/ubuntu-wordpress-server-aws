#!/usr/bin/env bash
#
# remove-site.sh — registry-verified, guarded site removal (Task P2.1, DESIGN §8.3)
#
# Resolves the database/files/cert to remove from the REGISTRY (never from the
# wp-config), runs every destructive step through lib/guards.sh (cross-reference
# scan, PROTECTED check, nested-child containment, pre-drop dump), and refuses to
# remove a site that still has registered children. The wp-config is read only to
# cross-check; a registry/wp-config mismatch is a hard abort unless --force.
#
# USAGE:  ./apps/remove-site.sh [--dry-run] [--force] [--keep-backups] <domain>
#
set -uo pipefail
SCRIPT_NAME="remove-site.sh"

_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${_DIR}/lib/common.sh"
source "${_DIR}/lib/registry.sh"
source "${_DIR}/lib/guards.sh"
require_lib 1

# --- the destructive core (interactive prompts handled by main) ---------------
# Env knobs: REMOVE_FORCE=1, REMOVE_KEEP_BACKUPS=1.
# Returns 0 ok; 1 refused (children / mismatch / protected); 3 not registered.
do_remove_site() {  # <domain>
    local domain=$1
    registry_read "$domain" || return 3

    if [ "${REG_PROTECTED-}" = "true" ]; then
        warning "'$domain' is PROTECTED — refusing removal."; return 1
    fi
    local kids; kids="$(registry_children "$domain")"
    if [ -n "$kids" ]; then
        warning "'$domain' has registered children (remove them first): $(echo $kids)"; return 1
    fi
    if [ -f "${REG_DOC_ROOT}/wp-config.php" ] && ! verify_binding "$domain"; then
        warning "registry/wp-config mismatch: ${GUARD_REASON}"
        [ "${REMOVE_FORCE:-}" = 1 ] || { warning "aborting (use --force to override)"; return 1; }
    fi

    # 1. nginx config (rm is safe; reload is a no-op in tests / where nginx absent)
    rm -f "${NGINX_ENABLED}/${domain}" "${NGINX_AVAILABLE}/${domain}.conf"
    # 2. this site's promotion redirect, if any
    [ -n "${REG_REDIRECT_FROM-}" ] && rm -f "${NGINX_REDIRECTS}/${REG_REDIRECT_FROM}.conf"
    reload_nginx || true
    # 3. certificate (wildcard-preserving)
    safe_remove_certificate "$domain"
    # 4. database — guarded real drop + pre-drop dump (the only DROP path) + the DB user
    if [ -n "${REG_DB_NAME-}" ]; then
        safe_drop_database "${REG_DB_NAME}" "$domain" || warning "database not dropped"
        [ -n "${REG_DB_USER-}" ] && mysql_root -e "DROP USER IF EXISTS '${REG_DB_USER}'@'${REG_DB_HOST:-localhost}'; FLUSH PRIVILEGES;" 2>/dev/null || true
    fi
    # 5. files — guarded (refuses if a nested registered site lives inside)
    [ -d "${REG_DOC_ROOT-}" ] && safe_remove_docroot "${REG_DOC_ROOT}" "$domain"
    # 6. cache + 7. logs
    rm -rf "${CACHE_ROOT}/${domain}"
    rm -f "${LOGS_ROOT}/${domain}.access.log" "${LOGS_ROOT}/${domain}.error.log"
    # 8. backup archives (optional) — but PRESERVE pre-removal/ (the safety dump from
    #    step 4 is the whole point of reversibility; never delete it here).
    if [ "${REMOVE_KEEP_BACKUPS:-}" != 1 ]; then
        find "${BACKUP_ROOT}/${domain}" -maxdepth 1 -type f -name "${domain}_*.tar.gz" -delete 2>/dev/null || true
    fi
    # 9. registry record (last — every step above needed it)
    registry_delete "$domain"
    log_operation "remove-site" "$domain"
    success "Removed ${domain}"
    return 0
}

show_removal_plan() {   # <domain>
    registry_read "$domain" || { warning "not registered: $domain"; return 1; }
    echo "Removal plan for ${C_RED}${domain}${C_NC} (TYPE=${REG_TYPE-}, STATUS=${REG_STATUS-}):"
    echo "  • database:  ${REG_DB_NAME-} (pre-drop dump taken first)"
    echo "  • files:     ${REG_DOC_ROOT-}"
    echo "  • nginx:     ${NGINX_AVAILABLE}/${domain}.conf (+ symlink)"
    [ -n "${REG_REDIRECT_FROM-}" ] && echo "  • redirect:  ${NGINX_REDIRECTS}/${REG_REDIRECT_FROM}.conf"
    echo "  • cache, logs, backup archives, registry record"
}

main() {
    case "${1:-}" in -h|--help) show_help "${BASH_SOURCE[0]}"; exit 0 ;; esac
    local dry='' domain=''
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry=1; shift ;;
            --force) REMOVE_FORCE=1; shift ;;
            --keep-backups) REMOVE_KEEP_BACKUPS=1; shift ;;
            -*) error_exit "unknown option: $1" ;;
            *) domain=$1; shift ;;
        esac
    done
    [ -n "$domain" ] || error_exit "Usage: $0 [--dry-run] [--force] [--keep-backups] <domain>"

    if ! registry_exists "$domain"; then
        error_exit "'$domain' is not in the registry. Unregistered (orphan) removal is a separate, extra-scrutiny path — see list-sites.sh orphans / health-check, then register or clean up by hand."
    fi

    show_removal_plan "$domain" || exit 1
    if [ "$dry" = 1 ]; then echo ""; info "[dry-run] no changes made."; exit 0; fi

    acquire_lifecycle_lock
    if [ "${REMOVE_FORCE:-}" != 1 ]; then
        echo ""
        read -rp "$(printf '%sType the domain to confirm removal:%s ' "$C_RED" "$C_NC")" typed
        [ "$typed" = "$domain" ] || error_exit "confirmation did not match — aborted."
    fi
    do_remove_site "$domain"
}

[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"
