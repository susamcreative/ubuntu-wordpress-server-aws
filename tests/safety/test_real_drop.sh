#!/usr/bin/env bash
#
# SAFE-1 (real) — the incident replay against ACTUAL MySQL (Tier A, L3-local).
# Proves not just the guard's decision but the real DROP path + pre-drop dump:
# the blueprint database physically survives every attempt to destroy it via the
# failed clone, and only the correct orphan DB is actually dropped.
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/apps/lib/guards.sh"
source "$ROOT/tests/lib/fixtures.sh"
source "$ROOT/tests/lib/db.sh"

if ! db_start; then fail "could not start isolated mysqld"; exit 0; fi
db_use_in_lib                       # mysql_root/mysqldump_root → isolated socket
fixture_init

# Real databases: the precious blueprint DB and the orphan clone DB (with data).
db -e "CREATE DATABASE bp_db;"
db -e "CREATE DATABASE clone_db; USE clone_db; CREATE TABLE t(id INT); INSERT INTO t VALUES (1),(2),(3);"

# The incident: blueprint (PROTECTED, bp_db); failed clone registered to clone_db
# but whose on-disk wp-config still names bp_db.
fixture_record blueprint.dev.example.com blueprint "" active true bp_db bp_usr bp_ "$WEB_ROOT/blueprint.dev.example.com"
fixture_wpconfig "$WEB_ROOT/blueprint.dev.example.com" bp_db bp_usr bp_
fixture_record clone.dev.example.com dev blueprint.dev.example.com creating false clone_db clone_usr cl_ "$WEB_ROOT/clone.dev.example.com"
fixture_wpconfig "$WEB_ROOT/clone.dev.example.com" bp_db bp_usr bp_      # <-- still the blueprint DB

# 1) Drop bp_db "on behalf of" the clone → REFUSED; bp_db physically intact.
assert_refuses "real: drop blueprint DB via clone is refused" \
    safe_drop_database bp_db clone.dev.example.com
assert_allows  "real: bp_db still exists after that attempt" db_exists bp_db

# 2) Drop bp_db via its own (PROTECTED) record → REFUSED; still intact.
assert_refuses "real: drop blueprint DB directly is refused (PROTECTED)" \
    safe_drop_database bp_db blueprint.dev.example.com
assert_allows  "real: bp_db still exists" db_exists bp_db

# 3) Drop the CORRECT orphan clone_db → ALLOWED, actually dropped, dump taken.
safe_drop_database clone_db clone.dev.example.com; rc=$?
assert_eq "0" "$rc" "real: dropping the registered orphan clone_db is allowed"
assert_refuses "real: clone_db is actually gone" db_exists clone_db
assert_allows  "real: bp_db STILL intact (only the orphan was dropped)" db_exists bp_db

dump="$(ls "$BACKUP_ROOT"/clone.dev.example.com/pre-removal/clone_db_*.sql.gz 2>/dev/null | head -1)"
assert_file_present "$dump" "real: pre-drop dump was written before the drop"
assert_allows "real: pre-drop dump is a valid gzip with content" bash -c "gzip -t '$dump' && [ \$(gzip -dc '$dump' | wc -c) -gt 0 ]"

db_stop
fixture_cleanup
