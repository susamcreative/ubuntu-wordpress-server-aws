#!/usr/bin/env bash
#
# run.sh — test runner (Task T.1)
#
# Discovers and runs every tests/**/test_*.sh, prints a summary, and exits
# nonzero if ANY test file fails. Each test file is run in its own bash process
# so one file's failure (or early exit) can't abort the rest of the suite.
#
# USAGE:
#   tests/run.sh                 # run everything under tests/
#   tests/run.sh tests/unit      # run a subdirectory
#   tests/run.sh tests/unit/test_foo.sh   # run one file
#
# EXIT: 0 = all test files passed; 1 = one or more failed (or none found).
#

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

targets=("$@")
[ ${#targets[@]} -eq 0 ] && targets=("$HERE")

# Collect test files (test_*.sh) from the given files/dirs.
files=()
while IFS= read -r line; do
    [ -n "$line" ] && files+=("$line")
done < <(
    for t in "${targets[@]}"; do
        if [ -d "$t" ]; then
            find "$t" -name 'test_*.sh' -type f
        elif [ -f "$t" ]; then
            echo "$t"
        fi
    done | sort -u
)

if [ ${#files[@]} -eq 0 ]; then
    echo "No test_*.sh files found under: ${targets[*]}" >&2
    exit 1
fi

total=0
failed=0
failed_files=()

for f in "${files[@]}"; do
    printf '\n▶ %s\n' "${f#"$HERE"/}"
    total=$((total + 1))
    if ! bash "$f"; then
        failed=$((failed + 1))
        failed_files+=("$f")
    fi
done

printf '\n══════════════════════════════════════════\n'
if [ "$failed" -eq 0 ]; then
    printf 'ALL %d test file(s) passed\n' "$total"
    exit 0
else
    printf '%d/%d test file(s) FAILED:\n' "$failed" "$total"
    for f in "${failed_files[@]}"; do
        printf '  - %s\n' "${f#"$HERE"/}"
    done
    exit 1
fi
