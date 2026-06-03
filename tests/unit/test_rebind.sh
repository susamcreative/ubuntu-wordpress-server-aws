#!/usr/bin/env bash
# lib/rebind.sh pure functions (Task P3.1) — DESIGN §6.3, §8.1, §10.2
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/rebind.sh"

dr="$(mktemp -d)"

# --- write_wpconfig: fresh, complete, correct bindings ---
salts="$(generate_salts_block)"
write_wpconfig "$dr" mysite_db mysite_usr 'p@ss-w0rd' localhost ab12_ cachekey123 "$salts"
read_wpconfig "$dr/wp-config.php"
assert_eq "mysite_db"  "$WPC_DB_NAME"     "write_wpconfig DB_NAME round-trips"
assert_eq "mysite_usr" "$WPC_DB_USER"     "write_wpconfig DB_USER round-trips"
assert_eq "ab12_"      "$WPC_TABLE_PREFIX" "write_wpconfig table_prefix round-trips"
assert_grep "WP_CACHE_KEY_SALT', 'cachekey123'" "$dr/wp-config.php" "per-site cache salt set"
assert_grep "FS_METHOD', 'direct'"              "$dr/wp-config.php" "FS_METHOD present"
assert_grep "require_once ABSPATH" "$dr/wp-config.php" "ends with wp-settings require"
# 8 salt defines present
assert_eq "8" "$(grep -cE "define\( '(AUTH|SECURE_AUTH|LOGGED_IN|NONCE)_(KEY|SALT)'" "$dr/wp-config.php")" "8 salt defines"
# php lint if available
if command -v php >/dev/null 2>&1; then
    assert_allows "generated wp-config is valid PHP" php -l "$dr/wp-config.php"
fi

# --- DB_NAME == DB_USER collision is a non-issue (separate defines) ---
write_wpconfig "$dr" samename samename pw localhost p_ cs "$salts"
read_wpconfig "$dr/wp-config.php"
assert_eq "samename" "$WPC_DB_NAME" "collision: DB_NAME"
assert_eq "samename" "$WPC_DB_USER" "collision: DB_USER (not corrupted)"

# --- set_wpconfig_value: replace existing, append missing ---
set_wpconfig_value "$dr" WP_CACHE_KEY_SALT newsalt999
assert_grep "WP_CACHE_KEY_SALT', 'newsalt999'" "$dr/wp-config.php" "set_wpconfig_value replaced cache salt"
assert_not_contains "$(cat "$dr/wp-config.php")" "'cs'" "old cache salt gone"
set_wpconfig_value "$dr" WP_MEMORY_LIMIT 256M
assert_grep "WP_MEMORY_LIMIT', '256M'" "$dr/wp-config.php" "set_wpconfig_value appended a new define"

# --- generate_redirect_config: http + https, 301, wildcard cert ---
rc="$(generate_redirect_config client.dev.example.com client-real.com dev.example.com)"
assert_contains "$rc" "listen 80;"  "redirect covers HTTP"
assert_contains "$rc" "listen 443"  "redirect covers HTTPS"
assert_contains "$rc" "return 301 https://client-real.com" "301 to the new domain"
assert_contains "$rc" "/etc/letsencrypt/live/dev.example.com/fullchain.pem" "reuses the wildcard cert"
assert_contains "$rc" "server_name client.dev.example.com;" "matches the dev domain"

rm -rf "$dr"
