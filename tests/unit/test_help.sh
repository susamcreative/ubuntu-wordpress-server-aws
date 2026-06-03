#!/usr/bin/env bash
# The --help convention (§14.6): every registry-era script self-documents from its
# header block, exits 0, and never performs any action.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"

for s in create-site promote-site remove-site remove-staging backup restore-backup migrate-registry deploy; do
    out="$(bash "$ROOT/apps/$s.sh" --help 2>&1)"; rc=$?
    assert_eq "0" "$rc" "$s.sh --help exits 0"
    assert_contains "$out" "$s.sh" "$s.sh --help prints its header (self-documenting)"
done

# -h is an alias for --help
assert_contains "$(bash "$ROOT/apps/backup.sh" -h 2>&1)" "backup.sh" "-h works as an alias"
