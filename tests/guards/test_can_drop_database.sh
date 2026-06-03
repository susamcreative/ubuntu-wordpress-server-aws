#!/usr/bin/env bash
# Guard decision tests for can_drop_database (Task P1.3) — DESIGN §6.2, §9
# Pure decisions only: NO database is ever touched here.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/apps/lib/guards.sh"
source "$ROOT/tests/lib/fixtures.sh"

fixture_standard

# GUARD-DROP-1 ALLOW: registry binds clone.dev→clone_db, unprotected, sole claimant,
# no foreign wp-config names clone_db.
assert_allows  "DROP-1 allow: own, unclaimed DB" \
    can_drop_database clone_db clone.dev.example.com

# GUARD-DROP-2 REFUSE: two registered sites claim shared_db.
assert_refuses "DROP-2 refuse: claimed by another site" \
    can_drop_database shared_db twin1.example.com

# GUARD-DROP-3 REFUSE: a stray foreign wp-config also references alpha_db.
assert_refuses "DROP-3 refuse: foreign wp-config references DB" \
    can_drop_database alpha_db alpha.example.com

# GUARD-DROP-4 REFUSE: blueprint is PROTECTED.
assert_refuses "DROP-4 refuse: PROTECTED site" \
    can_drop_database bp_db blueprint.dev.example.com

# GUARD-DROP-6 REFUSE: registry binds the requester to a DIFFERENT db
# (the wrong-target core — asking to drop the blueprint DB via the clone).
assert_refuses "DROP-6 refuse: registry binds requester to a different DB" \
    can_drop_database bp_db clone.dev.example.com

# SAFE-3 (recursive): the cross-reference scan is recursive, not top-level only.
# A wp-config nested deep inside another tree that names a site's DB must still
# block that DB's drop. Plant one referencing prod_db and confirm the refusal.
fixture_wpconfig "$WEB_ROOT/shop.example.com/nested/deep" prod_db nst_usr nst_
assert_refuses "SAFE-3 nested: a deep foreign wp-config reference blocks the drop" \
    can_drop_database prod_db shop.example.com

# Nested-child containment: removing the production docroot must refuse while a
# staging site lives inside it.
assert_refuses "docroot refuse: nested staging inside parent" \
    can_remove_docroot "$WEB_ROOT/shop.example.com" shop.example.com
assert_allows  "docroot allow: leaf site, no nested children" \
    can_remove_docroot "$WEB_ROOT/alpha.example.com" alpha.example.com

fixture_cleanup
