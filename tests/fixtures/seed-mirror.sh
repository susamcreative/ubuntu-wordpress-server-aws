#!/usr/bin/env bash
#
# seed-mirror.sh — provisions the L4 "seeded mirror" (Task T.3, DESIGN §13).
#
# Builds a throwaway environment that resembles the PRE-upgrade live server, so
# the C1–C9 compatibility suite (§10) and the UPGRADE.md dry-run can run against
# something realistic without touching anything real. The mirror is the *legacy*
# world: web dirs + wp-configs + real databases + the legacy backup.sh SITES
# array + a cron fixture + old-layout archives — and crucially NO registry
# records. migrate-registry.sh produces those, which is exactly what C9 proves.
#
# Sourceable, like fixtures.sh/db.sh. The caller must first source db.sh and run
# `db_start` + `db_use_in_lib` (real mysqld on its own socket); the seeder uses
# `db` to create the databases. Then:
#
#     source tests/fixtures/seed-mirror.sh
#     seed_mirror_all              # build the default scene
#     ... run compat assertions ...
#     seed_mirror_cleanup
#
# Idempotent: re-running seed_mirror_all (with the same SEED_HOME) drops and
# recreates every database, rewrites every dir/config, and rebuilds the SITES
# array from scratch — no duplicates, no stale state.
#
# Run directly (with mysqld on PATH) for a self-test:  bash tests/fixtures/seed-mirror.sh
#

# The default-scene namespace (dev/blueprint sites live under *.dev.example.com).
SEED_NS="${SEED_NS:-dev.example.com}"

# Accumulates "domain:freq" entries for the legacy SITES array. Reset by init.
_SEED_SITES=()

# --- environment -------------------------------------------------------------

# Point the library + tools at a throwaway tree. Honors a pre-set SEED_HOME so a
# re-run lands in the same place (real idempotency); otherwise a fresh mktemp.
seed_mirror_init() {
    SEED_HOME="${SEED_HOME:-$(mktemp -d)}"
    export APP_HOME="$SEED_HOME"
    export APP_DIR="$SEED_HOME/apps"
    export SITES_DIR="$SEED_HOME/apps/sites.d"
    export WEB_ROOT="$SEED_HOME/www"
    export BACKUP_ROOT="$SEED_HOME/backups"
    export CACHE_ROOT="$SEED_HOME/cache"
    export LOGS_ROOT="$SEED_HOME/logs"
    export OPERATIONS_LOG="$SEED_HOME/logs/operations.log"
    # Fixture nginx tree + cron file (real server uses /etc/nginx, /var/spool/cron).
    export NGINX_AVAILABLE="$SEED_HOME/nginx/sites-available"
    export NGINX_ENABLED="$SEED_HOME/nginx/sites-enabled"
    export NGINX_REDIRECTS="$SEED_HOME/nginx/redirects.d"
    export SEED_CRON="$SEED_HOME/crontab.fixture"
    # The legacy backup.sh that holds SITES=(); migrate-registry reads this.
    export LEGACY_BACKUP="$APP_DIR/backup.sh.legacy"

    mkdir -p "$SITES_DIR" "$WEB_ROOT" "$BACKUP_ROOT" "$CACHE_ROOT" "$LOGS_ROOT" \
             "$NGINX_AVAILABLE" "$NGINX_ENABLED" "$NGINX_REDIRECTS"
    _SEED_SITES=()
}

seed_mirror_cleanup() {
    # Drop every database we created, then remove the tree.
    local f db
    if [ -d "$SITES_DIR" ] && declare -F db >/dev/null 2>&1; then
        for db in $(db -N -e "SHOW DATABASES" 2>/dev/null | grep -E '_db$'); do
            db -e "DROP DATABASE IF EXISTS \`$db\`;" 2>/dev/null || true
        done
    fi
    [ -n "${SEED_HOME:-}" ] && rm -rf "$SEED_HOME"
}

