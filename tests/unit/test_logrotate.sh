#!/usr/bin/env bash
# Regression coverage for the nginx log-reopen policy.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"

logrotate_config="$(cat "$ROOT/site-logs")"

assert_contains "$logrotate_config" 'logs/*.log' \
    "logrotate covers every managed log"
assert_contains "$logrotate_config" 'maxsize 1M' \
    "size cap does not override the daily rotation interval"
assert_not_contains "$logrotate_config" '    size 1M' \
    "logrotate does not use mutually overriding size and daily directives"
assert_contains "$logrotate_config" 'su _user_ _user_' \
    "rotation declares the owner of the app-writable log directory"
assert_contains "$logrotate_config" 'delaycompress' \
    "compression waits for nginx to release rotated logs"
assert_contains "$logrotate_config" '/bin/kill -USR1 "$(/bin/cat /run/nginx.pid)"' \
    "rotation directly signals nginx to reopen logs"
assert_not_contains "$logrotate_config" 'invoke-rc.d nginx rotate' \
    "rotation does not depend on init-script-specific rotate support"
