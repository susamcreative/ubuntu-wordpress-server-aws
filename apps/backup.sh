#!/usr/bin/env bash
#
# backup.sh — registry-driven consolidated backups (Task P2.4, DESIGN §8.5)
#
# USAGE:  ./apps/backup.sh {daily|weekly|monthly}
#
# Sites and their frequencies come from the REGISTRY (apps/sites.d/*.conf,
# BACKUP_FREQ), not a hardcoded SITES array. Cascading logic:
#   daily   → sites with BACKUP_FREQ=daily
#   weekly  → daily + weekly
#   monthly → all sites with any frequency (not 'none')
#
# Each archive is SELF-DESCRIBING (site files + SQL dump + the site's registry
# record). The SQL dump is staged OUTSIDE the web root (never publicly downloadable).
# Database credentials are read from wp-config.php and cross-checked against the
# registry; a mismatch skips the site with a critical message (never backs up the
# wrong database).
#
# CRON (root crontab):
#   00 2 * * * cd /home/user/apps && /bin/bash ./backup.sh daily   >> /home/user/logs/backup.log 2>&1
#   30 2 * * 1 cd /home/user/apps && /bin/bash ./backup.sh weekly  >> /home/user/logs/backup.log 2>&1
#   00 3 1 * * cd /home/user/apps && /bin/bash ./backup.sh monthly >> /home/user/logs/backup.log 2>&1
#
set -uo pipefail
SCRIPT_NAME="backup.sh"

_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${_DIR}/lib/common.sh"
source "${_DIR}/lib/registry.sh"
require_lib 1
load_server_conf

ERROR_LOG="${LOGS_ROOT}/backup-errors.log"

# Retention (server.conf overrides; defaults match the documented policy).
: "${BACKUP_RETENTION_DAILY:=31}"
: "${BACKUP_RETENTION_WEEKLY:=91}"
: "${BACKUP_RETENTION_MONTHLY:=366}"
: "${REGISTRY_SNAPSHOT_KEEP:=30}"

# --- PURE: cascade selection (DESIGN §8.5) ------------------------------------
backup_should_run() {   # <site_freq> <run_freq>  → 0 if this site backs up on this run
    case "$2" in
        monthly) [ -n "$1" ] && [ "$1" != none ] ;;
        weekly)  [ "$1" = daily ] || [ "$1" = weekly ] ;;
        daily)   [ "$1" = daily ] ;;
        *)       return 1 ;;
    esac
}

# --- back up one site (real: mysqldump + tar) ---------------------------------
# Returns 0 ok, 1 error, 2 binding mismatch (skipped, critical).
backup_site() {     # <domain> <run_date> <run_freq>
    local domain=$1 thedate=$2 thefreq=$3
    registry_read "$domain" || { echo "⚠ ${domain}: no registry record"; return 1; }
    local docroot="${REG_DOC_ROOT}" wpc="${REG_DOC_ROOT}/wp-config.php"
    [ -d "$docroot" ] || { echo "⚠ ${domain}: docroot missing"; return 1; }
    read_wpconfig "$wpc" || { echo "⚠ ${domain}: wp-config unreadable"; return 1; }

    # Provenance cross-check — never back up the wrong database.
    if [ "$WPC_DB_NAME" != "${REG_DB_NAME}" ]; then
        echo "✗ ${domain}: CRITICAL — wp-config DB '${WPC_DB_NAME}' != registry '${REG_DB_NAME}', skipped"
        return 2
    fi

    echo "Backing up: ${domain}"
    local sitedir="${BACKUP_ROOT}/${domain}"
    local tmpdir="${sitedir}/tmp"
    mkdir -p "$sitedir" "$tmpdir"
    local sqlbase="${tmpdir}/${REG_DB_NAME}_${thedate}.sql"
    local archive="${sitedir}/${domain}_${thefreq}_${thedate}.tar.gz"

    # SQL dump staged OUTSIDE the web root; mysqldump exit checked directly.
    if ! mysqldump_as "$WPC_DB_USER" "$WPC_DB_PASSWORD" "$REG_DB_NAME" > "$sqlbase" 2>>"$ERROR_LOG"; then
        echo "  ✗ database dump failed"; rm -f "$sqlbase"; return 1
    fi
    gzip -f "$sqlbase"
    local sqlgz="$(basename "$sqlbase").gz"

    # Self-describing archive: site files + SQL dump + the registry record.
    local parent leaf; parent="$(dirname "$docroot")"; leaf="$(basename "$docroot")"
    if ! tar -czf "$archive" \
            --exclude="${leaf}/wp-content/cache" \
            --exclude="${leaf}/wp-content/litespeed" \
            -C "$parent" "$leaf" \
            -C "$tmpdir" "$sqlgz" \
            -C "$SITES_DIR" "${domain}.conf" 2>>"$ERROR_LOG"; then
        echo "  ✗ archive creation failed"; rm -f "$archive" "${tmpdir}/${sqlgz}"; return 1
    fi

    rm -f "${tmpdir}/${sqlgz}"; rmdir "$tmpdir" 2>/dev/null || true
    echo "  ✓ ${domain} backup complete"; echo ""
    return 0
}

