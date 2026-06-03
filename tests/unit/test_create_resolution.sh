#!/usr/bin/env bash
# create-site.sh pure cores (Task P3.2) — DESIGN §8.1 input-resolution table
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/tests/lib/fixtures.sh"
source "$ROOT/apps/create-site.sh"; set +u +o pipefail 2>/dev/null

# --- the five dots-signal rows (DESIGN §8.1) ---
out="$(resolve_site_domain clientname dev.example.com)"; rc=$?
assert_eq "clientname.dev.example.com" "$out" "ns + bare label → subdomain"
assert_eq "0" "$rc" "  (rc 0)"

out="$(resolve_site_domain clientname.dev.example.com dev.example.com)"; rc=$?
assert_eq "clientname.dev.example.com" "$out" "ns + already-qualified → as-is"
assert_eq "0" "$rc" "  (rc 0, no double-append)"

resolve_site_domain otherbrand.com dev.example.com >/dev/null; rc=$?
assert_eq "2" "$rc" "ns + outside-namespace full domain → ambiguous (rc 2)"

resolve_site_domain clientname "" >/dev/null; rc=$?
assert_eq "1" "$rc" "no ns + bare label → hard reject (rc 1)"

out="$(resolve_site_domain otherbrand.com "")"; rc=$?
assert_eq "otherbrand.com" "$out" "no ns + full domain → accept"
assert_eq "0" "$rc" "  (rc 0)"

# --- source selection ---
fixture_init
assert_eq "vanilla" "$(select_create_source)" "no blueprint → vanilla"
fixture_record bp.dev.example.com blueprint "" active true bp_db bp_usr bp_ "$WEB_ROOT/bp.dev.example.com"
assert_eq "clone:bp.dev.example.com" "$(select_create_source)" "one blueprint → clone it"
assert_eq "vanilla" "$(select_create_source --vanilla)" "--vanilla overrides to vanilla"
fixture_record bp2.dev.example.com blueprint "" active true b2_db b2_usr b2_ "$WEB_ROOT/bp2.dev.example.com"
select_create_source >/dev/null; rc=$?
assert_eq "2" "$rc" "multiple blueprints → needs --from (rc 2)"
assert_eq "clone:bp2.dev.example.com" "$(select_create_source --from bp2.dev.example.com)" "--from picks explicitly"

# --- credential format ---
generate_credentials
assert_eq "0" "$( [[ "$NEW_DBNAME" =~ ^site_[A-Za-z0-9]{8}$ ]]; echo $? )" "DB name format"
assert_eq "0" "$( [[ "$NEW_PREFIX" =~ ^[a-z][a-z0-9]*_$ ]]; echo $? )" "table prefix ends with underscore"
assert_eq "24" "${#NEW_DBPASS}" "DB password length"
assert_allows "admin id is in range" bash -c "[ \"$NEW_ADMIN_ID\" -ge 100 ] && [ \"$NEW_ADMIN_ID\" -le 9999 ]"

fixture_cleanup
