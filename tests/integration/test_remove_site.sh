#!/usr/bin/env bash
#
# remove-site.sh integration (Task P2.1, Tier A local) — real DB drop + file/cert/
# nginx/registry removal against the isolated mysqld. Proves the happy path AND the
# refusals (PROTECTED, children, binding mismatch), and that the pre-drop safety
# dump SURVIVES removal.
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/apps/lib/guards.sh"
source "$ROOT/tests/lib/fixtures.sh"
source "$ROOT/tests/lib/db.sh"
source "$ROOT/apps/remove-site.sh"; set +u +e +o pipefail 2>/dev/null

if ! db_start; then fail "could not start isolated mysqld"; exit 0; fi
db_use_in_lib
reload_nginx() { return 0; }      # no nginx here
fixture_init
export NGINX_AVAILABLE="$FIXTURE_HOME/nginx/sites-available"
export NGINX_ENABLED="$FIXTURE_HOME/nginx/sites-enabled"
export NGINX_REDIRECTS="$FIXTURE_HOME/nginx/redirects.d"
mkdir -p "$NGINX_AVAILABLE" "$NGINX_ENABLED" "$NGINX_REDIRECTS"

setup_site() {  # <domain> <db> [protected] [parent] [redirect_from]
    local d=$1 db=$2 prot=${3:-false} parent=${4:-} redir=${5:-}
    db -e "CREATE DATABASE IF NOT EXISTS \`$db\`; USE \`$db\`; CREATE TABLE t(id INT); INSERT INTO t VALUES (1);"
    local dr="$WEB_ROOT/$d"
    registry_clear
    REG_DOMAIN=$d REG_TYPE=production REG_PARENT=$parent REG_STATUS=active REG_PROTECTED=$prot
    REG_DB_NAME=$db REG_DB_USER=${db}_u REG_DB_HOST=localhost REG_TABLE_PREFIX=p_ REG_DOC_ROOT=$dr
    REG_REDIRECT_FROM=$redir REG_CREATED=2026-06-01
    registry_save "$d"
    fixture_wpconfig "$dr" "$db" "${db}_u" p_
    mkdir -p "$CACHE_ROOT/$d" "$BACKUP_ROOT/$d"
    touch "$BACKUP_ROOT/$d/${d}_daily_x.tar.gz" "$LOGS_ROOT/$d.access.log" "$LOGS_ROOT/$d.error.log"
    echo "server{}" > "$NGINX_AVAILABLE/$d.conf"; ln -sf "$NGINX_AVAILABLE/$d.conf" "$NGINX_ENABLED/$d"
}

# --- HAPPY PATH: a leaf production site is fully removed ---
setup_site shop.example.com shopdb
setup_site standalone.example.com standalonedb         # a bystander that must survive
do_remove_site shop.example.com; rc=$?
assert_eq "0" "$rc" "removal succeeds"
assert_refuses "DB actually dropped"            db_exists shopdb
assert_file_absent "$WEB_ROOT/shop.example.com" "docroot removed"
assert_file_absent "$CACHE_ROOT/shop.example.com" "cache removed"
assert_file_absent "$NGINX_AVAILABLE/shop.example.com.conf" "nginx config removed"
assert_file_absent "$NGINX_ENABLED/shop.example.com" "nginx symlink removed"
assert_file_absent "$LOGS_ROOT/shop.example.com.access.log" "logs removed"
assert_file_absent "$BACKUP_ROOT/shop.example.com/shop.example.com_daily_x.tar.gz" "backup archive removed"
assert_refuses "registry record deleted" registry_exists shop.example.com
# the safety dump survives
dump="$(ls "$BACKUP_ROOT"/shop.example.com/pre-removal/shopdb_*.sql.gz 2>/dev/null | head -1)"
assert_file_present "$dump" "pre-drop SAFETY dump survives removal"
# bystander untouched
assert_allows "bystander DB intact" db_exists standalonedb
assert_file_present "$WEB_ROOT/standalone.example.com" "bystander files intact"

# --- PROTECTED: refused, nothing touched ---
setup_site bp.dev.example.com bpdb true
do_remove_site bp.dev.example.com; rc=$?
assert_eq "1" "$rc" "PROTECTED site refuses removal"
assert_allows "PROTECTED DB intact" db_exists bpdb
assert_allows "PROTECTED record intact" registry_exists bp.dev.example.com

# --- CHILDREN: refused while a child is registered ---
setup_site parent.example.com parentdb false
setup_site child.parent.example.com childdb false parent.example.com
do_remove_site parent.example.com; rc=$?
assert_eq "1" "$rc" "site with registered children refuses removal"
assert_allows "parent DB intact" db_exists parentdb

# --- MISMATCH: wp-config lies → abort without --force; proceeds with --force ---
setup_site liar.example.com liardb false
fixture_wpconfig "$WEB_ROOT/liar.example.com" wrongdb liardb_u p_   # wp-config now lies
do_remove_site liar.example.com; rc=$?
assert_eq "1" "$rc" "binding mismatch aborts removal"
assert_allows "mismatch: DB still intact" db_exists liardb
REMOVE_FORCE=1 do_remove_site liar.example.com; rc=$?
assert_eq "0" "$rc" "--force overrides the mismatch"
assert_refuses "forced removal dropped the registry-named DB" db_exists liardb
unset REMOVE_FORCE

# --- REDIRECT cleanup on removal of a promoted site ---
setup_site acme.com acmedb false "" acme.dev.example.com
echo "server{}" > "$NGINX_REDIRECTS/acme.dev.example.com.conf"
do_remove_site acme.com >/dev/null 2>&1
assert_file_absent "$NGINX_REDIRECTS/acme.dev.example.com.conf" "promotion redirect file removed with the site"

db_stop
fixture_cleanup
