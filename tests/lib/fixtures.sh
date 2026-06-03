#!/usr/bin/env bash
#
# fixtures.sh — builds a throwaway APP_HOME with registry records + wp-configs
# for L1/L2 tests (Task T.2). Requires common.sh + registry.sh already sourced.
#
# The standard scene (fixture_standard) includes the §2.1 incident artifact: a
# `creating` clone whose wp-config still names the blueprint DB.
#

fixture_init() {
    FIXTURE_HOME="$(mktemp -d)"
    export APP_HOME="$FIXTURE_HOME"
    export APP_DIR="$FIXTURE_HOME/apps"
    export SITES_DIR="$FIXTURE_HOME/apps/sites.d"
    export WEB_ROOT="$FIXTURE_HOME/www"
    export BACKUP_ROOT="$FIXTURE_HOME/backups"
    export CACHE_ROOT="$FIXTURE_HOME/cache"
    export LOGS_ROOT="$FIXTURE_HOME/logs"
    export OPERATIONS_LOG="$FIXTURE_HOME/logs/operations.log"   # keep audit log inside the fixture
    mkdir -p "$SITES_DIR" "$WEB_ROOT" "$BACKUP_ROOT" "$CACHE_ROOT" "$LOGS_ROOT"
}

fixture_cleanup() { [ -n "${FIXTURE_HOME:-}" ] && rm -rf "$FIXTURE_HOME"; }

# Write a registry record.
fixture_record() {  # domain type parent status protected db_name db_user prefix docroot
    registry_clear
    REG_DOMAIN=$1 REG_TYPE=$2 REG_PARENT=$3 REG_STATUS=$4 REG_PROTECTED=$5
    REG_DB_NAME=$6 REG_DB_USER=$7 REG_DB_HOST=localhost REG_TABLE_PREFIX=$8 REG_DOC_ROOT=$9
    REG_CREATED=2026-06-01 REG_BACKUP_FREQ=none REG_SSL_MODE=wildcard REG_INDEXING=blocked
    registry_save "$1"
}

# Write a wp-config.php with the given bindings.
fixture_wpconfig() {    # docroot db_name db_user prefix
    mkdir -p "$1"
    cat > "$1/wp-config.php" <<EOF
<?php
define( 'DB_NAME', '$2' );
define( 'DB_USER', '$3' );
define( 'DB_PASSWORD', 'secret' );
define( 'DB_HOST', 'localhost' );
\$table_prefix = '$4';
EOF
}

# Consistent site: record + matching wp-config at the docroot.
fixture_site() {    # domain type parent status protected db_name db_user prefix docroot
    fixture_record "$@"
    fixture_wpconfig "${9}" "$6" "$7" "$8"
}

# The standard scene used across guard/safety tests.
fixture_standard() {
    fixture_init
    local w="$WEB_ROOT"
    # blueprint (PROTECTED)
    fixture_site blueprint.dev.example.com blueprint "" active true \
        bp_db bp_usr bp_ "$w/blueprint.dev.example.com"
    # a production site
    fixture_site shop.example.com production "" active false \
        prod_db prod_usr sh_ "$w/shop.example.com"
    # a dev clone of the blueprint
    fixture_site acme.dev.example.com dev blueprint.dev.example.com active false \
        dev_db dev_usr ac_ "$w/acme.dev.example.com"
    # a staging site nested INSIDE the production docroot
    fixture_site staging.shop.example.com staging shop.example.com active false \
        stg_db stg_usr st_ "$w/shop.example.com/staging"
    # two sites claiming the SAME db (claimed-by-another)
    fixture_site twin1.example.com production "" active false shared_db t1_usr t1_ "$w/twin1.example.com"
    fixture_site twin2.example.com production "" active false shared_db t2_usr t2_ "$w/twin2.example.com"
    # a site whose db is ALSO named by a stray foreign wp-config
    fixture_site alpha.example.com production "" active false alpha_db al_usr al_ "$w/alpha.example.com"
    fixture_wpconfig "$w/stray" alpha_db stray_usr str_      # stray foreign reference

    # THE INCIDENT: record says clone_db (STATUS=creating); wp-config still names bp_db
    fixture_record clone.dev.example.com dev blueprint.dev.example.com creating false \
        clone_db clone_usr cl_ "$w/clone.dev.example.com"
    fixture_wpconfig "$w/clone.dev.example.com" bp_db bp_usr bp_   # <-- the blueprint DB
}
