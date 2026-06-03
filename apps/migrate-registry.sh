#!/usr/bin/env bash
#
# migrate-registry.sh — one-time adoption scan (Task P1.6, DESIGN §12, C9)
#
# Proposes one registry record per existing top-level site, deriving bindings from
# each wp-config.php and backup frequency from the legacy backup.sh SITES array.
# TYPE is a heuristic the operator MUST review (the tool cannot know the blueprint).
# Nested wp-configs (staging under a parent) are reported for manual handling.
#
set -uo pipefail
SCRIPT_NAME="migrate-registry.sh"

_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${_DIR}/lib/common.sh"
source "${_DIR}/lib/registry.sh"
require_lib 1

# Legacy backup script that holds the SITES=( "domain:freq" ) array.
LEGACY_BACKUP="${LEGACY_BACKUP:-${APP_DIR}/backup.sh}"

_legacy_freq() {        # <domain> — echo daily|weekly|monthly from the SITES array, else nothing
    [ -f "$LEGACY_BACKUP" ] || return 0
    local d=${1//./\\.}
    grep -E "\"${d}:(daily|weekly|monthly)\"" "$LEGACY_BACKUP" 2>/dev/null | head -1 \
        | sed -E "s/.*\"${d}:(daily|weekly|monthly)\".*/\1/"
}

# Propose records for every top-level site dir. Echoes each proposed domain.
migrate_propose() {     # [namespace]
    local ns=${1:-} dir dom type freq wpc
    for dir in "$WEB_ROOT"/*/ ; do
        [ -d "$dir" ] || continue
        wpc="${dir}wp-config.php"
        [ -f "$wpc" ] || continue
        dir="${dir%/}"
        dom="$(basename "$dir")"
        case "$dom" in
            html) continue ;;                      # placeholder, not a site
            staging.*) type=staging ;;
            *)  if [ -n "$ns" ] && [ "$dom" != "$ns" ] && [[ "$dom" == *".$ns" ]]; then
                    type=dev
                else
                    type=production
                fi ;;
        esac
        read_wpconfig "$wpc"
        freq="$(_legacy_freq "$dom")"; [ -z "$freq" ] && freq=none
        registry_clear
        REG_DOMAIN="$dom" REG_TYPE="$type" REG_STATUS=active REG_PROTECTED=false
        REG_DB_NAME="$WPC_DB_NAME" REG_DB_USER="$WPC_DB_USER" REG_DB_HOST="$WPC_DB_HOST"
        REG_TABLE_PREFIX="$WPC_TABLE_PREFIX" REG_DOC_ROOT="$dir" REG_BACKUP_FREQ="$freq"
        REG_CREATED="$(date +%F)" REG_SSL_MODE=own REG_INDEXING=allowed
        case "$type" in
            staging) REG_PARENT="${dom#staging.}"; REG_SSL_MODE=wildcard; REG_INDEXING=blocked ;;
            dev)     REG_SSL_MODE=wildcard; REG_INDEXING=blocked ;;
        esac
        registry_save "$dom"
        printf '%s\n' "$dom"
    done
}

# Nested wp-configs (depth >= 3 under WEB_ROOT) — staging clones needing review.
migrate_nested_manual() { find "$WEB_ROOT" -mindepth 3 -name wp-config.php -type f 2>/dev/null; }

main() {
    case "${1:-}" in -h|--help) show_help "${BASH_SOURCE[0]}"; exit 0 ;; esac
    local ns="${1:-}"
    echo "Scanning ${WEB_ROOT} → proposing registry records in ${SITES_DIR}"
    echo ""
    local n=0 d
    while IFS= read -r d; do success "proposed: $d ($(registry_field "$d" TYPE), backup=$(registry_field "$d" BACKUP_FREQ))"; n=$((n+1)); done < <(migrate_propose "$ns")
    echo ""
    info "$n record(s) proposed."
    local nested; nested="$(migrate_nested_manual)"
    if [ -n "$nested" ]; then
        echo ""
        warning "Nested wp-configs found (likely staging — register manually after review):"
        printf '    %s\n' $nested
    fi
    echo ""
    warning "REVIEW EVERY RECORD before trusting it — especially TYPE and the blueprint."
    echo "    Then: mark the blueprint (TYPE=blueprint, PROTECTED=true, NAMESPACE=...)."
}

[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"
