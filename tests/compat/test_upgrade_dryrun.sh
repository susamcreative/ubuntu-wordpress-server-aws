#!/usr/bin/env bash
#
# UPGRADE.md dry-run on the seeded mirror (Task P4.6, DESIGN §12.3). Runs the
# runbook's LITERAL command sequences for the gate steps and asserts the gates,
# so the doc can't drift from the finished scripts. The environment-specific
# steps (real certbot, systemctl, live curl) are real-server only and skipped.
#
# Validated here: A5 capture → C1 migrate → C5 decisive diff → D1 cutover diff +
# fresh archives. (C4 list-sites / D2 health-check use Linux coreutils — skipped.)
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/tests/lib/db.sh"
source "$ROOT/tests/fixtures/seed-mirror.sh"

skip_real() { printf '    %sskip%s %s (real-server only)\n' "$_C_DIM" "$_C_NC" "$1"; }

if ! db_start; then fail "could not start isolated mysqld"; exit 0; fi
db_use_in_lib
seed_mirror_all     # the legacy world: SITES array + www + DBs, no registry yet

# --- Step A5: capture current truth (domain:freq) from the SAVED old backup.sh --
# UPGRADE.md: grep -oE '"[^"]+:(daily|weekly|monthly)"' ~/apps/backup.sh | tr -d '"' | sort
pre="$LOGS_ROOT/pre-upgrade-sites.txt"
grep -oE '"[^"]+:(daily|weekly|monthly)"' "$LEGACY_BACKUP" | tr -d '"' | sort > "$pre"
assert_eq "blog.example.com:weekly
shop.example.com:daily" "$(cat "$pre")" "A5: pre-upgrade SITES truth captured"

# --- Step C1: populate the registry (freqs from the saved old backup.sh) --------
# UPGRADE.md: LEGACY_BACKUP=~/apps.pre-upgrade.../backup.sh ~/apps/migrate-registry.sh
bash "$ROOT/apps/migrate-registry.sh" "$SEED_NS" >/dev/null 2>&1

# --- Step C5: THE DECISIVE GATE — registry must equal old SITES array, 1:1 ------
# Run the runbook's exact derivation loop and diff.
reg="$LOGS_ROOT/registry-sites.txt"
for f in "$SITES_DIR"/*.conf; do
    d=$(grep '^DOMAIN=' "$f" | cut -d'"' -f2); fr=$(grep '^BACKUP_FREQ=' "$f" | cut -d'"' -f2)
    [ -n "$fr" ] && [ "$fr" != none ] && echo "$d:$fr"
done | sort > "$reg"
assert_eq "" "$(diff "$pre" "$reg")" "C5: registry == old SITES array (diff empty) — decisive gate"

# --- Step D1: the cutover — new backup backs up the SAME site set ---------------
source "$ROOT/apps/backup.sh"; set +u +e +o pipefail 2>/dev/null
ERROR_LOG="$LOGS_ROOT/backup-errors.log"
rm -rf "$BACKUP_ROOT"/*/                 # clear the seeded pre-upgrade archives first
( main monthly ) >/dev/null 2>&1

# Re-derive the registry set after the run — still 1:1 with the old SITES array.
reg2="$LOGS_ROOT/registry-sites.2.txt"
for f in "$SITES_DIR"/*.conf; do
    d=$(grep '^DOMAIN=' "$f" | cut -d'"' -f2); fr=$(grep '^BACKUP_FREQ=' "$f" | cut -d'"' -f2)
    [ -n "$fr" ] && [ "$fr" != none ] && echo "$d:$fr"
done | sort > "$reg2"
assert_eq "" "$(diff "$pre" "$reg2")" "D1: registry set still matches after the cutover backup"

# Fresh archives exist for exactly the pre-upgrade site set.
while IFS=: read -r dom freq; do
    [ -n "$dom" ] || continue
    got="$(ls "$BACKUP_ROOT/$dom/${dom}_monthly_"*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "1" "$got" "D1: fresh archive written for $dom"
done < "$pre"

# --- Steps the local harness can't run (no serving stack / Linux-only) ----------
skip_real "C4: list-sites.sh full render (uses Linux coreutils)"
skip_real "D2: health-check.sh (Linux stat -c / systemctl)"
skip_real "E: live curl, scheduled cron cycle, real certbot promote"

seed_mirror_cleanup
db_stop
