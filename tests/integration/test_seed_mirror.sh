#!/usr/bin/env bash
#
# seed-mirror integration (Task T.3, Tier A local) — proves the L4 mirror fixture
# resembles the pre-upgrade live server and drives the real migrate-registry.sh:
# legacy SITES array + web dirs + real DBs + nested staging + old-layout archives,
# producing a clean C9 mapping. Idempotent on re-run.
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/tests/lib/db.sh"
source "$ROOT/tests/fixtures/seed-mirror.sh"

if ! db_start; then fail "could not start isolated mysqld"; exit 0; fi
db_use_in_lib

seed_mirror_all

# --- the mirror's shape ------------------------------------------------------
n_top="$(ls "$WEB_ROOT"/*/wp-config.php 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "4" "$n_top" "four top-level sites provisioned"

assert_contains "$(cat "$LEGACY_BACKUP")" "shop.example.com:daily"  "legacy SITES has shop:daily"
assert_contains "$(cat "$LEGACY_BACKUP")" "blog.example.com:weekly" "legacy SITES has blog:weekly"
assert_not_contains "$(cat "$LEGACY_BACKUP")" "staging" "staging is NOT in the legacy SITES array"

assert_file_present "$WEB_ROOT/shop.example.com/staging/wp-config.php" "staging is nested inside its parent docroot"

# --- real databases exist ----------------------------------------------------
assert_allows "shop_db database created" db -e "USE shop_db;"
assert_allows "bp_db (blueprint) database created" db -e "USE bp_db;"

# --- migrate-registry against the mirror (C9 source) -------------------------
# Runs as a subprocess; it inherits the exported SEED_* paths + LEGACY_BACKUP.
bash "$ROOT/apps/migrate-registry.sh" "$SEED_NS" >/dev/null 2>&1

n_rec="$(registry_list | wc -l | tr -d ' ')"
assert_eq "4" "$n_rec" "migrate proposed one record per top-level site"
assert_eq "daily"  "$(registry_field shop.example.com BACKUP_FREQ)" "C9: shop freq maps daily"
assert_eq "weekly" "$(registry_field blog.example.com BACKUP_FREQ)" "C9: blog freq maps weekly"
assert_refuses "nested staging is NOT auto-proposed (manual review only)" \
    registry_exists staging.shop.example.com

# --- C3 source: old-layout archive (dump INSIDE <domain>/) -------------------
arch="$BACKUP_ROOT/shop.example.com/shop.example.com_daily_26.05.01_02.00.tar.gz"
assert_file_present "$arch" "old-layout pre-upgrade archive exists"
listing="$(tar -tzf "$arch")"
assert_contains "$listing" "shop.example.com/shop_db_26.05.01_02.00.sql.gz" "dump is INSIDE the domain dir (old layout)"
assert_contains "$listing" "shop.example.com/wp-config.php" "archive contains site files"

# --- idempotency: re-run in place changes nothing ----------------------------
SEED_HOME="$SEED_HOME" seed_mirror_all
n_top2="$(ls "$WEB_ROOT"/*/wp-config.php 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "4" "$n_top2" "re-running the seeder is idempotent (still four sites)"

seed_mirror_cleanup
db_stop
