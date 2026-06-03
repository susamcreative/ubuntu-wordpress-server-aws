#!/usr/bin/env bash
# resolve_promotion_dupes (Task P3.3) — DESIGN §8.2 step 10 crash-window
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/apps/lib/guards.sh"
source "$ROOT/tests/lib/fixtures.sh"

fixture_init

# Healthy promotion handover that crashed between "write new" and "delete old":
# new production record points at the old dev record, both claim the same DB.
fixture_record acme.dev.example.com dev blueprint active false acme_db acme_usr ac_ "$WEB_ROOT/acme.dev.example.com"
registry_clear
REG_DOMAIN=acme.com REG_TYPE=production REG_STATUS=active REG_PROTECTED=false
REG_DB_NAME=acme_db REG_DB_USER=acme_usr REG_DB_HOST=localhost REG_TABLE_PREFIX=ac_
REG_DOC_ROOT="$WEB_ROOT/acme.com" REG_PROMOTED_FROM=acme.dev.example.com REG_CREATED=2026-06-02
registry_save acme.com

# An unrelated site that must NOT be flagged.
fixture_record shop.example.com production "" active false shop_db shop_usr sh_ "$WEB_ROOT/shop.example.com"

stale="$(resolve_promotion_dupes)"
assert_eq "acme.dev.example.com" "$stale" "stale pre-promotion record is identified (and only it)"

# No false positive when there is no promotion in flight.
registry_delete acme.com
assert_eq "" "$(resolve_promotion_dupes)" "no dupes when no promotion crash"

fixture_cleanup
