#!/usr/bin/env bash
#
# assert.sh — tiny assertion library for the test harness (Task T.1)
#
# USAGE:
#   Source this at the top of every tests/**/test_*.sh:
#       source "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
#   Then call assert_* helpers. An EXIT trap prints a per-file summary and sets
#   the exit code (nonzero if any assertion failed), so test files never manage
#   exit codes themselves.
#
# DESIGN NOTES:
#   - Plain bash, zero dependencies (matches the repo's no-dependency philosophy).
#   - Assertions use `if/case` internally so they never trip `set -e` in a caller.
#   - Do NOT use `set -e` in test files; let assertions report instead of aborting.
#

[ -n "${_ASSERT_SH_LOADED:-}" ] && return 0
_ASSERT_SH_LOADED=1

_ASSERT_TOTAL=0
_ASSERT_FAILS=0

if [ -t 1 ]; then
    _C_GREEN=$'\033[0;32m'; _C_RED=$'\033[0;31m'; _C_DIM=$'\033[2m'; _C_NC=$'\033[0m'
else
    _C_GREEN=''; _C_RED=''; _C_DIM=''; _C_NC=''
fi

_pass() {
    _ASSERT_TOTAL=$((_ASSERT_TOTAL + 1))
    printf '    %sok%s   %s\n' "$_C_GREEN" "$_C_NC" "$1"
}

_fail() {
    _ASSERT_TOTAL=$((_ASSERT_TOTAL + 1))
    _ASSERT_FAILS=$((_ASSERT_FAILS + 1))
    printf '    %sFAIL%s %s\n' "$_C_RED" "$_C_NC" "$1"
}

# --- value assertions ---------------------------------------------------------

assert_eq() {   # <expected> <actual> [label]
    local exp=$1 act=$2 label=${3:-"values equal"}
    if [ "$exp" = "$act" ]; then _pass "$label"
    else _fail "$label — expected [$exp], got [$act]"; fi
}

assert_ne() {   # <unexpected> <actual> [label]
    local nexp=$1 act=$2 label=${3:-"values differ"}
    if [ "$nexp" != "$act" ]; then _pass "$label"
    else _fail "$label — both were [$act]"; fi
}

assert_contains() {     # <haystack> <needle> [label]
    local hay=$1 needle=$2 label=${3:-"contains '$2'"}
    case "$hay" in
        *"$needle"*) _pass "$label" ;;
        *) _fail "$label — '$needle' not found in: $hay" ;;
    esac
}

assert_not_contains() { # <haystack> <needle> [label]
    local hay=$1 needle=$2 label=${3:-"excludes '$2'"}
    case "$hay" in
        *"$needle"*) _fail "$label — '$needle' unexpectedly found" ;;
        *) _pass "$label" ;;
    esac
}

# --- filesystem assertions ----------------------------------------------------

assert_file_present() { # <path> [label]
    if [ -e "$1" ]; then _pass "${2:-exists: $1}"
    else _fail "${2:-exists: $1} — missing"; fi
}

assert_file_absent() {  # <path> [label]
    if [ ! -e "$1" ]; then _pass "${2:-absent: $1}"
    else _fail "${2:-absent: $1} — unexpectedly present"; fi
}

assert_grep() {         # <pattern> <file> [label]  — pattern present in file
    local pat=$1 file=$2 label=${3:-"/$1/ in $(basename "$2")"}
    if [ -f "$file" ] && grep -qE "$pat" "$file"; then _pass "$label"
    else _fail "$label — pattern not found"; fi
}

# --- command assertions -------------------------------------------------------

assert_allows() {       # <label> <cmd...>   — command must exit 0 (action permitted)
    local label=$1; shift
    if "$@" >/dev/null 2>&1; then _pass "$label"
    else _fail "$label — command refused/failed: $*"; fi
}

assert_refuses() {      # <label> <cmd...>   — command must exit nonzero (action refused)
    local label=$1; shift
    if "$@" >/dev/null 2>&1; then _fail "$label — command unexpectedly succeeded: $*"
    else _pass "$label"; fi
}

# --- domain-specific assertions (used by later phases) ------------------------

assert_nginx_clean() {  # [label]  — `nginx -t` passes; skips cleanly where nginx is absent
    local label=${1:-"nginx -t clean"}
    if ! command -v nginx >/dev/null 2>&1; then
        printf '    %sskip%s %s (nginx not installed)\n' "$_C_DIM" "$_C_NC" "$label"
        return 0
    fi
    if sudo nginx -t >/dev/null 2>&1; then _pass "$label"
    else _fail "$label — nginx -t reported errors"; fi
}

assert_unserializes() { # <php-serialized-string> [label]  — value still unserializes (rebind safety)
    local val=$1 label=${2:-"value still unserializes"}
    if ! command -v php >/dev/null 2>&1; then
        printf '    %sskip%s %s (php not installed)\n' "$_C_DIM" "$_C_NC" "$label"
        return 0
    fi
    if php -r 'exit(unserialize($argv[1])===false && $argv[1]!=="b:0;" ? 1 : 0);' "$val" >/dev/null 2>&1; then
        _pass "$label"
    else
        _fail "$label — unserialize() failed (serialized length header likely corrupted)"
    fi
}

# --- manual ------------------------------------------------------------------

pass() { _pass "$1"; }
fail() { _fail "$1"; }

# --- summary / exit code (installed automatically) ----------------------------

_assert_finish() {
    if [ "$_ASSERT_TOTAL" -eq 0 ]; then
        printf '  %sno assertions made%s\n' "$_C_RED" "$_C_NC"
        exit 1
    elif [ "$_ASSERT_FAILS" -gt 0 ]; then
        printf '  %s%d/%d assertions failed%s\n' "$_C_RED" "$_ASSERT_FAILS" "$_ASSERT_TOTAL" "$_C_NC"
        exit 1
    else
        printf '  %s%d/%d assertions passed%s\n' "$_C_GREEN" "$_ASSERT_TOTAL" "$_ASSERT_TOTAL" "$_C_NC"
        exit 0
    fi
}

trap _assert_finish EXIT
