#!/usr/bin/env bash
#
# create-site.sh — unified site creation: vanilla or blueprint clone (Task P3.2)
# Implements: DESIGN §8.1. Replaces add-site.sh + the external newsite.sh.
#
# This file currently provides the PURE, unit-tested decision cores (domain
# resolution, source selection, credential generation). The full 14-step clone
# main() needs a real DB/nginx (no wp-cli) and is validated on the seeded mirror.
#
set -uo pipefail
SCRIPT_NAME="create-site.sh"

_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${_DIR}/lib/common.sh"
source "${_DIR}/lib/registry.sh"
source "${_DIR}/lib/guards.sh"
source "${_DIR}/lib/rebind.sh"
require_lib 1

# --- PURE: domain input resolution (DESIGN §8.1, the dots-signal table) --------
# Echoes the resolved FQDN and returns 0; on reject/ambiguous sets RESOLVE_REASON
# and returns 1 (reject) or 2 (outside-namespace, needs explicit choice).
RESOLVE_REASON=''
resolve_site_domain() {     # <input> <namespace>
    local input=$1 ns=$2
    RESOLVE_REASON=''
    if [ -n "$ns" ]; then
        if is_bare_label "$input"; then printf '%s.%s\n' "$input" "$ns"; return 0; fi
        if [ "$input" = "$ns" ] || [[ "$input" == *".${ns}" ]]; then printf '%s\n' "$input"; return 0; fi
        RESOLVE_REASON="'$input' is a full domain outside namespace '$ns' — confirm explicitly"
        return 2
    fi
    if is_bare_label "$input"; then
        RESOLVE_REASON="'$input' is not a valid domain. Set NAMESPACE in the blueprint record to use bare subdomains."
        return 1
    fi
    if is_valid_domain "$input"; then printf '%s\n' "$input"; return 0; fi
    RESOLVE_REASON="'$input' is not a valid domain"
    return 1
}

# --- PURE: creation source selection (DESIGN §8.1) ----------------------------
# Echoes "vanilla" or "clone:<blueprint-domain>"; rc 2 = multiple blueprints need --from.
select_create_source() {    # [--vanilla] [--from <domain>]
    local force_vanilla='' from=''
    while [ $# -gt 0 ]; do
        case "$1" in
            --vanilla) force_vanilla=1; shift ;;
            --from) from=$2; shift 2 ;;
            *) shift ;;
        esac
    done
    [ -n "$force_vanilla" ] && { echo vanilla; return 0; }
    [ -n "$from" ] && { echo "clone:${from}"; return 0; }
    local bps; bps="$(registry_list --type=blueprint)"
    local n; n="$(printf '%s' "$bps" | grep -c . )"
    case "$n" in
        0) echo vanilla; return 0 ;;
        1) echo "clone:${bps}"; return 0 ;;
        *) RESOLVE_REASON="multiple blueprints — pass --from <domain>"; return 2 ;;
    esac
}

# --- PURE-ish: credential generation (random; format is what's tested) ---------
_rand() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-8}"; }
generate_credentials() {
    NEW_DBNAME="site_$(_rand 8)"
    NEW_DBUSER="u_$(_rand 8)"
    NEW_DBPASS="$(LC_ALL=C tr -dc 'A-Za-z0-9._-' < /dev/urandom | head -c 24)"
    NEW_PREFIX="$(LC_ALL=C tr -dc 'a-z' < /dev/urandom | head -c 3)$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 4)_"
    NEW_ADMIN_USER="$(_rand 10)"
    NEW_ADMIN_ID="$(( (RANDOM % 9900) + 100 ))"
    NEW_ADMIN_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^&*' < /dev/urandom | head -c 16)"
    NEW_CACHE_SALT="$(_rand 16)"
}

# Clone a blueprint database into a new one with a rewritten table prefix. The
# prefix appears in table names (`wp_options`) and prefix-embedded option keys
# ('wp_user_roles') — a quote/backtick-anchored rewrite handles both safely.
clone_blueprint_database() {    # <src_db> <src_prefix> <dst_db> <dst_prefix>
    local src=$1 sp=$2 dst=$3 dp=$4 tmp rc
    mysql_root -e "CREATE DATABASE IF NOT EXISTS \`${dst}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;" || return 1
    # Dump to a file so mysqldump's exit is checked directly (a pipe would mask a
    # failed/missing source dump regardless of the caller's pipefail setting).
    tmp="$(mktemp)"
    if ! mysqldump_root "$src" > "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi
    sed "s/\`${sp}/\`${dp}/g; s/'${sp}/'${dp}/g" "$tmp" | mysql_root "$dst"; rc=$?
    rm -f "$tmp"
    return $rc
}

# --- nginx / SSL (real on the server; tests override these) -------------------

# Create the site's nginx config: clone the blueprint's config (sed the domain) or
# fall back to the no-caching template. Validates with `nginx -t` and rolls back.
setup_site_nginx() {    # <domain> <docroot> [src-config] [src-domain]
    local domain=$1 docroot=$2 src=${3:-} srcdom=${4:-}
    local conf="${NGINX_AVAILABLE}/${domain}.conf"
    if [ -n "$src" ] && [ -f "$src" ]; then
        sudo cp "$src" "$conf"
        sudo sed -i "s/${srcdom//./\\.}/${domain}/g" "$conf"
    elif [ -f "${NGINX_AVAILABLE}/template_no_caching.conf" ]; then
        sudo cp "${NGINX_AVAILABLE}/template_no_caching.conf" "$conf"
        sudo sed -i "s/_domain_name_/${domain}/g" "$conf"
    else
        warning "no nginx source/template for ${domain}"; return 1
    fi
    sudo ln -sf "$conf" "${NGINX_ENABLED}/${domain}"
    mkdir -p "${CACHE_ROOT}/${domain}"
    if sudo nginx -t >/dev/null 2>&1; then
        sudo systemctl reload nginx 2>/dev/null || sudo service nginx reload >/dev/null 2>&1
    else
        sudo rm -f "$conf" "${NGINX_ENABLED}/${domain}"
        warning "nginx config for ${domain} invalid — removed"; return 1
    fi
}

