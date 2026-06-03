#!/usr/bin/env bash
#
# registry.sh — the site registry: read/write/query sites.d/ (Task P1.2)
# Implements: DESIGN §5.1, §5.2, §6.1
#
# One file per site: $SITES_DIR/<domain>.conf, key="value". Writes are atomic
# (temp file in the same directory + mv). Records are loaded into REG_* globals
# WITHOUT sourcing the file (no code execution from a data file).
#

[ -n "${_REGISTRY_SH_LOADED:-}" ] && return 0
_REGISTRY_SH_LOADED=1

# Ensure common is available (paths, etc.).
if [ -z "${_COMMON_SH_LOADED:-}" ]; then
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
fi

# Canonical field order (DESIGN §5.2). registry_save writes exactly these.
REGISTRY_FIELDS=(
    DOMAIN TYPE PARENT STATUS STATUS_SINCE CREATED PROTECTED
    DB_NAME DB_USER DB_HOST TABLE_PREFIX DOC_ROOT
    BACKUP_FREQ SSL_MODE INDEXING
    NAMESPACE
    PROMOTED_FROM PROMOTED_DATE REDIRECT_FROM
)

registry_path()   { printf '%s/%s.conf' "$SITES_DIR" "$1"; }
registry_exists() { [ -f "$(registry_path "$1")" ]; }

# Clear REG_* (so a stale field from a previous read can't leak in).
registry_clear() {
    local k
    for k in "${REGISTRY_FIELDS[@]}"; do unset "REG_${k}"; done
}

# Load a record into REG_* globals. No sourcing: parse key="value" lines.
registry_read() {       # <domain>
    local f; f="$(registry_path "$1")"
    [ -f "$f" ] || return 1
    registry_clear
    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        key=${line%%=*}
        val=${line#*=}
        case "$key" in *[!A-Za-z0-9_]*) continue ;; esac   # only safe identifiers
        val=${val#\"}; val=${val%\"}                       # strip surrounding quotes
        printf -v "REG_${key}" '%s' "$val"
    done < "$f"
    return 0
}

# Echo a single field without disturbing the caller's REG_* (subshell read).
registry_field() {      # <domain> <KEY>
    ( registry_read "$1" >/dev/null 2>&1 || exit 1; local v="REG_$2"; printf '%s' "${!v-}" )
}

# Atomic whole-file write from current REG_* globals.
registry_save() {       # <domain>
    local d=$1 f tmp k var
    f="$(registry_path "$d")"
    mkdir -p "$SITES_DIR" || return 1
    tmp="$(mktemp "${SITES_DIR}/.${d}.XXXXXX")" || return 1
    {
        for k in "${REGISTRY_FIELDS[@]}"; do
            var="REG_${k}"
            printf '%s="%s"\n' "$k" "${!var-}"
        done
    } > "$tmp"
    mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
    # Keep records owned by the app user when a root-context script writes one.
    if [ "$(id -u)" -eq 0 ] && [ -n "${APP_USER:-}" ]; then
        chown "${APP_USER}:${APP_USER}" "$f" 2>/dev/null || true
    fi
    return 0
}

# Read-modify-write one field atomically. Stamps STATUS_SINCE (epoch) on a STATUS
# change, so health-check can detect operations stuck in a transient state.
registry_set() {        # <domain> <KEY> <VALUE>
    registry_read "$1" || return 1
    printf -v "REG_$2" '%s' "$3"
    [ "$2" = STATUS ] && printf -v REG_STATUS_SINCE '%s' "$(date +%s)"
    registry_save "$1"
}

registry_delete() { rm -f "$(registry_path "$1")"; }

# List domains, optionally filtered: registry_list [--type=X] [--status=Y]
registry_list() {
    local want_type='' want_status='' arg
    for arg in "$@"; do
        case "$arg" in
            --type=*)   want_type=${arg#--type=} ;;
            --status=*) want_status=${arg#--status=} ;;
        esac
    done
    [ -d "$SITES_DIR" ] || return 0
    local f d
    for f in "$SITES_DIR"/*.conf; do
        [ -e "$f" ] || continue
        d="$(basename "$f" .conf)"
        registry_read "$d" || continue
        [ -n "$want_type" ]   && [ "${REG_TYPE-}" != "$want_type" ]   && continue
        [ -n "$want_status" ] && [ "${REG_STATUS-}" != "$want_status" ] && continue
        printf '%s\n' "$d"
    done
}

# Domains whose PARENT == <domain>.
registry_children() {   # <domain>
    local parent=$1 f d
    [ -d "$SITES_DIR" ] || return 0
    for f in "$SITES_DIR"/*.conf; do
        [ -e "$f" ] || continue
        d="$(basename "$f" .conf)"
        registry_read "$d" || continue
        [ "${REG_PARENT-}" = "$parent" ] && printf '%s\n' "$d"
    done
}

# Blueprints. Returns 1 (and prints nothing) when none exist.
registry_find_blueprint() {
    local out; out="$(registry_list --type=blueprint)"
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

# Every domain that claims a given DB_NAME (provenance check support).
registry_db_claimants() {   # <db-name>
    local db=$1 f d
    [ -d "$SITES_DIR" ] || return 0
    for f in "$SITES_DIR"/*.conf; do
        [ -e "$f" ] || continue
        d="$(basename "$f" .conf)"
        registry_read "$d" || continue
        [ "${REG_DB_NAME-}" = "$db" ] && printf '%s\n' "$d"
    done
}
