#!/usr/bin/env bash
#
# Registry convergence checks for health-check (Task P2.5) — DESIGN §8.7.
# Pure (no server): binding mismatch, orphans, promotion dupes, stuck operations.
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/apps/lib/guards.sh"
source "$ROOT/tests/lib/fixtures.sh"

fixture_init
now="$(date +%s)"

# (1) an ACTIVE site whose wp-config lies → CRITICAL binding mismatch
fixture_record good.example.com production "" active false good_db good_u g_ "$WEB_ROOT/good.example.com"
fixture_wpconfig "$WEB_ROOT/good.example.com" good_db good_u g_                 # consistent (no issue)
fixture_record liar.example.com production "" active false liar_db liar_u l_ "$WEB_ROOT/liar.example.com"
fixture_wpconfig "$WEB_ROOT/liar.example.com" wrongdb liar_u l_                 # wp-config lies

# (2) an orphan dir with no registry record
fixture_wpconfig "$WEB_ROOT/orphan.example.com" orphan_db o_u o_

# (3) a stale pre-promotion handover record
fixture_record acme.dev.example.com dev "" active false acme_db acme_u a_ "$WEB_ROOT/acme.dev.example.com"
registry_clear
REG_DOMAIN=acme.com REG_TYPE=production REG_STATUS=active REG_DB_NAME=acme_db REG_DB_USER=acme_u
REG_DB_HOST=localhost REG_TABLE_PREFIX=a_ REG_DOC_ROOT="$WEB_ROOT/acme.com" REG_PROMOTED_FROM=acme.dev.example.com
registry_save acme.com

# (4) a 'creating' op stuck for 2 days, and a fresh one that is NOT stuck
fixture_record stuck.example.com dev "" creating false stuck_db stuck_u s_ "$WEB_ROOT/stuck.example.com"
registry_set stuck.example.com STATUS_SINCE "$((now - 2*86400))"
fixture_record fresh.example.com dev "" creating false fresh_db fresh_u f_ "$WEB_ROOT/fresh.example.com"
registry_set fresh.example.com STATUS_SINCE "$now"

report="$(registry_health_report)"

assert_contains "$report" "CRITICAL|binding|liar.example.com" "binding mismatch on active site → CRITICAL"
assert_not_contains "$report" "good.example.com" "consistent active site is not flagged"
assert_contains "$report" "orphan" "orphan directory reported"
assert_contains "$report" "orphan.example.com" "the specific orphan is named"
assert_contains "$report" "dupe|acme.dev.example.com" "stale pre-promotion record reported"
assert_contains "$report" "stuck|stuck.example.com" "2-day-old creating op flagged stuck"
assert_not_contains "$report" "stuck|fresh.example.com" "fresh creating op is NOT flagged"

# direct check of the stuck detector window
assert_contains "$(find_stuck_operations)" "stuck.example.com" "find_stuck_operations finds the old op"
assert_not_contains "$(find_stuck_operations)" "fresh.example.com" "find_stuck_operations ignores the fresh op"

fixture_cleanup
