#!/bin/bash
#
# List WordPress Sites - Display WordPress site inventory
#
# USAGE:
#   ./apps/list-sites.sh                    # Compact table view
#   ./apps/list-sites.sh --detailed         # Detailed view for all sites
#   ./apps/list-sites.sh example.com        # Detailed view for specific site
#
# DESCRIPTION:
#   Lists all WordPress sites on the server with key metrics including
#   status, storage, SSL, backups, and error counts.
#
# REQUIREMENTS:
#   - WordPress sites in ~/www/
#   - Access to nginx logs in ~/logs/
#   - Access to backup files in ~/backups/
#   - SSL certificates in /etc/letsencrypt/live/
#
# OUTPUT FORMATS:
#   Compact:  Single-line table with essential metrics
#   Detailed: Full report with sections for each site

set -euo pipefail

#=============================================================================
# CONFIGURATION
#=============================================================================

USER=$(whoami)
WEB_ROOT="/home/${USER}/www"
BACKUP_ROOT="/home/${USER}/backups"
LOGS_ROOT="/home/${USER}/logs"

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: Run this script as the app user, not root. It uses sudo internally where needed." >&2
    exit 1
fi

#=============================================================================
# DATA COLLECTION FUNCTIONS
#=============================================================================

mysql_with_credentials() {
    local dbuser=$1
    local dbpass=$2
    shift 2

    mysql --defaults-extra-file=<(printf "[client]\nuser=%s\npassword=%s\n" "$dbuser" "$dbpass") "$@"
}

get_http_status() {
    local domain=$1
    local protocol="https"

    # Try HTTPS first
    local status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "https://${domain}" 2>/dev/null || echo "000")

    # If HTTPS fails, try HTTP
    if [ "$status" = "000" ] || [ "$status" = "000" ]; then
        status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "http://${domain}" 2>/dev/null || echo "DOWN")
        protocol="http"
    fi

    if [ "$status" = "200" ] || [ "$status" = "301" ] || [ "$status" = "302" ]; then
        echo "UP"
    else
        echo "DOWN"
    fi
}

get_disk_usage() {
    local site_path=$1
    du -sh "$site_path" 2>/dev/null | cut -f1 || echo "N/A"
}

get_db_size() {
    local dbname=$1
    local dbuser=$2
    local dbpass=$3

    mysql_with_credentials "$dbuser" "$dbpass" -sN -e "
        SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 0)
        FROM information_schema.TABLES
        WHERE table_schema = '$dbname';
    " 2>/dev/null || echo "0"
}

get_wp_version() {
    local site_path=$1
    local version_file="${site_path}/wp-includes/version.php"

    if [ -f "$version_file" ]; then
        grep "wp_version =" "$version_file" | cut -d "'" -f 2
    else
        echo "N/A"
    fi
}

