#!/usr/bin/env bash
# Unit tests for lib/registry.sh (Task P1.2) — DESIGN §5.1, §6.1
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/tests/lib/fixtures.sh"

fixture_init

# --- round-trip: every field survives write→clear→read ---
registry_clear
REG_DOMAIN=shop.example.com REG_TYPE=production REG_PARENT="" REG_STATUS=active
REG_CREATED=2026-06-01 REG_PROTECTED=false
REG_DB_NAME=shop_db REG_DB_USER=shop_usr REG_DB_HOST=localhost REG_TABLE_PREFIX=ab12_
REG_DOC_ROOT="$WEB_ROOT/shop.example.com" REG_BACKUP_FREQ=daily REG_SSL_MODE=own REG_INDEXING=allowed
registry_save shop.example.com

registry_clear
registry_read shop.example.com
assert_eq "production"  "$REG_TYPE"        "round-trip TYPE"
assert_eq "shop_db"     "$REG_DB_NAME"     "round-trip DB_NAME"
assert_eq "ab12_"       "$REG_TABLE_PREFIX" "round-trip TABLE_PREFIX"
assert_eq "daily"       "$REG_BACKUP_FREQ" "round-trip BACKUP_FREQ"

# --- atomic write leaves no temp turds ---
leftovers="$(find "$SITES_DIR" -name '.shop.example.com.*' 2>/dev/null)"
assert_eq "" "$leftovers" "no leftover temp file after atomic save"

# --- registry_set updates one field, preserves the rest ---
registry_set shop.example.com BACKUP_FREQ weekly
registry_read shop.example.com
assert_eq "weekly" "$REG_BACKUP_FREQ" "registry_set changed BACKUP_FREQ"
assert_eq "shop_db" "$REG_DB_NAME"    "registry_set preserved DB_NAME"

# --- registry_field reads without disturbing caller REG_* ---
got="$(registry_field shop.example.com DB_USER)"
assert_eq "shop_usr" "$got" "registry_field returns the value"
assert_eq "shop_db"  "$REG_DB_NAME" "registry_field did not clobber caller REG_*"

# --- list / children / blueprint / claimants on the standard scene ---
fixture_standard
assert_eq "" "$(registry_find_blueprint >/dev/null; echo)" "find_blueprint runs"
assert_contains "$(registry_find_blueprint)" "blueprint.dev.example.com" "find_blueprint returns the blueprint"
assert_eq "staging.shop.example.com" "$(registry_list --type=staging)" "list --type=staging returns exactly the staging site (filter excludes others)"
assert_contains "$(registry_children blueprint.dev.example.com)" "acme.dev.example.com" "children by PARENT"
assert_contains "$(registry_db_claimants shared_db)" "twin1.example.com" "db claimants lists twin1"
assert_contains "$(registry_db_claimants shared_db)" "twin2.example.com" "db claimants lists twin2"

# --- find_blueprint fails cleanly when none exist ---
fixture_init   # fresh empty home
assert_refuses "find_blueprint refuses when none" registry_find_blueprint

fixture_cleanup
