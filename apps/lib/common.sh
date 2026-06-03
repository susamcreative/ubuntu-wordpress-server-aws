#!/usr/bin/env bash
#
# common.sh — shared foundation for all management scripts (Task P1.1)
# Implements: DESIGN §6.4, §4.4 (paths, mysql auth, validation, logging, lock)
#
# Source this first in every script:
#     source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#     require_lib 1
#
# All paths derive from APP_HOME (script location), ending the $USER-vs-APP_HOME
# split. Every path is overridable by setting it before sourcing (or after — the
# functions read the variables at call time), which is the seam the tests use to
# point the library at a fixture tree.
#

[ -n "${_COMMON_SH_LOADED:-}" ] && return 0
_COMMON_SH_LOADED=1

LIB_VERSION=1

require_lib() {     # <min-version> — abort loudly on an incompatible/stale library
    local need=$1
    if [ "${LIB_VERSION:-0}" -lt "$need" ]; then
        printf 'FATAL: lib version %s < required %s — redeploy apps/lib together with the scripts.\n' \
            "${LIB_VERSION:-0}" "$need" >&2
        exit 1
    fi
}

# --- paths (all overridable) --------------------------------------------------

_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
: "${APP_HOME:="$(cd -- "${_LIB_DIR}/../.." && pwd -P)"}"
: "${APP_DIR:="${APP_HOME}/apps"}"
: "${WEB_ROOT:="${APP_HOME}/www"}"
: "${CACHE_ROOT:="${APP_HOME}/cache"}"
: "${LOGS_ROOT:="${APP_HOME}/logs"}"
: "${BACKUP_ROOT:="${APP_HOME}/backups"}"
: "${SITES_DIR:="${APP_DIR}/sites.d"}"
: "${SERVER_CONF:="${APP_DIR}/server.conf"}"
: "${OPERATIONS_LOG:="${LOGS_ROOT}/operations.log"}"
: "${LIFECYCLE_LOCK:="/tmp/.site-lifecycle.lock"}"
: "${NGINX_AVAILABLE:=/etc/nginx/sites-available}"
: "${NGINX_ENABLED:=/etc/nginx/sites-enabled}"
: "${NGINX_REDIRECTS:=/etc/nginx/redirects.d}"

# Load instance config if present (thresholds, emails, webhook). Safe absent.
load_server_conf() {
    [ -f "$SERVER_CONF" ] && . "$SERVER_CONF"
    return 0
}

# --- colors / output ----------------------------------------------------------

if [ -t 1 ]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
    C_CYAN=$'\033[0;36m'; C_DIM=$'\033[2m'; C_NC=$'\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_DIM=''; C_NC=''
fi

# Print a script's leading comment block as help (the --help convention, §14.6).
show_help() {   # [script-path]
    local f="${1:-$0}"
    awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^#[[:space:]]?/,""); print; next} {exit}' "$f"
}

info()    { printf '  %s\n' "$1"; }
success() { printf '  %s✓ %s%s\n' "$C_GREEN" "$1" "$C_NC"; }
warning() { printf '  %s⚠ %s%s\n' "$C_YELLOW" "$1" "$C_NC"; }
error_exit() { printf '%s✗ %s%s\n' "$C_RED" "$1" "$C_NC" >&2; exit 1; }

# Append an audited lifecycle line to operations.log (all scripts share it).
log_operation() {   # <action> [detail]
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "$(dirname "$OPERATIONS_LOG")" 2>/dev/null || return 0
    { printf '%s | %s | %s | %s\n' "$ts" "${SCRIPT_NAME:-${0##*/}}" "$1" "${2:-}" \
        >> "$OPERATIONS_LOG"; } 2>/dev/null || true
}

# --- validation (pure: return 0/1, no output) ---------------------------------

is_valid_domain() {     # <domain>
    [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]]
}

is_valid_dbname() {     # <name>
    [ "${#1}" -le 64 ] && [[ "$1" =~ ^[a-zA-Z0-9_]+$ ]]
}

