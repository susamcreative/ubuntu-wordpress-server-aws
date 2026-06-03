#!/usr/bin/env bash
# P1.4 example configs parse; P1.7 .gitignore protects instance state.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"

# --- examples are valid and document the fields the scripts read ---
( set -e; source "$ROOT/apps/server.conf.example"; [ -n "$ADMIN_EMAIL" ] && [ -n "$CERTBOT_EMAIL" ] )
assert_eq "0" "$?" "server.conf.example sources cleanly with required fields"

( set -e; source "$ROOT/apps/sites.d/example.com.conf.example"; [ -n "$DOMAIN" ] && [ -n "$DB_NAME" ] )
assert_eq "0" "$?" "registry example sources cleanly with required fields"

# Every REGISTRY_FIELD is present in the example (no undocumented field).
source "$ROOT/apps/lib/common.sh"; source "$ROOT/apps/lib/registry.sh"
missing=""
for f in "${REGISTRY_FIELDS[@]}"; do
    grep -qE "^${f}=" "$ROOT/apps/sites.d/example.com.conf.example" || missing="$missing $f"
done
assert_eq "" "$missing" "every registry field is documented in the example"

# --- .gitignore protects real instance state, not the examples ---
# (skips off-repo, e.g. on a deployed server where there is no .git to consult)
cd "$ROOT"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    assert_allows  "real registry record is ignored"   git check-ignore -q apps/sites.d/foo.conf
    assert_allows  "real server.conf is ignored"       git check-ignore -q apps/server.conf
    assert_refuses "registry .example is NOT ignored"  git check-ignore -q apps/sites.d/example.com.conf.example
    assert_refuses "server.conf.example is NOT ignored" git check-ignore -q apps/server.conf.example
    assert_refuses "sites.d README is NOT ignored"     git check-ignore -q apps/sites.d/README.md
else
    pass ".gitignore checks skipped (not inside a git work tree)"
fi
