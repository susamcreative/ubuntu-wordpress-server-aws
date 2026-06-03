#!/usr/bin/env bash
#
# deploy.sh (Task P4.1, local) — proves the critical property without a real server:
# deploying to a "server" dir SHIPS code but NEVER clobbers instance state.
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/deploy.sh"; set +u +e +o pipefail 2>/dev/null

command -v rsync >/dev/null 2>&1 || { pass "rsync absent — skipping"; exit 0; }

# Fake "server" with pre-existing INSTANCE STATE and an OLD script.
srv="$(mktemp -d)/apps/"
mkdir -p "$srv/sites.d"
echo "SECRET=keepme"            > "$srv/server.conf"               # real instance config
echo 'DOMAIN="live.example.com"' > "$srv/sites.d/live.example.com.conf"   # real registry record
echo "OLD VERSION"              > "$srv/backup.sh"                  # stale script to be updated

deploy_apps "$srv"

# instance state preserved
assert_grep "SECRET=keepme" "$srv/server.conf"                 "server.conf NOT overwritten"
assert_file_present "$srv/sites.d/live.example.com.conf"        "real registry record preserved"
assert_grep 'DOMAIN="live.example.com"' "$srv/sites.d/live.example.com.conf" "record contents intact"

# code shipped / updated
assert_not_contains "$(cat "$srv/backup.sh")" "OLD VERSION"     "stale script updated"
assert_grep "registry-driven consolidated backups" "$srv/backup.sh" "new backup.sh deployed"
assert_file_present "$srv/lib/guards.sh"                        "lib/ shipped with scripts (one unit)"
assert_file_present "$srv/lib/common.sh"                        "lib/common.sh shipped"

# examples shipped, but a real server.conf is never sourced FROM the repo
assert_file_present "$srv/server.conf.example"                 "server.conf.example shipped"
assert_file_present "$srv/sites.d/README.md"                   "sites.d/README shipped"

rm -rf "$(dirname "$srv")"