# --- building blocks ---------------------------------------------------------

# A throwaway WordPress database with a minimal wp_options table (siteurl/home +
# one serialized option), so rebind / C1-style checks have real content. Drops
# first → idempotent.
_seed_db() {    # <db_name> <table_prefix> <siteurl>
    local db_name=$1 prefix=$2 url=$3 t="${2}options"
    db -e "DROP DATABASE IF EXISTS \`$db_name\`; CREATE DATABASE \`$db_name\`;"
    db "$db_name" <<SQL
CREATE TABLE \`$t\` (
  option_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  option_name VARCHAR(191) NOT NULL DEFAULT '',
  option_value LONGTEXT NOT NULL,
  PRIMARY KEY (option_id),
  UNIQUE KEY option_name (option_name)
);
INSERT INTO \`$t\` (option_name, option_value) VALUES
  ('siteurl', '$url'),
  ('home', '$url'),
  ('blogname', 'Mirror site'),
  ('a_serialized_opt', 'a:1:{s:3:"url";s:${#url}:"$url";}');
SQL
}

# A web dir with a wp-config.php (same format read_wpconfig parses) + an upload.
_seed_webdir() {    # <docroot> <db_name> <db_user> <table_prefix>
    local docroot=$1 db_name=$2 db_user=$3 prefix=$4
    rm -rf "$docroot"
    mkdir -p "$docroot/wp-content/uploads"
    cat > "$docroot/wp-config.php" <<EOF
<?php
define( 'DB_NAME', '$db_name' );
define( 'DB_USER', '$db_user' );
define( 'DB_PASSWORD', 'secret' );
define( 'DB_HOST', 'localhost' );
\$table_prefix = '$prefix';
EOF
    echo "seeded upload for $db_name" > "$docroot/wp-content/uploads/marker.txt"
}

# A minimal per-site nginx vhost (so C1/C8 have configs to diff on a real server).
_seed_nginx() {     # <domain> <docroot>
    cat > "$NGINX_AVAILABLE/$1" <<EOF
server {
    listen 80;
    server_name $1;
    root $2;
    index index.php;
}
EOF
    ln -sf "$NGINX_AVAILABLE/$1" "$NGINX_ENABLED/$1"
}

# Provision one complete site. freq=none means "not backed up" → kept out of the
# legacy SITES array (mirrors a real server: only prod sites are scheduled).
seed_site() {   # <domain> <type> <freq> <db_name> <db_user> <table_prefix> <docroot>
    local domain=$1 type=$2 freq=$3 db_name=$4 db_user=$5 prefix=$6 docroot=$7
    local url="https://$domain"
    _seed_db    "$db_name" "$prefix" "$url"
    _seed_webdir "$docroot" "$db_name" "$db_user" "$prefix"
    _seed_nginx  "$domain" "$docroot"
    [ "$freq" != none ] && _SEED_SITES+=("$domain:$freq")
}

# Write the legacy backup.sh carrying the accumulated SITES=() array. This is the
# migration source of truth migrate-registry.sh reads via $LEGACY_BACKUP.
seed_legacy_sites_array() {
    {
        echo '#!/usr/bin/env bash'
        echo '# Legacy backup.sh (pre-upgrade) — only the SITES array matters to migrate.'
        echo 'SITES=('
        local e
        for e in "${_SEED_SITES[@]}"; do printf '    "%s"\n' "$e"; done
        echo ')'
    } > "$LEGACY_BACKUP"
}

# An OLD-LAYOUT pre-upgrade archive: the SQL dump lives INSIDE <domain>/ (not in a
# sibling tmp dir), which is the layout restore-backup.sh must still read (C3).
seed_old_archive() {    # <domain> <db_name> <stamp>
    local domain=$1 db_name=$2 stamp=$3
    local staging; staging="$(mktemp -d)"
    local d="$staging/$domain"
    mkdir -p "$d/wp-content/uploads"
    cat > "$d/wp-config.php" <<EOF
<?php
define( 'DB_NAME', '$db_name' );
EOF
    echo "old upload" > "$d/wp-content/uploads/marker.txt"
    db "$db_name" >/dev/null 2>&1 && mysqldump_root "$db_name" 2>/dev/null | gzip > "$d/${db_name}_${stamp}.sql.gz"
    mkdir -p "$BACKUP_ROOT/$domain"
    tar -czf "$BACKUP_ROOT/$domain/${domain}_daily_${stamp}.tar.gz" -C "$staging" "$domain"
    rm -rf "$staging"
}

# The existing cron entries (unchanged across the upgrade — C2/C7 depend on this).
seed_cron() {
    cat > "$SEED_CRON" <<EOF
0 2 * * *   $APP_DIR/backup.sh daily
0 3 * * 0   $APP_DIR/backup.sh weekly
0 4 1 * *   $APP_DIR/backup.sh monthly
0 * * * *   $APP_DIR/health-check.sh
EOF
}

# --- the default scene -------------------------------------------------------

# A couple of production sites (in the SITES array), the blueprint, a dev clone,
# and a staging site nested inside its parent's docroot — plus cron and a couple
# of old-layout archives. Matches DESIGN §13 "Test environment".
seed_mirror_all() {
    seed_mirror_init
    local w="$WEB_ROOT"

    # Production sites — these ARE backed up, so they populate the SITES array.
    seed_site shop.example.com production daily  shop_db  shop_usr sh_ "$w/shop.example.com"
    seed_site blog.example.com production weekly blog_db  blog_usr bl_ "$w/blog.example.com"

    # Blueprint (operator marks PROTECTED post-migrate) + a dev clone, both on the
    # wildcard, neither scheduled for backup (freq none → not in SITES).
    seed_site "blueprint.$SEED_NS" blueprint none bp_db   bp_usr   bp_ "$w/blueprint.$SEED_NS"
    seed_site "acme.$SEED_NS"      dev       none clone_db clone_usr ac_ "$w/acme.$SEED_NS"

    # Staging nested INSIDE the production parent's docroot (depth ≥3 → migrate
    # reports it for manual handling, never auto-proposes it).
    seed_site staging.shop.example.com staging none stg_db stg_usr st_ "$w/shop.example.com/staging"

    seed_legacy_sites_array
    seed_cron

    # A few pre-upgrade, old-layout archives for the restore-compat test (C3).
    seed_old_archive shop.example.com shop_db 26.05.01_02.00
    seed_old_archive blog.example.com blog_db 26.05.01_02.00
}

# --- self-test (run directly) ------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -uo pipefail
    ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
    source "$ROOT/apps/lib/common.sh"
    source "$ROOT/apps/lib/registry.sh"
    source "$ROOT/tests/lib/db.sh"
    if ! db_start; then echo "SKIP: no isolated mysqld available"; exit 0; fi
    db_use_in_lib

    echo "Building mirror (run 1)…"
    seed_mirror_all
    n1="$(ls "$WEB_ROOT"/*/wp-config.php 2>/dev/null | wc -l | tr -d ' ')"
    echo "  top-level sites: $n1; SITES array entries: ${#_SEED_SITES[@]}"
    echo "  legacy SITES: $(grep -c ':' "$LEGACY_BACKUP")"
    echo "Re-building in place (run 2, idempotency)…"
    SEED_HOME="$SEED_HOME" seed_mirror_all
    n2="$(ls "$WEB_ROOT"/*/wp-config.php 2>/dev/null | wc -l | tr -d ' ')"
    echo "  top-level sites after re-run: $n2"
    [ "$n1" = "$n2" ] && echo "PASS idempotent ($n1 == $n2)" || { echo "FAIL idempotent"; db_stop; seed_mirror_cleanup; exit 1; }

    seed_mirror_cleanup
    db_stop
    echo "PASS self-test"
fi