# --- registry self-backup -----------------------------------------------------
backup_registry_snapshot() {    # <run_date>
    mkdir -p "${BACKUP_ROOT}/registry"
    local snap="${BACKUP_ROOT}/registry/registry_${1}.tar.gz"
    local extra=(); [ -f "$SERVER_CONF" ] && extra=("server.conf")
    tar -czf "$snap" -C "$APP_DIR" sites.d "${extra[@]}" 2>>"$ERROR_LOG" || return 1
    # keep the most recent N
    ls -1t "${BACKUP_ROOT}"/registry/registry_*.tar.gz 2>/dev/null \
        | tail -n +"$((REGISTRY_SNAPSHOT_KEEP + 1))" | xargs -r rm -f
}

# --- scoped retention cleanup (only per-site archives; reserved dirs safe) -----
cleanup_old_backups() {     # <run_freq>
    local ret
    case "$1" in
        daily) ret=$BACKUP_RETENTION_DAILY ;; weekly) ret=$BACKUP_RETENTION_WEEKLY ;;
        monthly) ret=$BACKUP_RETENTION_MONTHLY ;; *) return 0 ;;
    esac
    # mindepth/maxdepth 2 confines deletion to BACKUP_ROOT/<domain>/<archive>;
    # pre-removal/ (depth 3) and the registry/ dir are never touched.
    find "$BACKUP_ROOT" -mindepth 2 -maxdepth 2 -type f \
        -name "*_${1}_*.tar.gz" -not -path "*/registry/*" -mtime "+${ret}" -delete 2>>"$ERROR_LOG" || true
}

main() {
    case "${1:-}" in -h|--help) show_help "${BASH_SOURCE[0]}"; exit 0 ;; esac
    [ $# -eq 1 ] || { echo "Usage: $0 {daily|weekly|monthly}"; exit 1; }
    local freq=$1
    case "$freq" in daily|weekly|monthly) ;; *) echo "ERROR: invalid frequency"; exit 1 ;; esac
    local thedate; thedate="$(date +%y.%m.%d_%H.%M)"
    mkdir -p "$LOGS_ROOT"; touch "$ERROR_LOG"

    echo "========================================="
    echo "Backup Run: ${freq}"        # <-- log-line contract (health-check parses these)
    echo "Date: ${thedate}"
    echo "========================================="
    echo ""

    # Fail-loud: an empty registry while sites exist on disk = a migration mistake,
    # not "nothing to do". (DESIGN §8.5 — never silently stop backing up.)
    local n_records n_ondisk
    n_records="$(registry_list | grep -c . || true)"
    n_ondisk="$(find "$WEB_ROOT" -maxdepth 2 -name wp-config.php -type f 2>/dev/null | grep -c . || true)"
    if [ "$n_records" -eq 0 ] && [ "$n_ondisk" -gt 0 ]; then
        echo "✗ CRITICAL: registry is empty but ${n_ondisk} site(s) exist on disk — refusing to run." >&2
        exit 1
    fi

    local ok=0 skip=0 d freq_site
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        freq_site="$(registry_field "$d" BACKUP_FREQ)"
        backup_should_run "$freq_site" "$freq" || continue
        if backup_site "$d" "$thedate" "$freq"; then ok=$((ok+1)); else skip=$((skip+1)); fi
    done < <(registry_list)

    backup_registry_snapshot "$thedate"

    echo "========================================="
    echo "Backup Complete"
    echo "  Successfully backed up: ${ok} sites"
    [ "$skip" -gt 0 ] && echo "  Skipped (errors):       ${skip} sites"
    echo "========================================="
    echo ""

    echo "Cleaning up old backups..."
    cleanup_old_backups "$freq"
    echo "Cleanup complete"; echo ""
}

[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"
