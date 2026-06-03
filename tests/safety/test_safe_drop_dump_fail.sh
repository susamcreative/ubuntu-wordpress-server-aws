#!/usr/bin/env bash
#
# SAFE-5 — when the mandatory pre-drop dump cannot be staged, safe_drop_database
# REFUSES and never drops (DESIGN §9 / TASKS §9). Real isolated mysqld: we prove
# the database is still there afterwards.
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/apps/lib/guards.sh"
source "$ROOT/tests/lib/db.sh"
source "$ROOT/tests/lib/fixtures.sh"

if ! db_start; then fail "could not start isolated mysqld"; exit 0; fi
db_use_in_lib
fixture_init

# A normal, droppable site bound 1:1 to its own DB.
db -e "CREATE DATABASE victim_db; USE victim_db; CREATE TABLE t(i INT); INSERT INTO t VALUES (1);"
docroot="$WEB_ROOT/drop.example.com"
fixture_site drop.example.com production "" active false victim_db v_usr v_ "$docroot"

# Precondition: the guard WOULD allow this drop (so a refusal below is purely the
# dump-staging failure, not some other guard).
assert_allows "precondition: the drop is otherwise permitted" \
    can_drop_database victim_db drop.example.com

# Sabotage the pre-drop dump destination: a regular FILE where pre-removal/ must be
# created, so `mkdir -p .../pre-removal` fails.
: > "$BACKUP_ROOT/drop.example.com"

assert_refuses "SAFE-5: unstageable pre-drop dump → safe_drop_database refuses" \
    safe_drop_database victim_db drop.example.com
assert_allows "SAFE-5: the database is intact (no drop was attempted)" \
    db -e "USE victim_db;"

db_stop
fixture_cleanup
