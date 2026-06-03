#!/usr/bin/env bash
# migrate-registry.sh tests (Task P1.6) — DESIGN §12, the C9 1:1 guarantee
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/tests/lib/fixtures.sh"

fixture_init
# sourcing a script that sets `set -u` would leak into the test shell; neutralize after.
source "$ROOT/apps/migrate-registry.sh"; set +u +o pipefail 2>/dev/null

# Three top-level sites on disk.
fixture_wpconfig "$WEB_ROOT/a.example.com" a_db a_usr a_
fixture_wpconfig "$WEB_ROOT/b.example.com" b_db b_usr b_
fixture_wpconfig "$WEB_ROOT/c.example.com" c_db c_usr c_

# A legacy backup.sh whose SITES array covers a (daily) and b (weekly), not c.
LEGACY_BACKUP="$FIXTURE_HOME/backup.sh"
cat > "$LEGACY_BACKUP" <<'EOF'
SITES=(
    "a.example.com:daily"
    "b.example.com:weekly"
)
EOF

proposed="$(migrate_propose)"
assert_contains "$proposed" "a.example.com" "proposed a.example.com"
assert_contains "$proposed" "c.example.com" "proposed c.example.com"

# Bindings adopted from each wp-config.
assert_eq "a_db"  "$(registry_field a.example.com DB_NAME)"     "adopted a's DB_NAME"
assert_eq "b_usr" "$(registry_field b.example.com DB_USER)"     "adopted b's DB_USER"
assert_eq "c_"    "$(registry_field c.example.com TABLE_PREFIX)" "adopted c's TABLE_PREFIX"
assert_eq "production" "$(registry_field a.example.com TYPE)"   "default TYPE=production"

# C9: every legacy SITES entry maps 1:1 to a record at the SAME frequency.
assert_eq "daily"  "$(registry_field a.example.com BACKUP_FREQ)" "C9: a frequency preserved (daily)"
assert_eq "weekly" "$(registry_field b.example.com BACKUP_FREQ)" "C9: b frequency preserved (weekly)"
assert_eq "none"   "$(registry_field c.example.com BACKUP_FREQ)" "C9: c not in SITES → none"

# Count: exactly one record per on-disk site, no extras.
count="$(registry_list | wc -l | tr -d ' ')"
assert_eq "3" "$count" "C9: exactly one record per site (no extras, no omissions)"

fixture_cleanup
