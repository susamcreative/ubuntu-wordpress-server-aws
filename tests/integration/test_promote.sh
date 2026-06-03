#!/usr/bin/env bash
#
# promote-site.sh (Task P3.3, Tier A local) — registry handover, rename, redirect,
# cache-salt, and the cert-FIRST abort guarantee. nginx/cert/wp-cli are stubbed.
#
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/apps/lib/common.sh"
source "$ROOT/apps/lib/registry.sh"
source "$ROOT/apps/lib/guards.sh"
source "$ROOT/apps/lib/rebind.sh"
source "$ROOT/tests/lib/fixtures.sh"
source "$ROOT/apps/promote-site.sh"; set +u +e +o pipefail 2>/dev/null

reload_nginx() { return 0; }
rebind_urls()  { return 0; }                  # exercised for real on the box
promote_setup_nginx()      { return 0; }      # nginx/cert verified on the box, not here
promote_remove_dev_nginx() { return 0; }
fixture_init
export NGINX_AVAILABLE="$FIXTURE_HOME/nginx/sa" NGINX_ENABLED="$FIXTURE_HOME/nginx/se" NGINX_REDIRECTS="$FIXTURE_HOME/nginx/rd"
mkdir -p "$NGINX_AVAILABLE" "$NGINX_ENABLED" "$NGINX_REDIRECTS"

make_dev_site() {   # set up a fresh dev site to promote
    local dev=$1 dr="$WEB_ROOT/$1"
    fixture_record "$dev" dev "" active false clientdb client_u cl_ "$dr"
    fixture_wpconfig "$dr" clientdb client_u cl_
    printf "\ndefine( 'WP_CACHE_KEY_SALT', 'OLDSALT' );\n" >> "$dr/wp-config.php"
    mkdir -p "$CACHE_ROOT/$dev"
    echo "server{}" > "$NGINX_AVAILABLE/$dev.conf"; ln -sf "$NGINX_AVAILABLE/$dev.conf" "$NGINX_ENABLED/$dev"
}

# --- CERT-FIRST ABORT: if the cert step fails, the dev site is untouched ---
make_dev_site abort.dev.example.com
promote_obtain_certificate() { return 1; }      # simulate DNS-not-pointed
promote_site abort.dev.example.com abort-real.com; rc=$?
assert_ne "0" "$rc" "promotion aborts when the cert step fails"
assert_allows "dev record still present"        registry_exists abort.dev.example.com
assert_eq "dev"    "$(registry_field abort.dev.example.com TYPE)"   "still TYPE=dev"
assert_eq "active" "$(registry_field abort.dev.example.com STATUS)" "still active (untouched)"
assert_refuses "no production record was created" registry_exists abort-real.com
assert_file_present "$WEB_ROOT/abort.dev.example.com" "dev docroot not renamed"

# --- HAPPY PATH ---
make_dev_site client.dev.example.com
promote_obtain_certificate() { return 0; }      # cert succeeds
promote_site client.dev.example.com client-real.com; rc=$?
assert_eq "0" "$rc" "promotion succeeds"

# registry handover
assert_refuses "dev record removed"             registry_exists client.dev.example.com
assert_allows  "production record created"      registry_exists client-real.com
assert_eq "production" "$(registry_field client-real.com TYPE)"          "TYPE=production"
assert_eq "allowed"    "$(registry_field client-real.com INDEXING)"      "INDEXING flipped to allowed"
assert_eq "daily"      "$(registry_field client-real.com BACKUP_FREQ)"   "added to daily backups"
assert_eq "client.dev.example.com" "$(registry_field client-real.com PROMOTED_FROM)" "records provenance"
assert_eq "client.dev.example.com" "$(registry_field client-real.com REDIRECT_FROM)" "records the redirect source"
assert_eq "clientdb"   "$(registry_field client-real.com DB_NAME)"       "same database (rename, not reclone)"

# files renamed
assert_file_absent  "$WEB_ROOT/client.dev.example.com"  "dev docroot gone"
assert_file_present "$WEB_ROOT/client-real.com/wp-config.php" "production docroot has the files"

# cache salt rotated
assert_not_contains "$(cat "$WEB_ROOT/client-real.com/wp-config.php")" "OLDSALT" "WP_CACHE_KEY_SALT rotated"

# redirect file: 301 to the new domain, both schemes, namespace wildcard cert
redir="$NGINX_REDIRECTS/client.dev.example.com.conf"
assert_file_present "$redir" "redirect file written"
assert_contains "$(cat "$redir")" "return 301 https://client-real.com" "301 to the new domain"
assert_contains "$(cat "$redir")" "listen 80;"  "redirect covers HTTP"
assert_contains "$(cat "$redir")" "/etc/letsencrypt/live/dev.example.com/fullchain.pem" "reuses the namespace wildcard cert"

# --- the crash-window is recoverable (handover dupes resolvable) ---
# (resolve_promotion_dupes is exercised directly in test_promotion_dupes.sh)

fixture_cleanup
