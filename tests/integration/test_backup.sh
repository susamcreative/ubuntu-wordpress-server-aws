#!/usr/bin/env bash
#
# backup.sh integration (Task P2.4, Tier A local) — real mysqldump + tar against
# the isolated mysqld. Proves: cascade selection (C2), dump staged OUTSIDE the web
# root (security), self-describing archive, provenance cross-check, fail-loud, and
# scoped retention cleanup.
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/tests/lib/fixtures.sh"
source "$ROOT/tests/lib/db.sh"
source "$ROOT/apps/backup.sh"; set +u +e +o pipefail 2>/dev/null   # neutralize script's set -uo

if ! db_start; then fail "could not start isolated mysqld"; exit 0; fi
mysqldump_as() { shift 2; mysqldump --socket="$DB_SOCK" -u root "$@"; }   # dump via isolated socket
fixture_init
ERROR_LOG="$LOGS_ROOT/backup-errors.log"

# --- PURE cascade selection (C2 logic) ---
assert_allows  "daily run backs up daily site"     backup_should_run daily daily
assert_refuses "daily run skips weekly site"       backup_should_run weekly daily
assert_allows  "weekly run backs up daily site"    backup_should_run daily weekly
assert_allows  "weekly run backs up weekly site"   backup_should_run weekly weekly
assert_refuses "weekly run skips monthly site"     backup_should_run monthly weekly
assert_allows  "monthly run backs up weekly site"  backup_should_run weekly monthly
assert_refuses "monthly run skips 'none' site"     backup_should_run none monthly

# --- REAL backup of one site ---
db -e "CREATE DATABASE shopdb; USE shopdb; CREATE TABLE p(id INT); INSERT INTO p VALUES (1),(2);"
docroot="$WEB_ROOT/shop.example.com"
fixture_record shop.example.com production "" active false shopdb shop_usr sh_ "$docroot"
fixture_wpconfig "$docroot" shopdb shop_usr sh_
mkdir -p "$docroot/wp-content/uploads"; echo "hello" > "$docroot/wp-content/uploads/file.txt"

backup_site shop.example.com 26.06.03_10.00 daily; rc=$?
assert_eq "0" "$rc" "backup_site succeeds"
archive="$BACKUP_ROOT/shop.example.com/shop.example.com_daily_26.06.03_10.00.tar.gz"
assert_file_present "$archive" "archive created at the expected path"

# SECURITY: no SQL dump anywhere under the web root
assert_eq "" "$(find "$WEB_ROOT" -name '*.sql*' 2>/dev/null)" "no SQL dump staged in the web root"

# SELF-DESCRIBING: archive holds site files + the dump + the registry record
listing="$(tar -tzf "$archive")"
assert_contains "$listing" "shop.example.com/wp-config.php"         "archive contains site files"
assert_contains "$listing" "shopdb_26.06.03_10.00.sql.gz"          "archive contains the SQL dump"
assert_contains "$listing" "shop.example.com.conf"                 "archive contains the registry record (self-describing)"
assert_contains "$listing" "shop.example.com/wp-content/uploads/file.txt" "archive contains uploads"

# tmp staging cleaned
assert_file_absent "$BACKUP_ROOT/shop.example.com/tmp" "staging tmp dir removed"

# --- PROVENANCE cross-check: wp-config DB != registry DB → skip (rc 2) ---
db -e "CREATE DATABASE realdb;"
docroot2="$WEB_ROOT/bad.example.com"
fixture_record bad.example.com production "" active false realdb bad_usr bd_ "$docroot2"
fixture_wpconfig "$docroot2" wrongdb bad_usr bd_      # wp-config lies
backup_site bad.example.com 26.06.03_10.00 daily; rc=$?
assert_eq "2" "$rc" "binding mismatch is skipped (critical), not backed up"

# --- registry self-backup ---
backup_registry_snapshot 26.06.03_10.00
snap="$BACKUP_ROOT/registry/registry_26.06.03_10.00.tar.gz"
assert_file_present "$snap" "registry snapshot written"
assert_contains "$(tar -tzf "$snap")" "sites.d/shop.example.com.conf" "snapshot contains the registry"

# --- FAIL-LOUD: empty registry while sites exist on disk → exit 1 ---
fixture_init; ERROR_LOG="$LOGS_ROOT/backup-errors.log"
mkdir -p "$WEB_ROOT/ghost.example.com"; echo "<?php" > "$WEB_ROOT/ghost.example.com/wp-config.php"
( main daily ) >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "empty registry + on-disk sites → fail loud (exit 1)"

# --- SCOPED cleanup: per-site archive deleted, pre-removal + registry untouched ---
fixture_init; ERROR_LOG="$LOGS_ROOT/backup-errors.log"
mkdir -p "$BACKUP_ROOT/x.example.com/pre-removal" "$BACKUP_ROOT/registry"
old="$BACKUP_ROOT/x.example.com/x.example.com_daily_20.01.01_00.00.tar.gz"
keep_pre="$BACKUP_ROOT/x.example.com/pre-removal/x_daily_20.01.01_00.00.sql.gz"
keep_reg="$BACKUP_ROOT/registry/registry_20.01.01_00.00.tar.gz"
touch "$old" "$keep_pre" "$keep_reg"; touch -t 202001010000 "$old" "$keep_pre" "$keep_reg"
cleanup_old_backups daily
assert_file_absent  "$old"      "old per-site daily archive is pruned"
assert_file_present "$keep_pre" "pre-removal dump (depth 3) is NOT pruned"
assert_file_present "$keep_reg" "registry snapshot is NOT pruned"

db_stop
fixture_cleanup
