#!/usr/bin/env bash
#
# Validates DESIGN §6.3's decision to rebind URLs with wp-cli (serialization-aware)
# rather than SQL REPLACE() / byte substitution. Proves, with php (no network):
#   (a) a naive byte replacement on serialized data CORRUPTS it when lengths differ
#   (b) the serialization-aware approach wp-cli uses preserves it
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"

if ! command -v php >/dev/null 2>&1; then pass "php absent — skipping (covered on the mirror)"; exit 0; fi

# A serialized WP option holding a URL (as widgets/theme-mods/page-builders store it).
orig="$(php -r 'echo serialize(["home"=>"https://blueprint.dev.susam.co","n"=>5]);')"
assert_unserializes "$orig" "baseline: original serialized value is valid"

# (a) NAIVE byte replacement — 'blueprint' (9) → 'clientname' (10), length header now wrong.
naive="${orig//blueprint/clientname}"
assert_contains "$naive" "clientname.dev.susam.co" "naive replace changed the bytes"
# assert_unserializes returns failure on corrupted data; we assert that it FAILS:
if php -r 'exit(unserialize($argv[1])===false ? 0 : 1);' "$naive" >/dev/null 2>&1; then
    pass "naive byte replacement CORRUPTS serialized data (this is the hazard)"
else
    fail "expected naive replacement to corrupt serialization, but it survived"
fi

# (b) SERIALIZATION-AWARE replacement (what wp-cli search-replace does internally).
fixed="$(php -r '$o=unserialize($argv[1]); $o["home"]=str_replace("blueprint","clientname",$o["home"]); echo serialize($o);' "$orig")"
assert_unserializes "$fixed" "serialization-aware replace stays valid (wp-cli's approach)"
assert_contains "$(php -r 'echo unserialize($argv[1])["home"];' "$fixed")" "clientname.dev.susam.co" \
    "and the URL was actually rebased"
