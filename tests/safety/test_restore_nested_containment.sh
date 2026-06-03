#!/usr/bin/env bash
#
# Restore-side containment (companion to SAFE-7, which covers removal). Restoring a
# PARENT whose docroot holds a registered nested site (e.g. a staging clone) must
# NOT wipe the child: do_restore_files refuses before touching the filesystem.
# Pure registry + fs decision — no database needed.
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/apps/lib/guards.sh"
source "$ROOT/tests/lib/fixtures.sh"
source "$ROOT/apps/restore-backup.sh"; set +u +e +o pipefail 2>/dev/null

fixture_init

parent="$WEB_ROOT/site.example.com"
fixture_site site.example.com         production ""               active false site_db s_usr s_ "$parent"
fixture_site staging.site.example.com staging    site.example.com active false stg2_db g_usr g_ "$parent/staging"

# A file inside the nested staging that must survive an attempted parent-restore.
echo "STAGING SURVIVES" > "$parent/staging/keep.txt"

# The containment check fires before any extraction, so the archive need not exist.
do_restore_files site.example.com "/nonexistent.tar.gz"; rc=$?
assert_ne "0" "$rc" "restore of a parent with a nested registered site is refused"
assert_file_present "$parent/staging/keep.txt" "the nested staging files were NOT wiped"

# Sanity: a leaf site with no nested child is NOT blocked by the containment guard
# (it fails later, on the missing archive — proving the guard didn't trip here).
out="$(do_restore_files staging.site.example.com "/nonexistent.tar.gz" 2>&1)"
assert_not_contains "$out" "nested registered site" "a leaf site is not blocked by containment"

fixture_cleanup
