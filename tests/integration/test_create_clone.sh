#!/usr/bin/env bash
#
# create-site.sh clone orchestration (Task P3.2, Tier A local) — real DB clone with
# prefix rewrite, fresh wp-config, and intent-before-action. nginx/cert/wp-cli are
# stubbed (L3); the data/file/registry orchestration is exercised for real.
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/apps/lib/guards.sh"
source "$ROOT/apps/lib/rebind.sh"
source "$ROOT/tests/lib/fixtures.sh"
source "$ROOT/tests/lib/db.sh"
source "$ROOT/apps/create-site.sh"; set +u +e +o pipefail 2>/dev/null

if ! db_start; then fail "could not start isolated mysqld"; exit 0; fi
db_use_in_lib
rebind_urls() { return 0; }       # exercised for real in test_rebind_db.sh
scrub_users() { return 0; }
setup_site_nginx() { return 0; }  # nginx/cert verified on the box, not here
setup_site_ssl()   { return 0; }
fixture_init

# --- a blueprint: DB with wp_ tables + a prefix-embedded option key, and files ---
db -e "CREATE DATABASE bpdb; USE bpdb;
  CREATE TABLE wp_options (option_name VARCHAR(64), option_value TEXT);
  INSERT INTO wp_options VALUES ('wp_user_roles','x'), ('siteurl','http://bp');
  CREATE TABLE wp_posts (id INT); INSERT INTO wp_posts VALUES (1),(2);"
bp_root="$WEB_ROOT/blueprint.dev.example.com"
mkdir -p "$bp_root/wp-content/themes"; echo "<?php //index" > "$bp_root/index.php"; echo "BLUEPRINT~ONLY~MARKER" > "$bp_root/wp-config.php"
fixture_record blueprint.dev.example.com blueprint "" active true bpdb bp_u wp_ "$bp_root"
registry_set blueprint.dev.example.com NAMESPACE dev.example.com

# --- CLONE ---
create_clone_site client.dev.example.com blueprint.dev.example.com; rc=$?
assert_eq "0" "$rc" "clone create succeeds"

# registry record: active, dev, parented, fresh creds
assert_allows "new record exists" registry_exists client.dev.example.com
assert_eq "active" "$(registry_field client.dev.example.com STATUS)"  "STATUS flipped to active"
assert_eq "dev"    "$(registry_field client.dev.example.com TYPE)"    "TYPE=dev"
assert_eq "blueprint.dev.example.com" "$(registry_field client.dev.example.com PARENT)" "parented to the blueprint"
newdb="$(registry_field client.dev.example.com DB_NAME)"; newpfx="$(registry_field client.dev.example.com TABLE_PREFIX)"
assert_ne "bpdb" "$newdb" "new DB name differs from blueprint"
assert_ne "wp_"  "$newpfx" "new table prefix differs from blueprint"

# database: cloned with the NEW prefix, data intact, prefix-embedded keys rewritten
tables="$(db -N -e "SHOW TABLES FROM \`$newdb\`;" 2>/dev/null)"
assert_contains "$tables" "${newpfx}options" "tables use the new prefix"
assert_contains "$tables" "${newpfx}posts"   "all tables cloned with new prefix"
assert_not_contains "$tables" "wp_options"   "no blueprint-prefixed tables remain"
assert_eq "2" "$(db -N -e "SELECT COUNT(*) FROM \`$newdb\`.\`${newpfx}posts\`;" 2>/dev/null)" "row data cloned"
assert_eq "${newpfx}user_roles" "$(db -N -e "SELECT option_name FROM \`$newdb\`.\`${newpfx}options\` WHERE option_name LIKE '%user_roles';" 2>/dev/null)" "prefix-embedded option key rewritten"

# files: blueprint files copied, but wp-config is FRESH (not the blueprint's)
client_root="$WEB_ROOT/client.dev.example.com"
assert_file_present "$client_root/index.php" "blueprint files copied"
assert_not_contains "$(cat "$client_root/wp-config.php")" "BLUEPRINT~ONLY~MARKER" "wp-config is freshly written, not the blueprint's"
assert_grep "DB_NAME', '${newdb}'" "$client_root/wp-config.php" "wp-config has the new DB name"
assert_grep "table_prefix = '${newpfx}'" "$client_root/wp-config.php" "wp-config has the new prefix"

# --- INTENT-BEFORE-ACTION: a failure leaves a 'creating' record ---
db -e "DROP DATABASE bpdb;"     # blueprint DB now missing → clone step will fail
create_clone_site fail.dev.example.com blueprint.dev.example.com; rc=$?
assert_ne "0" "$rc" "clone fails when the blueprint DB is gone"
assert_allows "but the intent record was written" registry_exists fail.dev.example.com
assert_eq "creating" "$(registry_field fail.dev.example.com STATUS)" "left as 'creating' for rollback/resume"

db_stop
fixture_cleanup
