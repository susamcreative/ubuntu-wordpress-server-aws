#!/usr/bin/env bash
#
# promote-site.sh — dev → production promotion (Task P3.3, DESIGN §8.2)
#
# A rename-in-place: the dev site becomes the production site; the dev domain
# becomes a 301 redirect. The certificate is obtained FIRST so a DNS/cert failure
# leaves the dev site completely untouched. The registry handover writes the new
# production record BEFORE deleting the dev record (a crash between them is resolved
# by health-check's resolve_promotion_dupes).
#
# USAGE:  ./apps/promote-site.sh <dev-domain> <new-domain>
#
set -uo pipefail
SCRIPT_NAME="promote-site.sh"

_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${_DIR}/lib/common.sh"
source "${_DIR}/lib/registry.sh"
source "${_DIR}/lib/guards.sh"
source "${_DIR}/lib/rebind.sh"
require_lib 1

# --- nginx / SSL (real on the server; tests override) -------------------------

# Obtain the production certificate. Idempotent: if one already exists for the
# domain, succeed without calling certbot.
promote_obtain_certificate() {  # <new-domain>
    local d=$1
    [ -d "/etc/letsencrypt/live/${d}" ] && return 0
    command -v certbot >/dev/null 2>&1 || { warning "certbot not available"; return 1; }
    sudo certbot certonly --nginx -d "$d" -d "www.$d" --non-interactive --agree-tos \
        -m "${CERTBOT_EMAIL:-admin@example.com}" >/dev/null 2>&1
}

# Production nginx config (own cert + caching template). Validates and rolls back.
promote_setup_nginx() {     # <new-domain> <docroot>
    local d=$1                                 # split: `local d=$1 conf=${d}` expands ${d} before d is set (set -u)
    local conf="${NGINX_AVAILABLE}/${d}.conf"
    sudo cp "${NGINX_AVAILABLE}/template.conf" "$conf"
    sudo sed -i "s/_domain_name_/${d}/g" "$conf"
    sudo ln -sf "$conf" "${NGINX_ENABLED}/${d}"
    if sudo nginx -t >/dev/null 2>&1; then
        sudo systemctl reload nginx 2>/dev/null || sudo service nginx reload >/dev/null 2>&1
    else
        sudo rm -f "$conf" "${NGINX_ENABLED}/${d}"; warning "production nginx config invalid — removed"; return 1
    fi
}

promote_remove_dev_nginx() { rm -f "${NGINX_AVAILABLE}/$1.conf" "${NGINX_ENABLED}/$1"; }

# Lazily create the namespace config so redirects.d/*.conf is actually included by
# nginx (DESIGN §10.2). Idempotent; never clobbers an existing one.
ensure_namespace_config() {     # <namespace>
    local ns=$1
    local nsconf="${NGINX_AVAILABLE}/${ns}.conf"
    [ -f "$nsconf" ] && return 0
    cat > "$nsconf" <<NGINX
# Namespace ${ns} — promotion redirects + catch-all (created by promote-site.sh)
include ${NGINX_REDIRECTS}/*.conf;
server {
    listen 443 ssl;
    http2 on;
    server_name *.${ns};
    ssl_certificate     /etc/letsencrypt/live/${ns}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${ns}/privkey.pem;
    return 444;
}
NGINX
    ln -sf "$nsconf" "${NGINX_ENABLED}/${ns}"
}

promote_site() {    # <dev-domain> <new-domain>
    local dev=$1 new=$2
    registry_read "$dev" || { warning "not registered: $dev"; return 1; }
    [ "${REG_TYPE-}" = dev ]    || { warning "$dev is TYPE=${REG_TYPE-}, not dev"; return 1; }
    [ "${REG_STATUS-}" = active ] || { warning "$dev is not active (STATUS=${REG_STATUS-})"; return 1; }

    local db="$REG_DB_NAME" dbuser="$REG_DB_USER" dbhost="$REG_DB_HOST" prefix="$REG_TABLE_PREFIX"
    local dev_root="$REG_DOC_ROOT" ns="${dev#*.}" new_root="${WEB_ROOT}/${new}"

    # Certificate FIRST — if it fails, nothing has changed yet.
    if ! promote_obtain_certificate "$new"; then
        warning "certificate step failed (DNS not pointed?) — dev site untouched"; return 1
    fi

    registry_set "$dev" STATUS promoting

    rebind_urls "$dev_root" "https://${dev}" "https://${new}" || true

    # rename doc root + cache, fresh per-site cache salt
    mkdir -p "$(dirname "$new_root")"
    mv "$dev_root" "$new_root" 2>/dev/null || true
    [ -d "${CACHE_ROOT}/${dev}" ] && mv "${CACHE_ROOT}/${dev}" "${CACHE_ROOT}/${new}" 2>/dev/null || true
    set_wpconfig_value "$new_root" WP_CACHE_KEY_SALT "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"

    regenerate_assets "$new_root" || true
    promote_setup_nginx "$new" "$new_root" || true
    promote_remove_dev_nginx "$dev" || true

    # redirect dev → new (reuses the namespace wildcard cert), then reload
    # (/etc/nginx is owned by the app user per Install LEMP, so no sudo needed here)
    mkdir -p "$NGINX_REDIRECTS"
    ensure_namespace_config "$ns"          # so redirects.d/*.conf is included by nginx
    generate_redirect_config "$dev" "$new" "$ns" > "${NGINX_REDIRECTS}/${dev}.conf"
    reload_nginx || true

    # registry handover: write NEW first (crash-window safe), then delete OLD
    registry_clear
    REG_DOMAIN=$new REG_TYPE=production REG_PARENT="" REG_STATUS=active REG_STATUS_SINCE="$(date +%s)"
    REG_CREATED="$(date +%F)" REG_PROTECTED=false
    REG_DB_NAME=$db REG_DB_USER=$dbuser REG_DB_HOST=$dbhost REG_TABLE_PREFIX=$prefix REG_DOC_ROOT=$new_root
    REG_BACKUP_FREQ=daily REG_SSL_MODE=own REG_INDEXING=allowed
    REG_PROMOTED_FROM=$dev REG_PROMOTED_DATE="$(date +%F)" REG_REDIRECT_FROM=$dev
    registry_save "$new"
    registry_delete "$dev"

    rm -f "${LOGS_ROOT}/${dev}.access.log" "${LOGS_ROOT}/${dev}.error.log"
    log_operation "promote-site" "$dev → $new"
    return 0
}

main() {
    case "${1:-}" in -h|--help) show_help "${BASH_SOURCE[0]}"; exit 0 ;; esac
    [ $# -eq 2 ] || error_exit "Usage: $0 <dev-domain> <new-domain>"
    local dev=$1 new=$2
    registry_exists "$dev" || error_exit "'$dev' is not registered."
    registry_exists "$new" && error_exit "'$new' already exists."
    echo "Promoting ${dev} → ${new}"
    acquire_lifecycle_lock
    promote_site "$dev" "$new" && success "Promoted ${dev} → ${new} (dev domain now redirects)"
}

[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"
