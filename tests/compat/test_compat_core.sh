#!/usr/bin/env bash
#
# Compatibility suite, core (DESIGN §12.2, TASKS §10) — the invariants that must
# hold before the live upgrade. Runs on the seeded mirror (tests/fixtures).
#
# Covered here: C9 (SITES→registry 1:1), C8 (CLIs + add-site alias), C7 (logrotate
# glob), C4 (webhook additive), C6 (blueprint+dev untouched), C1 (per-site nginx
# configs untouched by an upgrade run) and C2 (backup parity — the DECISIVE gate).
# C3/C5 live in test_compat_restore_staging.sh.
#
# Real-server-only assertions (live curl, certs, systemctl) are skipped here with
# a clear message — the local harness has no serving stack.
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
seed_mirror_all
# Populate the registry exactly as the upgrade would (migrate runs with no DB).
bash "$ROOT/apps/migrate-registry.sh" "$SEED_NS" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# C9 — the SITES array maps 1:1 into the registry, same frequency
# ---------------------------------------------------------------------------
while IFS= read -r entry; do
    dom="${entry%%:*}"; freq="${entry##*:}"
    assert_eq "$freq" "$(registry_field "$dom" BACKUP_FREQ)" "C9: $dom freq maps $freq"
done < <(grep -oE '"[^"]+:[a-z]+"' "$LEGACY_BACKUP" | tr -d '"')
# Every backed-up SITES entry has exactly one record (no dupes, none missing).
n_sites="$(grep -cE '"[^"]+:[a-z]+"' "$LEGACY_BACKUP")"
n_backed="$(for d in $(registry_list); do [ "$(registry_field "$d" BACKUP_FREQ)" != none ] && echo "$d"; done | wc -l | tr -d ' ')"
assert_eq "$n_sites" "$n_backed" "C9: backed-up record count == SITES entry count"

# ---------------------------------------------------------------------------
# C8 — interactive scripts keep their CLI; add-site.sh forwards to create-site.
# (The registry-era --help convention itself is covered by tests/unit/test_help.sh;
#  C8's unique compat invariant is the one renamed CLI — the add-site alias.)
# ---------------------------------------------------------------------------
assert_allows "C8: add-site.sh alias is still invocable" bash "$ROOT/apps/add-site.sh" --help
alias_out="$(bash "$ROOT/apps/add-site.sh" --help 2>&1)"
assert_contains "$alias_out" "create-site" "C8: add-site.sh forwards to create-site.sh"

# ---------------------------------------------------------------------------
# C7 — log rotation continues to cover the new operations.log
# ---------------------------------------------------------------------------
assert_contains "$(cat "$ROOT/site-logs")" "logs/*.log" "C7: logrotate uses the logs/*.log glob"
case "logs/$(basename "$OPERATIONS_LOG")" in
    logs/*.log) pass "C7: glob matches operations.log" ;;
    *) fail "C7: glob does NOT match operations.log" ;;
esac

# ---------------------------------------------------------------------------
# C4 — health-check webhook payload is an additive superset, still valid JSON
# ---------------------------------------------------------------------------
# health-check.sh runs main() unconditionally (no source guard — noted for the T.4
# task), so it can't be sourced safely. Extract just the payload generator by
# brace-matching and eval it in isolation — no checks run.
fn="$(awk '
    /^generate_webhook_payload\(\) \{/ {f=1}
    f {
        print
        t=$0; ob=gsub(/[{]/,"",t); t=$0; cb=gsub(/[}]/,"",t); depth+=ob-cb
        if (depth<=0) exit
    }' "$ROOT/apps/health-check.sh")"
eval "$fn"
payload="$(generate_webhook_payload '[]' WARNING 'sample')"
if command -v php >/dev/null 2>&1; then
    assert_allows "C4: webhook payload is valid JSON" \
        php -r 'exit(json_decode($argv[1])===null ? 1 : 0);' "$payload"
    for k in timestamp hostname level summary issues; do
        assert_allows "C4: payload keeps documented field '$k'" \
            php -r '$o=json_decode($argv[1],true); exit(array_key_exists($argv[2],$o)?0:1);' "$payload" "$k"
    done
else
    skip_real "C4 JSON validation (php absent)"
fi

# ---------------------------------------------------------------------------
# C6 — blueprint and dev sites untouched, still on the wildcard
# ---------------------------------------------------------------------------
# (migrate types the blueprint 'dev' by heuristic; the operator marks it blueprint
#  post-migrate. The invariant here is that the record exists and is untouched.)
assert_allows "C6: blueprint record exists post-migrate" registry_exists "blueprint.$SEED_NS"
assert_allows "C6: dev clone record exists post-migrate" registry_exists "acme.$SEED_NS"
assert_eq "wildcard" "$(registry_field "acme.$SEED_NS" SSL_MODE)" "C6: dev clone stays on the wildcard cert"
assert_eq "blocked"  "$(registry_field "acme.$SEED_NS" INDEXING)" "C6: dev clone stays non-indexable"
skip_real "C6: curl blueprint + dev serve identically"

# ---------------------------------------------------------------------------
# C1 + C2 — drive a real backup run; nginx configs untouched, parity holds
# ---------------------------------------------------------------------------
# Snapshot per-site nginx configs before the upgrade-era backup run (C1 proxy).
nginx_before="$(cd "$NGINX_AVAILABLE" && for f in *; do printf '%s:%s\n' "$f" "$(cksum < "$f")"; done)"

source "$ROOT/apps/backup.sh"; set +u +e +o pipefail 2>/dev/null
ERROR_LOG="$LOGS_ROOT/backup-errors.log"

# Expected backup set per cascade, derived from the legacy SITES array (C2 oracle).
expected_for() {    # <run-freq> → domains that should be backed up, sorted
    local run=$1 e dom f
    while IFS= read -r e; do
        dom="${e%%:*}"; f="${e##*:}"
        backup_should_run "$f" "$run" && echo "$dom"
    done < <(grep -oE '"[^"]+:[a-z]+"' "$LEGACY_BACKUP" | tr -d '"') | sort
}
# What actually got an archive this run.
backed_this_run() { ls -1 "$BACKUP_ROOT"/*/*"_${1}_"*.tar.gz 2>/dev/null | xargs -n1 basename 2>/dev/null \
    | sed -E "s/_${1}_.*//" | sort -u; }

for run in daily weekly monthly; do
    rm -rf "$BACKUP_ROOT"/*/  # isolate each run's archives
    ( main "$run" ) >/dev/null 2>&1
    exp="$(expected_for "$run")"
    got="$(backed_this_run "$run")"
    assert_eq "$exp" "$got" "C2: $run run backs up exactly the old SITES set for this cascade"
done

nginx_after="$(cd "$NGINX_AVAILABLE" && for f in *; do printf '%s:%s\n' "$f" "$(cksum < "$f")"; done)"
assert_eq "$nginx_before" "$nginx_after" "C1: existing per-site nginx configs are untouched by the upgrade run"
skip_real "C1: curl every live domain pre/post for identical responses"

seed_mirror_cleanup
db_stop
