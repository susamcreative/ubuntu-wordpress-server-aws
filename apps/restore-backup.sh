#!/usr/bin/env bash
#
# restore-backup.sh — registry-aware restore (Task P2.3, DESIGN §8.6)
#
# Restores a site from a self-describing archive (site files + SQL dump + the
# site's registry record). The restore TARGET comes from the registry, cross-
# checked against wp-config. A backup of a REMOVED site re-establishes its registry
# record from the archive first, then restores data — so a removed site can be
# fully resurrected from its backup alone.
#
# USAGE:  ./apps/restore-backup.sh [<domain> [<archive>]]
#
set -uo pipefail
SCRIPT_NAME="restore-backup.sh"

_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${_DIR}/lib/common.sh"
source "${_DIR}/lib/registry.sh"
source "${_DIR}/lib/guards.sh"
source "${_DIR}/lib/rebind.sh"
require_lib 1

# Validate an archive is readable and self-describing.
validate_archive() {    # <archive>
    [ -f "$1" ] || { warning "archive not found: $1"; return 1; }
    tar -tzf "$1" >/dev/null 2>&1 || { warning "archive is corrupt: $1"; return 1; }
}

# If the archive carries a registry record and the site isn't registered, restore
# the record (re-establish provenance). Echoes the domain the archive describes.
restore_registry_record() {     # <archive>
    local archive=$1 rec dom tmp
    rec="$(tar -tzf "$archive" 2>/dev/null | grep -E '^[^/]+\.conf$' | head -1)"
    [ -n "$rec" ] || return 1
    dom="${rec%.conf}"
    if ! registry_exists "$dom"; then
        tmp="$(mktemp -d)"
        tar -xzf "$archive" -C "$tmp" "$rec" 2>/dev/null
        mkdir -p "$SITES_DIR"; cp "$tmp/$rec" "$SITES_DIR/$rec"
        rm -rf "$tmp"
        log_operation "restore-registry" "$dom (from archive)"
    fi
    printf '%s\n' "$dom"
}

# Restore the database (guarded recreate + import).
do_restore_db() {       # <domain> <archive>
    local domain=$1 archive=$2 tmp sqlgz rc
    registry_read "$domain" || { warning "not registered: $domain"; return 1; }
    tmp="$(mktemp -d)"
    tar -xzf "$archive" -C "$tmp" 2>/dev/null
    sqlgz="$(find "$tmp" -name '*.sql.gz' -type f | head -1)"
    [ -n "$sqlgz" ] || { warning "no SQL dump in archive"; rm -rf "$tmp"; return 1; }
    safe_recreate_and_import "${REG_DB_NAME}" "$domain" "$sqlgz"; rc=$?
    rm -rf "$tmp"
    return $rc
}

# Restore the site files (preserving a current wp-config if one exists).
do_restore_files() {    # <domain> <archive>
    local domain=$1 archive=$2 docroot leaf tmp extracted preserve=''
    registry_read "$domain" || { warning "not registered: $domain"; return 1; }
    docroot="${REG_DOC_ROOT}"; leaf="$(basename "$docroot")"
    tmp="$(mktemp -d)"
    tar -xzf "$archive" -C "$tmp" "$leaf" 2>/dev/null || { warning "site files not in archive"; rm -rf "$tmp"; return 1; }
    extracted="$tmp/$leaf"
    [ -d "$extracted" ] || { rm -rf "$tmp"; return 1; }
    [ -f "$docroot/wp-config.php" ] && { preserve="$tmp/wp-config.keep"; cp "$docroot/wp-config.php" "$preserve"; }
    mkdir -p "$docroot"
    find "$docroot" -mindepth 1 -delete 2>/dev/null || true
    cp -r "$extracted"/. "$docroot"/
    [ -n "$preserve" ] && cp "$preserve" "$docroot/wp-config.php"
    fix_permissions "$docroot" 2>/dev/null || true
    rm -rf "$tmp"
    log_operation "restore-files" "$domain"
}

# Pre-promotion archive: restoring a backup older than the promotion restores the
# old dev URLs. Offer to rebase them. (Returns the dev URL if a rebind is warranted.)
restore_needs_rebind() {    # <domain> <archive>  → echoes old→new if archive predates promotion
    registry_read "$1" || return 1
    [ -n "${REG_PROMOTED_FROM-}" ] && [ -n "${REG_PROMOTED_DATE-}" ] || return 1
    local adate; adate="$(basename "$2" | sed -E 's/.*_([0-9.]+_[0-9.]+)\.tar\.gz/\1/')"
    # archive datetime (yy.mm.dd...) lexically before promotion date → predates it
    [ "$adate" \< "${REG_PROMOTED_DATE//-/.}" ] && printf 'https://%s https://%s\n' "$REG_PROMOTED_FROM" "$1"
}

main() {
    case "${1:-}" in -h|--help) show_help "${BASH_SOURCE[0]}"; exit 0 ;; esac
    local domain="${1:-}" archive="${2:-}"
    [ -n "$domain" ] || error_exit "Usage: $0 <domain> [<archive>]  (lists archives if <archive> omitted)"
    if [ -z "$archive" ]; then
        echo "Backups for ${domain}:"
        ls -1t "${BACKUP_ROOT}/${domain}"/${domain}_*.tar.gz 2>/dev/null || error_exit "no archives for ${domain}"
        exit 0
    fi
    validate_archive "$archive" || exit 1
    acquire_lifecycle_lock
    local dom; dom="$(restore_registry_record "$archive")"   # re-register if removed
    echo ""; warning "This overwrites current data for ${dom}. A safety dump is taken first."
    read -rp "Type 'yes' to continue: " c; [ "$c" = yes ] || { echo "cancelled"; exit 0; }
    do_restore_db "$dom" "$archive"
    do_restore_files "$dom" "$archive"
    local reb; reb="$(restore_needs_rebind "$dom" "$archive" || true)"
    [ -n "$reb" ] && warning "Archive predates promotion — consider: rebind_urls ${REG_DOC_ROOT} ${reb}"
    success "Restore complete for ${dom}"
}

[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"
