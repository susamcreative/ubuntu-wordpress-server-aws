#!/usr/bin/env bash
#
# rebind.sh — point a WordPress install at a new identity (Task P3.1, DESIGN §6.3)
#
# Two kinds of function here:
#   PURE (unit-testable now): wp-config generation/editing, salt + redirect-config
#     generation. File-in/file-out, no DB or nginx.
#   DB/file (need a real DB or root): rebind_urls (PHP + mysqli — NO wp-cli),
#     scrub_users (SQL), fix_permissions, regenerate_assets.
#
# NO wp-cli dependency: URL rebinding uses srdb.php (PHP, already required for
# WordPress); user scrubbing uses plain SQL. Everything stays on the LEMP stack.
#

[ -n "${_REBIND_SH_LOADED:-}" ] && return 0
_REBIND_SH_LOADED=1

_REBIND_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [ -z "${_COMMON_SH_LOADED:-}" ]; then
    source "${_REBIND_DIR}/common.sh"
fi

# --- PURE: wp-config generation/editing ---------------------------------------

# Eight WordPress salt defines, generated locally (offline, deterministic format).
generate_salts_block() {
    local keys=(AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY \
                AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT) k salt
    for k in "${keys[@]}"; do
        salt="$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^&*()_+=-' < /dev/urandom | head -c 64)"
        printf "define( '%s', '%s' );\n" "$k" "$salt"
    done
}

# Write a fresh, complete wp-config.php (DESIGN §8.1 step 5 — never edits a copied
# one, so a wrong-binding wp-config never exists on disk). DB_NAME==DB_USER is a
# non-issue because each value is a separate define.
write_wpconfig() {  # <docroot> <db_name> <db_user> <db_pass> <db_host> <prefix> <cache_salt> [salts_block]
    local dr=$1 name=$2 user=$3 pass=$4 host=$5 prefix=$6 csalt=$7 salts=${8:-}
    [ -z "$salts" ] && salts="$(generate_salts_block)"
    cat > "${dr}/wp-config.php" <<PHP
<?php
define( 'DB_NAME', '${name}' );
define( 'DB_USER', '${user}' );
define( 'DB_PASSWORD', '${pass}' );
define( 'DB_HOST', '${host}' );
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

${salts}

\$table_prefix = '${prefix}';

define( 'WP_CACHE_KEY_SALT', '${csalt}' );
define( 'FS_METHOD', 'direct' );
define( 'WP_DEBUG', false );

if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}
require_once ABSPATH . 'wp-settings.php';
PHP
}

# Replace (or append) a single define value. Used by promote for WP_CACHE_KEY_SALT.
# -i.bak form works on both BSD (macOS) and GNU sed.
set_wpconfig_value() {  # <docroot> <CONST> <value>
    local f="${1}/wp-config.php" c=$2 v=$3
    [ -f "$f" ] || return 1
    if grep -qE "define\([[:space:]]*['\"]${c}['\"]" "$f"; then
        sed -i.bak -E \
            "s|define\([[:space:]]*['\"]${c}['\"][[:space:]]*,[[:space:]]*['\"][^'\"]*['\"][[:space:]]*\)|define( '${c}', '${v}' )|" \
            "$f" && rm -f "${f}.bak"
    else
        printf "define( '%s', '%s' );\n" "$c" "$v" >> "$f"
    fi
}

# --- PURE: nginx redirect-config generation (promotion) -----------------------

# A promoted dev domain → 301 to its new home, over both HTTP and HTTPS, reusing
# the namespace wildcard cert (DESIGN §10.2).
generate_redirect_config() {    # <dev-domain> <new-domain> <wildcard-cert-domain>
    local dev=$1 new=$2 cert=$3
    cat <<NGINX
# ${dev} → ${new} (written by promote-site.sh)
server {
    listen 80;
    server_name ${dev};
    return 301 https://${new}\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${dev};
    ssl_certificate     /etc/letsencrypt/live/${cert}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${cert}/privkey.pem;
    return 301 https://${new}\$request_uri;
}
NGINX
}

# --- DB operations (no wp-cli; PHP + SQL only) --------------------------------

# Serialization-safe URL rebind via srdb.php (PHP, already required). Reads the
# site's DB credentials from its wp-config. SRDB_SOCKET may be set (tests).
rebind_urls() {     # <docroot> <old-url> <new-url>
    command -v php >/dev/null 2>&1 || { warning "php required for rebind_urls"; return 1; }
    local docroot=$1 old=$2 new=$3
    read_wpconfig "${docroot}/wp-config.php" || return 1
    SRDB_HOST="$WPC_DB_HOST" SRDB_DB="$WPC_DB_NAME" SRDB_USER="$WPC_DB_USER" SRDB_PASS="$WPC_DB_PASSWORD" \
    SRDB_SOCKET="${SRDB_SOCKET:-}" \
        php "${_REBIND_DIR}/srdb.php" "$WPC_TABLE_PREFIX" "$old" "$new"
}

# Replace inherited users with a single fresh admin, via SQL (no wp-cli). The MD5
# hash is computed in the shell (not via a SQL function — portable across MariaDB
# and MySQL); WordPress accepts MD5 and auto-upgrades to phpass on first login.
scrub_users() {     # <db> <prefix> <admin_id> <admin_user> <admin_pass> <admin_email>
    local db=$1 prefix=$2 id=$3 user=$4 pass=$5 email=$6 hash
    if command -v php >/dev/null 2>&1; then hash="$(php -r 'echo md5($argv[1]);' "$pass")"
    elif command -v md5sum >/dev/null 2>&1; then hash="$(printf '%s' "$pass" | md5sum | cut -d' ' -f1)"
    else hash="$(printf '%s' "$pass" | md5 -q)"; fi
    mysql_root "$db" <<SQL
DELETE FROM \`${prefix}usermeta\`;
DELETE FROM \`${prefix}users\`;
INSERT INTO \`${prefix}users\` (ID, user_login, user_pass, user_nicename, user_email, user_registered, user_status, display_name)
  VALUES (${id}, '${user}', '${hash}', 'admin', '${email}', NOW(), 0, 'Admin');
INSERT INTO \`${prefix}usermeta\` (user_id, meta_key, meta_value)
  VALUES (${id}, '${prefix}capabilities', 'a:1:{s:13:"administrator";s:1:"1";}'),
         (${id}, '${prefix}user_level', '10');
SQL
}

regenerate_assets() {   # <docroot>  — clear builder CSS + caches (per-site, never global flushall)
    rm -rf "${1}/wp-content/uploads/elementor/css" 2>/dev/null || true
    rm -rf "${1}/wp-content/cache" 2>/dev/null || true
    return 0
}

fix_permissions() {     # <docroot>  — ${USER}:www-data + setgid + group-write (DESIGN §8.1)
    local dr=$1
    sudo chown -R "$(whoami):www-data" "$dr"
    sudo find "$dr" -type d -exec chmod g+s {} \;
    sudo chmod -R g+w "$dr/wp-content"
}
