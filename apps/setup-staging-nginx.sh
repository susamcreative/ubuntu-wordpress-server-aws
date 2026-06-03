#!/usr/bin/env bash
#
# setup-staging-nginx.sh — adopt + verify a plugin-created staging site (Task P3.4,
# DESIGN §8.4)
#
# Staging sites are created by cloning plugins (WP Staging, Duplicator, WP Time
# Capsule, …). This ADOPTS one into the registry — but VERIFIES it first: a staging
# wp-config that still points at an already-registered (live) database is a broken
# clone and is HARD-REJECTED (the §2.1 incident, caught at adoption rather than
# detonating at removal). Then it configures nginx (no caching, search engines
# blocked).
#
# USAGE:  ./apps/setup-staging-nginx.sh <staging-domain> [<docroot>]
#         (docroot defaults to ~/www/<parent>/staging, .../wp-content/staging, or
#          ~/www/<staging-domain>)
#
set -uo pipefail
SCRIPT_NAME="setup-staging-nginx.sh"

_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${_DIR}/lib/common.sh"
source "${_DIR}/lib/registry.sh"
source "${_DIR}/lib/guards.sh"
require_lib 1

# nginx config for a staging site (no-caching template, search engines blocked).
setup_staging_nginx_config() {  # <staging-domain> <docroot>
    local sdom=$1 conf="${NGINX_AVAILABLE}/${sdom}.conf"
    cp "${NGINX_AVAILABLE}/template_no_caching.conf" "$conf"
    sed -i "s/_domain_name_/${sdom}/g" "$conf"
    # block search engines on the staging server block
    sed -i "/server_name ${sdom//./\\.};/a\\    add_header X-Robots-Tag \"noindex, nofollow\" always;" "$conf"
    ln -sf "$conf" "${NGINX_ENABLED}/${sdom}"
    if sudo nginx -t >/dev/null 2>&1; then
        sudo systemctl reload nginx 2>/dev/null || sudo service nginx reload >/dev/null 2>&1
    else
        rm -f "$conf" "${NGINX_ENABLED}/${sdom}"; warning "staging nginx config invalid — removed"; return 1
    fi
}

# Verify (gate) then register + configure. Reads WPC_* via can_adopt_staging.
adopt_staging() {       # <staging-domain> <docroot>
    local sdom=$1 docroot=$2
    can_adopt_staging "$sdom" "$docroot" || { warning "$GUARD_REASON"; return 1; }
    local parent="${sdom#staging.}"
    registry_clear
    REG_DOMAIN=$sdom REG_TYPE=staging REG_PARENT=$parent REG_STATUS=active REG_STATUS_SINCE="$(date +%s)"
    REG_CREATED="$(date +%F)" REG_PROTECTED=false
    REG_DB_NAME=$WPC_DB_NAME REG_DB_USER=$WPC_DB_USER REG_DB_HOST=$WPC_DB_HOST
    REG_TABLE_PREFIX=$WPC_TABLE_PREFIX REG_DOC_ROOT=$docroot
    REG_BACKUP_FREQ=none REG_SSL_MODE=wildcard REG_INDEXING=blocked
    registry_save "$sdom"
    setup_staging_nginx_config "$sdom" "$docroot" || true
    log_operation "adopt-staging" "$sdom"
    success "Adopted staging site ${sdom}"
}

discover_docroot() {    # <staging-domain>
    local sdom=$1 parent="${sdom#staging.}" c
    for c in "${WEB_ROOT}/${parent}/staging" "${WEB_ROOT}/${parent}/wp-content/staging" "${WEB_ROOT}/${sdom}"; do
        [ -f "${c}/wp-config.php" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

main() {
    case "${1:-}" in -h|--help) show_help "${BASH_SOURCE[0]}"; exit 0 ;; esac
    local sdom="${1:-}" docroot="${2:-}"
    [ -n "$sdom" ] || error_exit "Usage: $0 <staging-domain> [<docroot>]"
    case "$sdom" in staging.*) ;; *) error_exit "staging domains must use the staging.<parent> convention" ;; esac
    [ -n "$docroot" ] || docroot="$(discover_docroot "$sdom")" || error_exit "no staging install found for ${sdom}"
    registry_exists "$sdom" && error_exit "'$sdom' is already registered."
    acquire_lifecycle_lock
    adopt_staging "$sdom" "$docroot"
}

[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"