# Obtain a certificate. Wildcard namespace sites already share the parent cert
# (referenced by the cloned config), so they are a no-op.
setup_site_ssl() {  # <domain> <ssl-mode>
    case "${2:-}" in
        wildcard*|none) return 0 ;;
        *) command -v certbot >/dev/null 2>&1 || return 0
           sudo certbot --nginx -d "$1" -d "www.$1" --non-interactive --agree-tos \
               -m "${CERTBOT_EMAIL:-admin@example.com}" >/dev/null 2>&1 || warning "certbot failed for $1" ;;
    esac
}

# Clone-create orchestration. INTENT (the registry record) is written BEFORE any
# resource, so a crash at any step leaves a `creating` record for rollback/resume.
create_clone_site() {   # <domain> <blueprint-domain>
    local domain=$1 bp=$2
    registry_read "$bp" || { warning "blueprint not registered: $bp"; return 1; }
    local bp_db="${REG_DB_NAME}" bp_prefix="${REG_TABLE_PREFIX}" bp_root="${REG_DOC_ROOT}"
    generate_credentials
    local docroot="${WEB_ROOT}/${domain}"

    # 1. INTENT — before anything exists
    registry_clear
    REG_DOMAIN=$domain REG_TYPE=dev REG_PARENT=$bp REG_STATUS=creating REG_STATUS_SINCE="$(date +%s)"
    REG_CREATED="$(date +%F)" REG_PROTECTED=false
    REG_DB_NAME=$NEW_DBNAME REG_DB_USER=$NEW_DBUSER REG_DB_HOST=localhost
    REG_TABLE_PREFIX=$NEW_PREFIX REG_DOC_ROOT=$docroot
    REG_BACKUP_FREQ=weekly REG_SSL_MODE=wildcard REG_INDEXING=blocked
    registry_save "$domain"

    # 2. files (exclude wp-config) + 3. fresh wp-config (never a wrong-binding one)
    mkdir -p "$docroot"
    cp -r "$bp_root/." "$docroot/" 2>/dev/null || true
    rm -f "$docroot/wp-config.php"
    write_wpconfig "$docroot" "$NEW_DBNAME" "$NEW_DBUSER" "$NEW_DBPASS" localhost "$NEW_PREFIX" "$NEW_CACHE_SALT"

    # 4. database: clone (prefix rewrite) + create the site's own DB user
    clone_blueprint_database "$bp_db" "$bp_prefix" "$NEW_DBNAME" "$NEW_PREFIX" || return 1
    mysql_root -e "CREATE USER IF NOT EXISTS '${NEW_DBUSER}'@'localhost' IDENTIFIED BY '${NEW_DBPASS}'; GRANT ALL PRIVILEGES ON \`${NEW_DBNAME}\`.* TO '${NEW_DBUSER}'@'localhost'; FLUSH PRIVILEGES;" || return 1

    # 5-9. URL rebind (PHP, no wp-cli), user scrub (SQL), perms, assets, nginx, ssl
    rebind_urls "$docroot" "https://${bp}" "https://${domain}" || true
    scrub_users "$NEW_DBNAME" "$NEW_PREFIX" "$NEW_ADMIN_ID" "$NEW_ADMIN_USER" "$NEW_ADMIN_PASS" "${ADMIN_EMAIL:-admin@example.com}" || true
    regenerate_assets "$docroot" || true
    fix_permissions "$docroot" || true
    setup_site_nginx "$domain" "$docroot" "${NGINX_AVAILABLE}/${bp}.conf" "$bp" || true
    setup_site_ssl "$domain" "wildcard" || true

    # 10. done — flip to active (stamps STATUS_SINCE)
    registry_set "$domain" STATUS active
    log_operation "create-site" "$domain (clone of $bp)"
    return 0
}

main() {
    case "${1:-}" in -h|--help) show_help "${BASH_SOURCE[0]}"; exit 0 ;; esac
    local input="${1:-}"
    [ -n "$input" ] || error_exit "Usage: $0 <name-or-domain> [--vanilla] [--from <blueprint>]"
    acquire_lifecycle_lock
    local src; src="$(select_create_source "${@:2}")" || error_exit "$RESOLVE_REASON"
    case "$src" in
        vanilla) error_exit "vanilla creation downloads WordPress (L3) — validated on the server." ;;
        clone:*) local bp="${src#clone:}"
                 local ns; ns="$(registry_field "$bp" NAMESPACE)"
                 local domain; domain="$(resolve_site_domain "$input" "$ns")" || error_exit "$RESOLVE_REASON"
                 registry_exists "$domain" && error_exit "already registered: $domain"
                 echo "Creating ${domain} from blueprint ${bp}..."
                 create_clone_site "$domain" "$bp" && success "Created ${domain}" ;;
    esac
}

[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"
