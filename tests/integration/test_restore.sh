#!/usr/bin/env bash
#
# restore-backup.sh integration (Task P2.3, Tier A local) — the full resurrection
# round-trip: BACKUP a site → REMOVE it entirely → RESTORE it from the archive
# alone, recovering its registry record, database rows, and files. Real mysqld.
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/apps/lib/guards.sh"
source "$ROOT/apps/lib/rebind.sh"
source "$ROOT/tests/lib/fixtures.sh"
source "$ROOT/tests/lib/db.sh"
source "$ROOT/apps/backup.sh"
source "$ROOT/apps/remove-site.sh"
source "$ROOT/apps/restore-backup.sh"; set +u +e +o pipefail 2>/dev/null

if ! db_start; then fail "could not start isolated mysqld"; exit 0; fi
db_use_in_lib
reload_nginx() { return 0; }
fix_permissions() { return 0; }
fixture_init
ERROR_LOG="$LOGS_ROOT/backup-errors.log"
export NGINX_AVAILABLE="$FIXTURE_HOME/nginx/sa" NGINX_ENABLED="$FIXTURE_HOME/nginx/se" NGINX_REDIRECTS="$FIXTURE_HOME/nginx/rd"
mkdir -p "$NGINX_AVAILABLE" "$NGINX_ENABLED" "$NGINX_REDIRECTS"

# --- archive validation ---
assert_refuses "validate rejects a missing archive" validate_archive "/nope/x.tar.gz"
echo "garbage" > "$FIXTURE_HOME/bad.tar.gz"
assert_refuses "validate rejects a corrupt archive" validate_archive "$FIXTURE_HOME/bad.tar.gz"

# --- build a real site, with data + a content file ---
db -e "CREATE DATABASE shopdb; USE shopdb; CREATE TABLE p(id INT); INSERT INTO p VALUES (1),(2),(3);"
docroot="$WEB_ROOT/shop.example.com"
fixture_record shop.example.com production "" active false shopdb shop_usr sh_ "$docroot"
fixture_wpconfig "$docroot" shopdb shop_usr sh_
mkdir -p "$docroot/wp-content/uploads"; echo "precious" > "$docroot/wp-content/uploads/file.txt"

# --- BACKUP ---
backup_site shop.example.com 26.06.03_12.00 daily >/dev/null
archive="$BACKUP_ROOT/shop.example.com/shop.example.com_daily_26.06.03_12.00.tar.gz"
assert_file_present "$archive" "backup archive created"

# --- REMOVE the whole site (keeping the backup archive) ---
REMOVE_KEEP_BACKUPS=1 do_remove_site shop.example.com >/dev/null
assert_refuses "after removal: registry record gone" registry_exists shop.example.com
assert_refuses "after removal: database gone"         db_exists shopdb
assert_file_absent "$docroot"                          "after removal: files gone"
assert_file_present "$archive"                          "archive preserved for restore"

# --- RESTORE from the archive alone ---
dom="$(restore_registry_record "$archive")"
assert_eq "shop.example.com" "$dom" "archive self-identifies its domain"
assert_allows "registry record resurrected from the archive" registry_exists shop.example.com

do_restore_db shop.example.com "$archive"
assert_eq "0" "$?" "database restore succeeds"
assert_allows "database recreated" db_exists shopdb
rows="$(db -N -e "SELECT COUNT(*) FROM shopdb.p;" 2>/dev/null)"
assert_eq "3" "$rows" "all rows recovered (data, not just schema)"

do_restore_files shop.example.com "$archive"
assert_file_present "$docroot/wp-config.php" "wp-config restored"
assert_file_present "$docroot/wp-content/uploads/file.txt" "uploads restored"
assert_eq "precious" "$(cat "$docroot/wp-content/uploads/file.txt")" "file contents intact"

# --- restore_registry_record is a no-op when the site is already registered ---
again="$(restore_registry_record "$archive")"
assert_eq "shop.example.com" "$again" "still identifies the domain when already registered"

db_stop
fixture_cleanup
