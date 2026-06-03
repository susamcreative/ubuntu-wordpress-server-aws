#!/usr/bin/env bash
#
# remove-staging.sh integration (Task P2.2, Tier A local) — removes a NESTED
# staging site (docroot inside the parent) without harming the parent, and refuses
# non-staging sites. Real mysqld.
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/apps/lib/guards.sh"
source "$ROOT/tests/lib/fixtures.sh"
source "$ROOT/tests/lib/db.sh"
source "$ROOT/apps/remove-staging.sh"; set +u +e +o pipefail 2>/dev/null

if ! db_start; then fail "could not start isolated mysqld"; exit 0; fi
db_use_in_lib
reload_nginx() { return 0; }
fixture_init
export NGINX_AVAILABLE="$FIXTURE_HOME/nginx/sa" NGINX_ENABLED="$FIXTURE_HOME/nginx/se" NGINX_REDIRECTS="$FIXTURE_HOME/nginx/rd"
mkdir -p "$NGINX_AVAILABLE" "$NGINX_ENABLED" "$NGINX_REDIRECTS"

# Parent production site, and a staging site whose docroot is NESTED inside it.
db -e "CREATE DATABASE parentdb;  USE parentdb;  CREATE TABLE t(id INT); INSERT INTO t VALUES (1);"
db -e "CREATE DATABASE stagingdb; USE stagingdb; CREATE TABLE t(id INT); INSERT INTO t VALUES (9);"
parent_dr="$WEB_ROOT/shop.example.com"
stg_dr="$WEB_ROOT/shop.example.com/staging"
fixture_record shop.example.com production "" active false parentdb parent_u sh_ "$parent_dr"
fixture_wpconfig "$parent_dr" parentdb parent_u sh_
fixture_record staging.shop.example.com staging shop.example.com active false stagingdb staging_u st_ "$stg_dr"
fixture_wpconfig "$stg_dr" stagingdb staging_u st_
echo "server{}" > "$NGINX_AVAILABLE/staging.shop.example.com.conf"
ln -sf "$NGINX_AVAILABLE/staging.shop.example.com.conf" "$NGINX_ENABLED/staging.shop.example.com"

# --- refuse a non-staging (production) site ---
do_remove_staging shop.example.com; rc=$?
assert_eq "1" "$rc" "production site refused by remove-staging"
assert_allows "parent DB still intact after refusal" db_exists parentdb

# --- remove the staging site ---
do_remove_staging staging.shop.example.com; rc=$?
assert_eq "0" "$rc" "staging removal succeeds"
assert_refuses "staging DB dropped"                 db_exists stagingdb
assert_file_absent "$stg_dr"                          "nested staging docroot removed"
assert_refuses "staging registry record gone"        registry_exists staging.shop.example.com
assert_file_absent "$NGINX_AVAILABLE/staging.shop.example.com.conf" "staging nginx config removed"

# --- the PARENT is completely untouched ---
assert_allows "parent DB intact"                     db_exists parentdb
assert_file_present "$parent_dr/wp-config.php"        "parent files intact"
assert_allows "parent registry record intact"        registry_exists shop.example.com

db_stop
fixture_cleanup
