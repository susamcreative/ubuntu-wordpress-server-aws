#!/usr/bin/env bash
#
# Static analysis (Task T.4, DESIGN §12 DoD) — the structural guarantees, checked
# without a server:
#   1. every apps/*.sh parses (bash -n) and, if shellcheck is present, lints clean
#      of error-level findings;
#   2. every apps/*.sh self-documents on --help (exit 0, prints its header) and
#      never acts — the convention from §14.6;
#   3. every apps/*.sh is executable (a 100644 oversight once broke the add-site
#      alias's exec-forward);
#   4. the destruction primitives — `DROP DATABASE` and docroot `rm -rf` — appear
#      ONLY in lib/guards.sh. This is the structural proof that guards are the sole
#      destruction path (DESIGN §6.2, §9).
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"

# Portable array fill (macOS ships bash 3.2 — no `mapfile`).
SCRIPTS=()
while IFS= read -r line; do [ -n "$line" ] && SCRIPTS+=("$line"); done \
    < <(find "$ROOT/apps" -maxdepth 1 -name '*.sh' | sort)
have_shellcheck=0; command -v shellcheck >/dev/null 2>&1 && have_shellcheck=1

for f in "${SCRIPTS[@]}"; do
    name="$(basename "$f")"

    # 1. syntax
    assert_allows "bash -n: $name parses" bash -n "$f"
    # 1b. shellcheck (error severity only — style/info is out of scope here)
    if [ "$have_shellcheck" = 1 ]; then
        assert_allows "shellcheck (errors): $name" shellcheck -S error "$f"
    fi

    # 2. --help self-documents and exits 0
    out="$(bash "$f" --help 2>&1)"; rc=$?
    assert_eq "0" "$rc" "--help: $name exits 0"
    assert_contains "$out" "$name" "--help: $name prints its own header (self-documenting)"

    # 3. executable bit (so `exec ./script` and docs' ./apps/x.sh work everywhere)
    assert_allows "exec bit: $name is executable" test -x "$f"
done

if [ "$have_shellcheck" = 0 ]; then
    printf '    %sskip%s shellcheck lint (shellcheck not installed)\n' "$_C_DIM" "$_C_NC"
fi

# 4. destruction lives ONLY in guards.sh — the no-inline-DROP / no-inline-rm proof.
drop_hits="$(grep -rn 'DROP DATABASE' "$ROOT/apps" | grep -v '/lib/guards.sh:' || true)"
assert_eq "" "$drop_hits" "no 'DROP DATABASE' outside lib/guards.sh"

# docroot rm -rf: any rm -rf naming a docroot/web-root variable must be in guards.sh.
docroot_rm="$(grep -rnE 'rm -rf .*(REG_DOC_ROOT|DOC_ROOT|docroot|WEB_ROOT)' "$ROOT/apps" \
    | grep -v '/lib/guards.sh:' || true)"
assert_eq "" "$docroot_rm" "no docroot 'rm -rf' outside lib/guards.sh"
