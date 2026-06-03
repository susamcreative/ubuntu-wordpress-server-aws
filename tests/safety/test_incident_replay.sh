#!/usr/bin/env bash
#
# SAFE-1 — Incident replay (TASKS §9). The crown-jewel test: it reproduces the
# exact §2.1 failure (a half-cloned site whose wp-config still names the blueprint
# DB) and proves the redesign makes destroying the blueprint impossible.
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/apps/lib/guards.sh"
source "$ROOT/tests/lib/fixtures.sh"

fixture_standard
# Scene: blueprint.dev (DB bp_db, PROTECTED). Failed clone clone.dev — registry
# says DB clone_db (STATUS=creating); its on-disk wp-config still names bp_db.

# 1) PROVENANCE OVER ARTIFACTS: removal resolves the DB from the REGISTRY (clone_db),
#    never from the wp-config (which lies about bp_db).
registry_db="$(registry_field clone.dev.example.com DB_NAME)"
read_wpconfig "$WEB_ROOT/clone.dev.example.com/wp-config.php"
assert_eq "clone_db" "$registry_db"      "registry resolves clone.dev → clone_db"
assert_eq "bp_db"    "$WPC_DB_NAME"       "the wp-config artifact still lies (names bp_db)"
assert_ne "$WPC_DB_NAME" "$registry_db"   "artifact and provenance disagree — the incident condition"

# 2) The correct cleanup (drop the orphan clone DB) is ALLOWED.
assert_allows  "drop the real orphan clone_db is allowed" \
    can_drop_database clone_db clone.dev.example.com

# 3) THE INCIDENT ITSELF: dropping bp_db on behalf of clone.dev is REFUSED
#    (registry binds clone.dev to clone_db, not bp_db).
assert_refuses "drop blueprint DB via the clone is REFUSED" \
    can_drop_database bp_db clone.dev.example.com

# 4) Defense in depth: even targeting bp_db through its own (protected) record refuses.
assert_refuses "drop blueprint DB directly is REFUSED (PROTECTED)" \
    can_drop_database bp_db blueprint.dev.example.com

# 5) The mismatch is independently detectable (the Critical health-check signal).
verify_binding clone.dev.example.com
assert_eq "1" "$?" "verify_binding flags the registry/wp-config mismatch"

# 6) Net guarantee: there is NO requester for which bp_db can be dropped.
dropped_somehow=0
for d in $(registry_list); do
    if can_drop_database bp_db "$d" 2>/dev/null; then dropped_somehow=1; fi
done
assert_eq "0" "$dropped_somehow" "no registered site can drop the blueprint DB"

fixture_cleanup
