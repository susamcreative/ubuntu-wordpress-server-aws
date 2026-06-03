#!/usr/bin/env bash
# Unit tests for lib/common.sh (Task P1.1) — DESIGN §6.4
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"

# --- domain validation (the dots-signal rule that create-site relies on) ---
assert_allows  "valid: example.com"        is_valid_domain example.com
assert_allows  "valid: sub.example.com"    is_valid_domain sub.example.com
assert_allows  "valid: a-b.example.co.uk"  is_valid_domain a-b.example.co.uk
assert_refuses "invalid: bare label"       is_valid_domain clientname
assert_refuses "invalid: uppercase"        is_valid_domain Example.com
assert_refuses "invalid: underscore"       is_valid_domain ex_ample.com
assert_refuses "invalid: no TLD"           is_valid_domain example

# --- bare-label detection (namespace subdomain vs full domain) ---
assert_allows  "bare: clientname"          is_bare_label clientname
assert_refuses "not bare: client.com"      is_bare_label client.com

# --- db name/user validation ---
assert_allows  "dbname ok"                 is_valid_dbname site_db_1
assert_refuses "dbname bad char"           is_valid_dbname "site-db"
assert_refuses "dbuser too long"           is_valid_dbuser "$(printf 'u%.0s' {1..33})"

# --- wp-config parsing (canonical extractor) ---
tmp="$(mktemp -d)"
cat > "$tmp/wp-config.php" <<'EOF'
<?php
define( 'DB_NAME', 'mysite_db' );
define('DB_USER',"mysite_db");
define( 'DB_PASSWORD', 'p@ss w0rd!' );
$table_prefix = 'xy12_';
EOF
read_wpconfig "$tmp/wp-config.php"
assert_eq "mysite_db" "$WPC_DB_NAME"      "wp-config DB_NAME (single quotes)"
assert_eq "mysite_db" "$WPC_DB_USER"      "wp-config DB_USER (double quotes, == DB_NAME)"
assert_eq "p@ss w0rd!" "$WPC_DB_PASSWORD" "wp-config DB_PASSWORD (spaces/specials)"
assert_eq "localhost" "$WPC_DB_HOST"      "wp-config DB_HOST defaults to localhost"
assert_eq "xy12_" "$WPC_TABLE_PREFIX"     "wp-config table_prefix"
rm -rf "$tmp"
