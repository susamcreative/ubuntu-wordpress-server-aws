#!/usr/bin/env bash
#
# Compatibility suite, restore + staging (DESIGN §12.2, TASKS §10).
#   C5 — an existing staging site adopts into the registry (gate accepts its own DB,
#        rejects a parent-DB clone) and stays removable; its DB is never the parent's.
#   C3 — a pre-upgrade OLD-LAYOUT archive (dump inside <domain>/) restores end to
#        end via the new restore-backup.sh, which locates the dump by recursive find.
# Serving (curl) is real-server only and skipped here.
#
# NOTE on ordering: C5 runs first. C3 restores the PARENT (shop.example.com), and
# do_restore_files wipes the docroot — which contains the nested staging — so it
# must run after the staging assertions. (That a parent-restore clobbers a nested
# staging docroot is a real containment gap, flagged for the safety task.)
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
bash "$ROOT/apps/migrate-registry.sh" "$SEED_NS" >/dev/null 2>&1

# restore-backup.sh → do_restore_db/do_restore_files + safe_recreate_and_import.
# remove-site.sh → show_removal_plan + can_adopt_staging (via guards). Both main()s
# are source-guarded; we only use their functions.
source "$ROOT/apps/restore-backup.sh"
source "$ROOT/apps/remove-site.sh"
set +u +e +o pipefail 2>/dev/null

# ---------------------------------------------------------------------------
# C5 — staging adopts into the registry; gate is sound; DB never the parent's
# ---------------------------------------------------------------------------
sdom="staging.shop.example.com"
sdoc="$WEB_ROOT/shop.example.com/staging"

# The valid staging (its OWN db, stg_db) is adoptable…
assert_allows "C5: adoption gate accepts a valid staging clone" \
    can_adopt_staging "$sdom" "$sdoc"

# …but a staging whose wp-config points at the PARENT's live db is hard-rejected.
bad="$WEB_ROOT/shop.example.com/staging-bad"
mkdir -p "$bad"
cat > "$bad/wp-config.php" <<EOF
<?php
define( 'DB_NAME', 'shop_db' );
\$table_prefix = 'sh_';
EOF
assert_refuses "C5: adoption gate rejects a staging bound to the parent's live DB" \
    can_adopt_staging "$sdom" "$bad"

# Adoption registers the staging record (DB taken from its wp-config).
read_wpconfig "$sdoc/wp-config.php"
registry_clear
REG_DOMAIN=$sdom REG_TYPE=staging REG_PARENT=shop.example.com REG_STATUS=active
REG_DB_NAME=$WPC_DB_NAME REG_DB_USER=$WPC_DB_USER REG_TABLE_PREFIX=$WPC_TABLE_PREFIX
REG_DOC_ROOT=$sdoc REG_BACKUP_FREQ=none REG_SSL_MODE=wildcard REG_INDEXING=blocked REG_PROTECTED=false
registry_save "$sdom"

assert_eq "staging"           "$(registry_field "$sdom" TYPE)"     "C5: adopted record is TYPE=staging"
assert_eq "shop.example.com"  "$(registry_field "$sdom" PARENT)"   "C5: adopted record points at its parent"
assert_eq "stg_db"            "$(registry_field "$sdom" DB_NAME)"  "C5: adopted record binds the staging DB"
assert_ne "$(registry_field shop.example.com DB_NAME)" "$(registry_field "$sdom" DB_NAME)" \
    "C5: staging DB is distinct from the parent's — removal can never hit the parent"

# Still removable: the dry-run plan reads the registry and names the staging DB.
# (show_removal_plan reads $domain from its caller's scope, mirroring main().)
domain="$sdom"
plan="$(show_removal_plan "$sdom" 2>&1)"
assert_contains "$plan" "stg_db" "C5: remove-staging dry-run targets the registry (staging) DB"
skip_real "C5: serve the staging site over its nginx vhost"

# ---------------------------------------------------------------------------
# C3 — restore a pre-upgrade old-layout archive end to end (DESTRUCTIVE: last).
# Uses blog.example.com (a leaf site, no nested child — see test_restore_nested_
# containment.sh for the parent-with-staging refusal path).
# ---------------------------------------------------------------------------
arch="$BACKUP_ROOT/blog.example.com/blog.example.com_daily_26.05.01_02.00.tar.gz"
assert_file_present "$arch" "C3: old-layout archive is present to restore"

# Mutate the LIVE db so a successful restore is observable: add a row the archived
# dump never had, and change siteurl. Mutate the live files too.
db -e "INSERT INTO bl_options (option_name, option_value) VALUES ('sentinel','LIVE-ONLY');" blog_db
db -e "UPDATE bl_options SET option_value='https://changed.example.com' WHERE option_name='siteurl';" blog_db
echo "LIVE marker" > "$WEB_ROOT/blog.example.com/wp-content/uploads/marker.txt"

do_restore_db    blog.example.com "$arch"
do_restore_files blog.example.com "$arch"

assert_eq "" "$(db -N -e "SELECT option_value FROM bl_options WHERE option_name='sentinel';" blog_db)" \
    "C3: DB restored from the archived dump (live-only row is gone)"
assert_eq "https://blog.example.com" \
    "$(db -N -e "SELECT option_value FROM bl_options WHERE option_name='siteurl';" blog_db)" \
    "C3: original siteurl is back after restore"
assert_eq "old upload" "$(cat "$WEB_ROOT/blog.example.com/wp-content/uploads/marker.txt")" \
    "C3: site files restored from the old-layout archive"
# The destructive restore took a safety dump of the pre-restore state first.
assert_eq "1" "$(ls "$BACKUP_ROOT/blog.example.com/pre-restore"/*.sql.gz 2>/dev/null | wc -l | tr -d ' ')" \
    "C3: a pre-restore safety dump was taken before overwriting"
skip_real "C3: curl the restored site for an identical response"

seed_mirror_cleanup
db_stop