is_valid_dbuser() {     # <user>
    [ "${#1}" -le 32 ] && [[ "$1" =~ ^[a-zA-Z0-9_]+$ ]]
}

# True if the string is a bare namespace subdomain label (no dots) vs a full domain.
is_bare_label() {       # <input>
    case "$1" in *.*) return 1 ;; *) [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ;; esac
}

# --- wp-config parsing (canonical, single source — replaces 3 drifted copies) -

# Reads bindings from a wp-config.php into WPC_* globals. Handles single/double
# quotes and arbitrary define() spacing. Returns 1 if the file is unreadable.
read_wpconfig() {       # <wp-config-path>
    local f=$1
    WPC_DB_NAME='' WPC_DB_USER='' WPC_DB_PASSWORD='' WPC_DB_HOST='' WPC_TABLE_PREFIX=''
    [ -f "$f" ] || return 1
    WPC_DB_NAME="$(_wpc_define "$f" DB_NAME)"
    WPC_DB_USER="$(_wpc_define "$f" DB_USER)"
    WPC_DB_PASSWORD="$(_wpc_define "$f" DB_PASSWORD)"
    WPC_DB_HOST="$(_wpc_define "$f" DB_HOST)"
    [ -z "$WPC_DB_HOST" ] && WPC_DB_HOST="localhost"
    WPC_TABLE_PREFIX="$(grep -E '^[[:space:]]*\$table_prefix' "$f" | head -1 \
        | sed -E "s/.*\\\$table_prefix[[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\\1/")"
    return 0
}

# Uses [[:space:]] (not \s) so the same parser works under BSD sed/grep (macOS dev
# box, where the tests run) and GNU (the Ubuntu server).
_wpc_define() {         # <wp-config> <CONSTANT> — echo the defined value
    grep -E "define\([[:space:]]*['\"]${2}['\"]" "$1" | head -1 \
        | sed -E "s/.*define\([[:space:]]*['\"]${2}['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]*)['\"].*/\1/"
}

# --- mysql (real action — used at L3; password via process substitution) ------

mysql_root() {          # uses $MYSQL_ROOT_PASS; args passed through
    mysql --defaults-extra-file=<(printf '[client]\nuser=root\npassword=%s\n' "${MYSQL_ROOT_PASS:-}") "$@"
}

mysql_as() {            # <user> <pass> ...args
    local u=$1 p=$2; shift 2
    mysql --defaults-extra-file=<(printf '[client]\nuser=%s\npassword=%s\n' "$u" "$p") "$@"
}

mysqldump_root() {      # uses $MYSQL_ROOT_PASS; args passed through (overridable in tests)
    mysqldump --defaults-extra-file=<(printf '[client]\nuser=root\npassword=%s\n' "${MYSQL_ROOT_PASS:-}") "$@"
}

mysqldump_as() {        # <user> <pass> ...args (overridable in tests)
    local u=$1 p=$2; shift 2
    mysqldump --defaults-extra-file=<(printf '[client]\nuser=%s\npassword=%s\n' "$u" "$p") "$@"
}

# --- lifecycle lock (single concurrent create/promote/remove/adopt) -----------

acquire_lifecycle_lock() {
    # NOTE: do NOT add `2>/dev/null` here — on an `exec N>file` line it redirects
    # the SHELL's stderr permanently, silently swallowing all later errors.
    if ! exec 9>"$LIFECYCLE_LOCK"; then error_exit "Cannot open lifecycle lock: $LIFECYCLE_LOCK"; fi
    if command -v flock >/dev/null 2>&1; then
        flock -n 9 || error_exit "Another lifecycle operation is in progress (lock: $LIFECYCLE_LOCK)"
    fi
}
release_lifecycle_lock() { exec 9>&- 2>/dev/null || true; }

# Reload nginx after a validated config change (overridable/no-op in tests).
reload_nginx() {
    command -v nginx >/dev/null 2>&1 || return 0
    sudo nginx -t >/dev/null 2>&1 && sudo service nginx reload >/dev/null 2>&1
}
