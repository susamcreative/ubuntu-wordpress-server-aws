#!/usr/bin/env bash
#
# test_harness_selftest.sh — proves the assert library works (Task T.1 acceptance).
# Every assertion here is on its PASSING path, so this file must stay green.
# The FAILING path (that a bad assertion makes the file exit nonzero) is proven
# separately by tests/run.sh's own verification, not committed as a red test.
#
source "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"

# value assertions
assert_eq   "abc" "abc"            "assert_eq matches"
assert_ne   "abc" "xyz"            "assert_ne distinguishes"
assert_contains     "hello world" "lo wo"  "assert_contains finds substring"
assert_not_contains "hello world" "xyz"    "assert_not_contains rejects absent"

# filesystem assertions
_tmp="$(mktemp)"
printf 'DB_NAME="example_db"\nTYPE="production"\n' > "$_tmp"
assert_file_present "$_tmp"                 "assert_file_present on a real file"
assert_file_absent  "/no/such/path/xyzzy"  "assert_file_absent on a missing file"
assert_grep 'TYPE="production"' "$_tmp"     "assert_grep finds a registry field"
rm -f "$_tmp"

# command assertions
assert_allows  "assert_allows on a succeeding command" true
assert_refuses "assert_refuses on a failing command"   false
