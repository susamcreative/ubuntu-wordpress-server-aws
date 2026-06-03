#!/usr/bin/env bash
#
# Staging adoption gate (Task P3.4) — DESIGN §8.4, §2.1. The incident caught at
# ADOPTION: a staging clone whose wp-config points at a live site's database is
# hard-rejected before anything is configured. Pure (no server).
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/apps/lib/guards.sh"
source "$ROOT/tests/lib/fixtures.sh"

fixture_init

# Registered LIVE sites: a production parent (prod_db) and a blueprint (bp_db).
fixture_record shop.example.com production "" active false prod_db shop_u sh_ "$WEB_ROOT/shop.example.com"
fixture_record blueprint.dev.example.com blueprint "" active true bp_db bp_u bp_ "$WEB_ROOT/blueprint.dev.example.com"

# (1) BROKEN clone — staging wp-config still names the parent's LIVE db → REJECT
broken="$WEB_ROOT/shop.example.com/staging"
fixture_wpconfig "$broken" prod_db shop_u sh_
assert_refuses "reject: staging points at the parent's live DB" \
    can_adopt_staging staging.shop.example.com "$broken"
assert_contains "$GUARD_REASON" "LIVE database" "explains why (the incident)"

# (2) BROKEN clone — staging wp-config names the blueprint DB → REJECT
broken2="$WEB_ROOT/staging.blueprint.dev.example.com"
fixture_wpconfig "$broken2" bp_db bp_u bp_
assert_refuses "reject: staging points at the blueprint DB" \
    can_adopt_staging staging.blueprint.dev.example.com "$broken2"

# (3) HEALTHY clone — staging has its OWN unique db → ACCEPT
good="$WEB_ROOT/shop.example.com/staging-ok"
fixture_wpconfig "$good" staging_db stg_u st_
assert_allows "accept: staging has its own unique DB" \
    can_adopt_staging staging.shop.example.com "$good"
# and the bindings were read for registration
assert_eq "staging_db" "$WPC_DB_NAME" "staging DB bindings captured for the record"

# (4) missing wp-config → reject cleanly
assert_refuses "reject: no wp-config at the path" \
    can_adopt_staging staging.x.example.com "$WEB_ROOT/nope"

fixture_cleanup