get_ssl_days() {
    local domain=$1
    local cert_file=""

    # Try to find cert path from nginx config
    local nginx_conf="/etc/nginx/sites-available/${domain}.conf"
    if [ -f "$nginx_conf" ]; then
        cert_file=$(grep "ssl_certificate " "$nginx_conf" | grep -v "#" | head -1 | awk '{print $2}' | tr -d ';' | sed 's/fullchain\.pem/cert.pem/')
    fi

    # Fallback to standard path
    if [ -z "$cert_file" ] || ! sudo test -f "$cert_file" 2>/dev/null; then
        cert_file="/etc/letsencrypt/live/${domain}/cert.pem"
    fi

    if sudo test -f "$cert_file" 2>/dev/null; then
        local expiry_date=$(sudo openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
        local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
        local now_epoch=$(date +%s)
        local days_left=$(( ($expiry_epoch - $now_epoch) / 86400 ))
        echo "${days_left}d"
    else
        echo "N/A"
    fi
}

get_backup_frequency() {
    # Registry-driven (BACKUP_FREQ in the site's record), not the old SITES array.
    local domain=$1
    local rec="/home/${USER}/apps/sites.d/${domain}.conf"
    local frequency=""
    [ -f "$rec" ] && frequency=$(grep '^BACKUP_FREQ=' "$rec" 2>/dev/null | head -1 | cut -d'"' -f2)
    if [ -n "$frequency" ] && [ "$frequency" != none ]; then
        echo "${frequency^}"
    else
        echo "None"
    fi
}

get_last_backup() {
    local domain=$1
    local backup_dir="${BACKUP_ROOT}/${domain}"

    if [ ! -d "$backup_dir" ]; then
        echo "N/A"
        return
    fi

    local last_backup=$(find "$backup_dir" -name "*.tar.gz" -type f -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1)

    if [ -z "$last_backup" ]; then
        echo "N/A"
        return
    fi

    local backup_epoch=$(echo "$last_backup" | cut -d' ' -f1 | cut -d. -f1)
    local now_epoch=$(date +%s)
    local days_ago=$(( ($now_epoch - $backup_epoch) / 86400 ))
    echo "${days_ago}d"
}

get_error_count() {
    local domain=$1
    local error_log="${LOGS_ROOT}/${domain}.error.log"

    if [ ! -f "$error_log" ]; then
        echo "0"
        return
    fi

    # Count errors from last 24 hours
    local yesterday=$(date -d'now-24 hours' '+%Y/%m/%d')
    local count=$(awk -v date="$yesterday" '$1 >= date' "$error_log" 2>/dev/null | wc -l)
    echo "$count"
}

get_db_credentials() {
    local site_path=$1
    local wp_config="${site_path}/wp-config.php"

    if [ ! -f "$wp_config" ]; then
        echo "N/A N/A N/A"
        return
    fi

    local dbname=$(grep "DB_NAME" "$wp_config" | cut -d "'" -f 4)
    local dbuser=$(grep "DB_USER" "$wp_config" | cut -d "'" -f 4)
    local dbpass=$(grep "DB_PASSWORD" "$wp_config" | cut -d "'" -f 4)

    echo "$dbname $dbuser $dbpass"
}

#=============================================================================
# DETAILED VIEW FUNCTIONS
#=============================================================================

get_requests_today() {
    local domain=$1
    local access_log="${LOGS_ROOT}/${domain}.access.log"

    if [ ! -f "$access_log" ]; then
        echo "0"
        return
    fi

    local today=$(date '+%d/%b/%Y')
    grep "$today" "$access_log" 2>/dev/null | wc -l
}

get_redis_status() {
    if command -v redis-cli &>/dev/null; then
        if redis-cli ping 2>/dev/null | grep -q "PONG"; then
            echo "Connected"
        else
            echo "Not responding"
        fi
    else
        echo "Not installed"
    fi
}

get_nginx_cache_status() {
    local domain=$1
    local nginx_conf="/etc/nginx/sites-available/${domain}.conf"

    if [ -f "$nginx_conf" ]; then
        if grep -q "fastcgi_cache" "$nginx_conf"; then
            echo "Enabled"
        else
            echo "Disabled"
        fi
    else
        echo "N/A"
    fi
}

get_db_table_count() {
    local dbname=$1
    local dbuser=$2
    local dbpass=$3

    mysql_with_credentials "$dbuser" "$dbpass" -sN -e "
        SELECT COUNT(*)
        FROM information_schema.TABLES
        WHERE table_schema = '$dbname';
    " 2>/dev/null || echo "0"
}

get_plugin_count() {
    local site_path=$1
    local plugin_dir="${site_path}/wp-content/plugins"

    if [ -d "$plugin_dir" ]; then
        find "$plugin_dir" -maxdepth 1 -type d ! -name plugins | wc -l
    else
        echo "0"
    fi
}

get_theme_count() {
    local site_path=$1
    local theme_dir="${site_path}/wp-content/themes"

    if [ -d "$theme_dir" ]; then
        find "$theme_dir" -maxdepth 1 -type d ! -name themes | wc -l
    else
        echo "0"
    fi
}

get_php_version() {
    local domain=$1
    local nginx_conf="/etc/nginx/sites-available/${domain}.conf"

    if [ -f "$nginx_conf" ]; then
        local socket=$(grep "fastcgi_pass" "$nginx_conf" | grep -oP "php\d+\.\d+" | head -1)
        if [ -n "$socket" ]; then
            echo "$socket" | sed 's/php//'
        else
            echo "N/A"
        fi
    else
        php -v 2>/dev/null | head -1 | cut -d' ' -f2 | cut -d'-' -f1 || echo "N/A"
    fi
}

get_ssl_expiry_date() {
    local domain=$1
    local cert_file=""

    # Try to find cert path from nginx config
    local nginx_conf="/etc/nginx/sites-available/${domain}.conf"
    if [ -f "$nginx_conf" ]; then
        cert_file=$(grep "ssl_certificate " "$nginx_conf" | grep -v "#" | head -1 | awk '{print $2}' | tr -d ';' | sed 's/fullchain\.pem/cert.pem/')
    fi

    # Fallback to standard path
    if [ -z "$cert_file" ] || ! sudo test -f "$cert_file" 2>/dev/null; then
        cert_file="/etc/letsencrypt/live/${domain}/cert.pem"
    fi

    if sudo test -f "$cert_file" 2>/dev/null; then
        sudo openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2 | xargs -I{} date -d "{}" '+%Y-%m-%d' 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

check_xmlrpc() {
    local site_path=$1

    if [ -f "${site_path}/xmlrpc.php" ]; then
        echo "Present"
    else
        echo "Not found"
    fi
}

check_admin_user() {
    local dbname=$1
    local dbuser=$2
    local dbpass=$3
    local table_prefix=$(get_table_prefix "$site_path")

    local count=$(mysql_with_credentials "$dbuser" "$dbpass" -sN -e "
        SELECT COUNT(*)
        FROM ${dbname}.${table_prefix}users
        WHERE user_login = 'admin';
    " 2>/dev/null || echo "0")

    if [ "$count" -gt 0 ]; then
        echo "Found"
    else
        echo "Not found"
    fi
}

get_table_prefix() {
    local site_path=$1
    local wp_config="${site_path}/wp-config.php"

    if [ -f "$wp_config" ]; then
        grep "table_prefix" "$wp_config" | cut -d "'" -f 2 || echo "wp_"
    else
        echo "wp_"
    fi
}

get_backup_count() {
    local domain=$1
    local backup_dir="${BACKUP_ROOT}/${domain}"

    if [ -d "$backup_dir" ]; then
        find "$backup_dir" -name "*.tar.gz" -type f 2>/dev/null | wc -l
    else
        echo "0"
    fi
}

get_backup_size() {
    local domain=$1
    local backup_dir="${BACKUP_ROOT}/${domain}"

    if [ -d "$backup_dir" ]; then
        du -sh "$backup_dir" 2>/dev/null | cut -f1 || echo "0"
    else
        echo "0"
    fi
}

get_404_count() {
    local domain=$1
    local access_log="${LOGS_ROOT}/${domain}.access.log"

    if [ ! -f "$access_log" ]; then
        echo "0"
        return
    fi

    local today=$(date '+%d/%b/%Y')
    grep "$today" "$access_log" 2>/dev/null | grep " 404 " | wc -l
}

get_5xx_count() {
    local domain=$1
    local access_log="${LOGS_ROOT}/${domain}.access.log"

    if [ ! -f "$access_log" ]; then
        echo "0"
        return
    fi

    local today=$(date '+%d/%b/%Y')
    grep "$today" "$access_log" 2>/dev/null | grep -E " 50[0-9] " | wc -l
}

#=============================================================================
# DISPLAY FUNCTIONS
#=============================================================================

display_compact() {
    local sites=()

    # Collect all WordPress sites
    for site_dir in "$WEB_ROOT"/*/ ; do
        if [ -d "$site_dir" ] && [ -f "${site_dir}/wp-config.php" ]; then
            local domain=$(basename "$site_dir")
            sites+=("$domain")
        fi
    done

    if [ ${#sites[@]} -eq 0 ]; then
        echo "No WordPress sites found in $WEB_ROOT"
        return
    fi

    # Header
    printf "%-25s %-6s %-12s %-8s %-6s %-12s %-7s\n" \
        "Site" "Status" "Storage" "WP" "SSL" "Backup" "Errors"
    printf "%-25s %-6s %-12s %-8s %-6s %-12s %-7s\n" \
        "-------------------------" "------" "------------" "--------" "------" "------------" "-------"

    # Data rows
    for domain in "${sites[@]}"; do
        local site_path="${WEB_ROOT}/${domain}"

        # Get basic info
        local status=$(get_http_status "$domain")
        local disk=$(get_disk_usage "$site_path")
        local wp_ver=$(get_wp_version "$site_path")
        local ssl=$(get_ssl_days "$domain")
        local backup_freq=$(get_backup_frequency "$domain")
        local backup_last=$(get_last_backup "$domain")
        local errors=$(get_error_count "$domain")

        # Get DB credentials and size
        read dbname dbuser dbpass <<< $(get_db_credentials "$site_path")
        local db_size="0"
        if [ "$dbname" != "N/A" ]; then
            db_size=$(get_db_size "$dbname" "$dbuser" "$dbpass")
        fi

        local storage="${disk}/${db_size}M"
        local backup="${backup_freq}/${backup_last}"

        printf "%-25s %-6s %-12s %-8s %-6s %-12s %-7s\n" \
            "$domain" "$status" "$storage" "$wp_ver" "$ssl" "$backup" "$errors"
    done

    echo ""
    echo "Total: ${#sites[@]} sites"
}

display_detailed() {
    local target_domain=$1
    local sites=()

    # Collect sites to display
    if [ -n "$target_domain" ]; then
        if [ -d "${WEB_ROOT}/${target_domain}" ] && [ -f "${WEB_ROOT}/${target_domain}/wp-config.php" ]; then
            sites=("$target_domain")
        else
            echo "Site not found: $target_domain"
            return 1
        fi
    else
        for site_dir in "$WEB_ROOT"/*/ ; do
            if [ -d "$site_dir" ] && [ -f "${site_dir}/wp-config.php" ]; then
                local domain=$(basename "$site_dir")
                sites+=("$domain")
            fi
        done
    fi

    if [ ${#sites[@]} -eq 0 ]; then
        echo "No WordPress sites found"
        return
    fi

    # Display detailed report for each site
    for domain in "${sites[@]}"; do
        local site_path="${WEB_ROOT}/${domain}"

        # Get all data
        local status=$(get_http_status "$domain")
        local requests=$(get_requests_today "$domain")
        local redis=$(get_redis_status)
        local cache=$(get_nginx_cache_status "$domain")

        local disk=$(get_disk_usage "$site_path")
        read dbname dbuser dbpass <<< $(get_db_credentials "$site_path")
        local db_size=$(get_db_size "$dbname" "$dbuser" "$dbpass")
        local db_tables=$(get_db_table_count "$dbname" "$dbuser" "$dbpass")
        local plugins=$(get_plugin_count "$site_path")
        local themes=$(get_theme_count "$site_path")

        local wp_ver=$(get_wp_version "$site_path")
        local php_ver=$(get_php_version "$domain")

        local ssl_days=$(get_ssl_days "$domain")
        local ssl_date=$(get_ssl_expiry_date "$domain")
        local xmlrpc=$(check_xmlrpc "$site_path")
        local admin=$(check_admin_user "$dbname" "$dbuser" "$dbpass")

        local backup_freq=$(get_backup_frequency "$domain")
        local backup_last=$(get_last_backup "$domain")
        local backup_count=$(get_backup_count "$domain")
        local backup_size=$(get_backup_size "$domain")

        local nginx_errors=$(get_error_count "$domain")
        local errors_404=$(get_404_count "$domain")
        local errors_5xx=$(get_5xx_count "$domain")

        # Determine status symbols
        local status_symbol="[OK]"
        if [ "$status" = "DOWN" ]; then
            status_symbol="[CRITICAL]"
        fi

        local ssl_symbol=""
        if [ "$ssl_days" != "N/A" ]; then
            local days_num=$(echo "$ssl_days" | sed 's/d//')
            if [ "$days_num" -lt 7 ]; then
                ssl_symbol="[WARNING]"
            else
                ssl_symbol="✓"
            fi
        fi

        local xmlrpc_symbol=""
        if [ "$xmlrpc" = "Present" ]; then
            xmlrpc_symbol="[WARNING]"
        else
            xmlrpc_symbol="✓"
        fi

        local admin_symbol=""
        if [ "$admin" = "Found" ]; then
            admin_symbol="[WARNING]"
        else
            admin_symbol="✓"
        fi

        local error_symbol="✓"
        if [ "$nginx_errors" -gt 50 ]; then
            error_symbol="[CRITICAL]"
        elif [ "$nginx_errors" -gt 10 ]; then
            error_symbol="[WARNING]"
        fi

        # Display report
        echo "========================================"
        echo "WordPress Site Report: $domain"
        echo "========================================"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        echo "[SITE STATUS] $status_symbol"
        echo "  HTTP Response:      $status"
        echo "  Site Reachable:     $([ "$status" = "UP" ] && echo "Yes" || echo "No")"
        echo "  Daily Requests:     $requests"
        echo ""

        echo "[WORDPRESS]"
        echo "  Version:            $wp_ver"
        echo "  PHP Version:        $php_ver"
        echo "  Database Size:      ${db_size}MB ($db_tables tables)"
        echo "  Disk Usage:         $disk"
        echo "  Plugins:            $plugins installed"
        echo "  Themes:             $themes installed"
        echo ""

        echo "[SECURITY] $xmlrpc_symbol"
        echo "  SSL Certificate:    $([ "$ssl_days" != "N/A" ] && echo "Valid" || echo "Not found") $ssl_symbol"
        echo "  Days Until Expiry:  $ssl_days"
        echo "  Expiration Date:    $ssl_date"
        echo "  xmlrpc.php:         $xmlrpc $xmlrpc_symbol"
        echo "  Admin User:         $admin $admin_symbol"
        echo ""

        echo "[BACKUPS]"
        echo "  Schedule:           $backup_freq"
        echo "  Last Backup:        $backup_last ago"
        echo "  Total Backups:      $backup_count archives"
        echo "  Storage Used:       $backup_size"
        echo ""

        echo "[PERFORMANCE]"
        echo "  Redis Cache:        $redis"
        echo "  Nginx Cache:        $cache"
        echo ""

        echo "[ACTIVITY - LAST 24H] $error_symbol"
        echo "  Nginx Errors:       $nginx_errors"
        echo "  404 Errors:         $errors_404"
        echo "  5xx Errors:         $errors_5xx"
        echo ""

        echo "========================================"
        echo ""
    done
}

#=============================================================================
# MAIN
#=============================================================================

main() {
    case "${1:-}" in -h|--help)
        awk 'NR==1&&/^#!/{next} /^#/{sub(/^#[[:space:]]?/,"");print;next}{exit}' "$0"; exit 0 ;;
    esac
    local mode="compact"
    local target_site=""

    # Parse arguments
    if [ $# -gt 0 ]; then
        if [ "$1" = "--detailed" ]; then
            mode="detailed"
        else
            mode="detailed"
            target_site="$1"
        fi
    fi

    if [ "$mode" = "compact" ]; then
        display_compact
    else
        display_detailed "$target_site"
    fi
}

[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"
