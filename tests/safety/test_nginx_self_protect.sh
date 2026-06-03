#!/usr/bin/env bash
#
# SAFE-9 — safe_write_nginx_config is self-protecting: a config that fails
# validation is removed and the write aborts; a valid one persists (DESIGN §9,
# §10.2 / TASKS §9). No real nginx needed — we drive the validation seam.
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/apps/lib/guards.sh"

export NGINX_SUDO=""        # drop the privilege prefix for the test
tmpd="$(mktemp -d)"; path="$tmpd/site.conf"

# Case 1 — validation FAILS: the bad file must be removed and the call abort.
nginx_validate() { return 1; }
echo "this is { not valid nginx" | safe_write_nginx_config "$path"; rc=$?
assert_ne "0" "$rc" "SAFE-9: write aborts (nonzero) when nginx -t fails"
assert_file_absent "$path" "SAFE-9: the invalid config was removed (self-protect)"

# Case 2 — validation PASSES: the config is written and kept.
nginx_validate() { return 0; }
echo "server { listen 80; }" | safe_write_nginx_config "$path"; rc=$?
assert_eq "0" "$rc" "SAFE-9: a valid config write succeeds"
assert_file_present "$path" "SAFE-9: the valid config persists"

rm -rf "$tmpd"
