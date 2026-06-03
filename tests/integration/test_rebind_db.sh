#!/usr/bin/env bash
#
# rebind.sh DB operations (Task P3.1, Tier A local) — proves the wp-cli-free
# replacement works FOR REAL against the isolated mysqld: srdb.php does a
# serialization-safe URL replace (length-changing), and scrub_users replaces all
# users with one fresh admin — using only PHP + SQL, no wp-cli.
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/tests/lib/db.sh"
source "$ROOT/apps/lib/rebind.sh"

if ! db_start; then fail "could not start isolated mysqld"; exit 0; fi
db_use_in_lib
command -v php >/dev/null 2>&1 || { pass "php absent — skipping"; db_stop; exit 0; }

# --- srdb.php: serialization-safe URL rebind (blueprint=9 → clientname=10 chars) ---
db -e "CREATE DATABASE wp; USE wp;
  CREATE TABLE wp_options (option_id INT PRIMARY KEY AUTO_INCREMENT, option_name VARCHAR(191), option_value LONGTEXT);"
ser="$(php -r 'echo serialize(["home"=>"https://blueprint.dev.susam.co","n"=>2]);')"
{ echo "USE wp;"
  echo "INSERT INTO wp_options(option_name,option_value) VALUES ('theme_mods','${ser}'),('siteurl','https://blueprint.dev.susam.co');"
} | db

SRDB_SOCKET="$DB_SOCK" SRDB_DB=wp SRDB_USER=root SRDB_PASS="" \
    php "$ROOT/apps/lib/srdb.php" wp_ "blueprint.dev.susam.co" "clientname.dev.susam.co" >/dev/null

site="$(db -N -e "SELECT option_value FROM wp.wp_options WHERE option_name='siteurl';")"
assert_eq "https://clientname.dev.susam.co" "$site" "plain siteurl rebased"

tm="$(db -N -e "SELECT option_value FROM wp.wp_options WHERE option_name='theme_mods';")"
assert_unserializes "$tm" "serialized value still valid after a length-changing rebind"
assert_contains "$tm" "clientname.dev.susam.co" "URL rebased INSIDE the serialized value"
assert_not_contains "$tm" "blueprint.dev.susam.co" "old URL fully gone"

# --- scrub_users: SQL, no wp-cli ---
db -e "USE wp;
  CREATE TABLE wp_users (ID BIGINT PRIMARY KEY, user_login VARCHAR(60), user_pass VARCHAR(255), user_nicename VARCHAR(50), user_email VARCHAR(100), user_registered DATETIME, user_status INT, display_name VARCHAR(250));
  CREATE TABLE wp_usermeta (umeta_id BIGINT PRIMARY KEY AUTO_INCREMENT, user_id BIGINT, meta_key VARCHAR(255), meta_value LONGTEXT);
  INSERT INTO wp_users (ID,user_login,user_registered,user_status) VALUES (1,'inherited1',NOW(),0),(2,'inherited2',NOW(),0);"

scrub_users wp wp_ 500 freshadmin 'Secr3t!' admin@client.com

assert_eq "1" "$(db -N -e 'SELECT COUNT(*) FROM wp.wp_users;')"          "exactly one user after scrub"
assert_eq "freshadmin" "$(db -N -e 'SELECT user_login FROM wp.wp_users;')" "the fresh admin"
assert_refuses "inherited users gone" bash -c "[ -n \"\$(mysql --socket='$DB_SOCK' -uroot -N -e \"SELECT user_login FROM wp.wp_users WHERE user_login LIKE 'inherited%'\")\" ]"
assert_eq "1" "$(db -N -e "SELECT COUNT(*) FROM wp.wp_usermeta WHERE meta_key='wp_capabilities';")" "admin capabilities set"

db_stop
