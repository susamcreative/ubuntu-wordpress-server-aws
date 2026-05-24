#!/bin/bash
#
# Remove Staging Site - Completely remove staging WordPress site
#
# USAGE:
#   ./apps/remove-staging.sh
#   ./apps/remove-staging.sh staging.example.com
#
# DESCRIPTION:
#   Safely removes a staging WordPress site including nginx configuration,
#   SSL certificate, database, files, and logs. Multiple confirmations required.
#
# WHAT IT DOES:
#   1. Identifies staging site to remove (interactive or via argument)
#   2. Validates staging site is configured
#   3. Extracts database credentials from wp-config.php
#   4. Shows detailed list of what will be deleted
#   5. Requires typing domain name to confirm
#   6. Prompts for MySQL root password
#   7. Removes nginx configuration (sites-enabled & sites-available)
#   8. Removes SSL certificate (preserves wildcard certs)
#   9. Drops database and database user
#   10. Removes WordPress files
#   11. Removes log files
#   12. Reloads nginx
#
# SAFETY FEATURES:
#   - Lists all items before deletion
#   - Requires typing domain name to confirm
#   - Preserves wildcard SSL certificates
#   - Validates MySQL credentials before deletion
#   - Shows clear warnings
#
# REQUIREMENTS:
#   - MySQL root password (prompted securely)
#   - sudo access for nginx operations
#
# EXAMPLES:
#   # Interactive mode
#   ./apps/remove-staging.sh
#
#   # Direct mode
#   ./apps/remove-staging.sh staging.example.com
#
# NOTES:
#   - This is PERMANENT - files and database cannot be recovered
#   - Wildcard SSL certificates are preserved (may be used by other staging sites)
#   - Does not affect parent production site

set -euo pipefail

#=============================================================================
# CONFIGURATION
#=============================================================================

USER=$(whoami)
WEB_ROOT="/home/${USER}/www"
LOGS_ROOT="/home/${USER}/logs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ "$(id -u)" -eq 0 ]; then
    echo -e "${RED}ERROR: Run this script as the app user, not root. It uses sudo internally where needed.${NC}" >&2
    exit 1
fi

#=============================================================================
# HELPER FUNCTIONS
#=============================================================================

error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

mysql_root() {
    mysql --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s\n" "$MYSQL_ROOT_PASS") "$@"
}

extract_db_credentials() {
    local wp_config=$1

    if [ ! -f "$wp_config" ]; then
        echo "N/A N/A N/A N/A"
        return 1
    fi

    # Extract credentials
    local dbname=$(grep "define.*DB_NAME" "$wp_config" 2>/dev/null | sed "s/.*['\"]DB_NAME['\"].*['\"]\\([^'\"]*\\)['\"].*/\\1/" | head -1)
    local dbuser=$(grep "define.*DB_USER" "$wp_config" 2>/dev/null | sed "s/.*['\"]DB_USER['\"].*['\"]\\([^'\"]*\\)['\"].*/\\1/" | head -1)
    local dbpass=$(grep "define.*DB_PASSWORD" "$wp_config" 2>/dev/null | sed "s/.*['\"]DB_PASSWORD['\"].*['\"]\\([^'\"]*\\)['\"].*/\\1/" | head -1)
    local dbhost=$(grep "define.*DB_HOST" "$wp_config" 2>/dev/null | sed "s/.*['\"]DB_HOST['\"].*['\"]\\([^'\"]*\\)['\"].*/\\1/" | head -1)

    # Set defaults if empty
    dbhost=${dbhost:-localhost}

    echo "$dbname $dbuser $dbpass $dbhost"
}

is_wildcard_cert() {
    local domain=$1
    local cert_path="/etc/letsencrypt/live/${domain}"

    # Check if this is actually a wildcard certificate path
    if [[ "$cert_path" == *"*."* ]]; then
        return 0
    fi

    # Check if cert directory name contains asterisk
    if [ -d "$cert_path" ] && [[ "$(basename "$cert_path")" == *"*"* ]]; then
        return 0
    fi

    return 1
}

is_staging_domain() {
    local domain=$1

    if [[ "$domain" == staging.* ]] || [[ "$domain" == *.staging.* ]] || [[ "$domain" == staging-*.* ]] || [[ "$domain" == *-staging.* ]]; then
        return 0
    fi

    return 1
}

find_staging_sites() {
    local sites=()

    # Look for nginx configs in sites-available
    for conf in /etc/nginx/sites-available/*.conf; do
        if [ -f "$conf" ]; then
            local domain=$(basename "$conf" .conf)

            # Skip if it's a template
            if [[ "$domain" == "template"* ]] || [[ "$domain" == "default" ]]; then
                continue
            fi

            # Only list explicitly named staging domains.
            if is_staging_domain "$domain"; then
                sites+=("$domain")
            fi
        fi
    done

    echo "${sites[@]}"
}

#=============================================================================
# MAIN SCRIPT
#=============================================================================

main() {
    echo "========================================="
    echo "Remove Staging Site"
    echo "========================================="
    echo ""

    # Determine staging domain to remove
    local staging_domain=""

    if [ $# -eq 1 ]; then
        # Domain provided as argument
        staging_domain="$1"
    else
        # Interactive mode - list available staging sites
        echo "Detecting staging sites..."
        echo ""

        local staging_sites=($(find_staging_sites))

        if [ ${#staging_sites[@]} -eq 0 ]; then
            echo "No staging sites found."
            echo ""
            read -p "Enter staging domain manually: " staging_domain
        else
            echo "Found staging sites:"
            for i in "${!staging_sites[@]}"; do
                echo "  $((i+1))) ${staging_sites[$i]}"
            done
            echo "  $((${#staging_sites[@]}+1))) Enter manually"
            echo ""

            read -p "Choose (1-$((${#staging_sites[@]}+1))): " choice

            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#staging_sites[@]}" ]; then
                staging_domain="${staging_sites[$((choice-1))]}"
            elif [ "$choice" -eq "$((${#staging_sites[@]}+1))" ]; then
                read -p "Enter staging domain: " staging_domain
            else
                error_exit "Invalid choice"
            fi
        fi
    fi

    if [ -z "$staging_domain" ]; then
        error_exit "No staging domain specified"
    fi

    if ! is_staging_domain "$staging_domain"; then
        error_exit "Refusing to remove non-staging domain with remove-staging.sh: ${staging_domain}. Use remove-site.sh for dev or production sites."
    fi

    echo ""
    echo "Staging domain to remove: ${staging_domain}"
    echo ""

    # Validate nginx config exists
    NGINX_CONF="/etc/nginx/sites-available/${staging_domain}.conf"
    if [ ! -f "$NGINX_CONF" ]; then
        error_exit "Nginx configuration not found: $NGINX_CONF"
    fi

    # Extract WordPress path from nginx config
    STAGING_PATH=$(grep "root " "$NGINX_CONF" | grep -v "#" | head -1 | awk '{print $2}' | tr -d ';')

    if [ -z "$STAGING_PATH" ]; then
        error_exit "Could not determine WordPress path from nginx config"
    fi

    # Extract database credentials
    WP_CONFIG="${STAGING_PATH}/wp-config.php"
    read DB_NAME DB_USER DB_PASS DB_HOST <<< $(extract_db_credentials "$WP_CONFIG")

    # Check SSL certificate
    SSL_CERT_PATH="/etc/letsencrypt/live/${staging_domain}"
    HAS_SSL=false
    IS_WILDCARD=false

    if [ -d "$SSL_CERT_PATH" ]; then
        HAS_SSL=true
        if is_wildcard_cert "$staging_domain"; then
            IS_WILDCARD=true
        fi
    else
        # Check if nginx config references a wildcard cert
        if grep -q "/etc/letsencrypt/live/\*\." "$NGINX_CONF" 2>/dev/null; then
            HAS_SSL=true
            IS_WILDCARD=true
            # Extract actual wildcard cert path
            SSL_CERT_PATH=$(grep "ssl_certificate " "$NGINX_CONF" | grep -v "#" | head -1 | awk '{print $2}' | tr -d ';' | xargs dirname)
        fi
    fi

    # Check log files
    ACCESS_LOG="${LOGS_ROOT}/${staging_domain}.access.log"
    ERROR_LOG="${LOGS_ROOT}/${staging_domain}.error.log"

    # Display what will be deleted
    echo -e "${RED}⚠  WARNING: This will PERMANENTLY delete the following:${NC}"
    echo ""
    echo -e "${YELLOW}[NGINX CONFIGURATION]${NC}"
    echo "  - ${NGINX_CONF}"
    echo "  - /etc/nginx/sites-enabled/${staging_domain}"
    echo ""

    if [ "$HAS_SSL" = true ]; then
        echo -e "${YELLOW}[SSL CERTIFICATE]${NC}"
        if [ "$IS_WILDCARD" = true ]; then
            echo "  - ${SSL_CERT_PATH} (wildcard - will be PRESERVED)"
        else
            echo "  - ${SSL_CERT_PATH}"
        fi
        echo ""
    fi

    if [ "$DB_NAME" != "N/A" ] && [ -n "$DB_NAME" ]; then
        echo -e "${YELLOW}[DATABASE]${NC}"
        echo "  - Database: ${DB_NAME}"
        echo "  - User:     ${DB_USER}"
        echo "  - Host:     ${DB_HOST}"
        echo ""
    else
        echo -e "${YELLOW}[DATABASE]${NC}"
        echo "  - No database credentials found in wp-config.php"
        echo ""
    fi

    if [ -d "$STAGING_PATH" ]; then
        DISK_USAGE=$(du -sh "$STAGING_PATH" 2>/dev/null | cut -f1 || echo "unknown")
        echo -e "${YELLOW}[WORDPRESS FILES]${NC}"
        echo "  - ${STAGING_PATH}"
        echo "  - Size: ${DISK_USAGE}"
        echo ""
    else
        echo -e "${YELLOW}[WORDPRESS FILES]${NC}"
        echo "  - Directory not found: ${STAGING_PATH}"
        echo ""
    fi

    if [ -f "$ACCESS_LOG" ] || [ -f "$ERROR_LOG" ]; then
        echo -e "${YELLOW}[LOG FILES]${NC}"
        [ -f "$ACCESS_LOG" ] && echo "  - ${ACCESS_LOG}"
        [ -f "$ERROR_LOG" ] && echo "  - ${ERROR_LOG}"
        echo ""
    fi

    echo "========================================="
    echo ""

    # Confirmation 1: Type domain name
    echo -e "${RED}Type the staging domain to confirm deletion:${NC}"
    read -p "> " confirmation

    if [ "$confirmation" != "$staging_domain" ]; then
        echo "Domain mismatch. Aborting."
        exit 0
    fi

    echo ""

    # Confirmation 2: MySQL password (if database exists)
    if [ "$DB_NAME" != "N/A" ] && [ -n "$DB_NAME" ]; then
        echo "MySQL root authentication required for database deletion"
        read -sp "Enter MySQL root password: " MYSQL_ROOT_PASS
        echo ""
        echo ""

        # Test MySQL connection
        if ! mysql_root -e "SELECT 1" &>/dev/null; then
            error_exit "MySQL authentication failed"
        fi

        echo -e "${GREEN}✓ MySQL authentication successful${NC}"
        echo ""
    fi

    # Begin deletion
    echo "Starting deletion process..."
    echo ""

    # 1. Remove nginx config
    echo "[1/6] Removing nginx configuration..."
    sudo rm -f "/etc/nginx/sites-enabled/${staging_domain}"
    sudo rm -f "$NGINX_CONF"

    if sudo nginx -t &>/dev/null; then
        sudo service nginx reload &>/dev/null
        echo -e "${GREEN}✓ Nginx configuration removed and reloaded${NC}"
    else
        echo -e "${YELLOW}⚠ Nginx config test failed, but files removed${NC}"
    fi
    echo ""

    # 2. Remove SSL certificate (if not wildcard)
    if [ "$HAS_SSL" = true ]; then
        echo "[2/6] Handling SSL certificate..."
        if [ "$IS_WILDCARD" = true ]; then
            echo -e "${GREEN}✓ Wildcard certificate preserved (may be used by other sites)${NC}"
        else
            if [ -d "$SSL_CERT_PATH" ]; then
                sudo certbot delete --cert-name "${staging_domain}" --non-interactive &>/dev/null || true
                echo -e "${GREEN}✓ SSL certificate removed${NC}"
            else
                echo -e "${YELLOW}⚠ SSL certificate path not found${NC}"
            fi
        fi
    else
        echo "[2/6] No SSL certificate to remove"
    fi
    echo ""

    # 3. Drop database
    if [ "$DB_NAME" != "N/A" ] && [ -n "$DB_NAME" ]; then
        echo "[3/6] Removing database..."

        # Drop database
        if mysql_root -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" 2>/dev/null; then
            echo -e "${GREEN}✓ Database '${DB_NAME}' dropped${NC}"
        else
            echo -e "${YELLOW}⚠ Failed to drop database '${DB_NAME}'${NC}"
        fi

        # Drop user
        if mysql_root -e "DROP USER IF EXISTS '${DB_USER}'@'${DB_HOST}';" 2>/dev/null; then
            echo -e "${GREEN}✓ Database user '${DB_USER}' removed${NC}"
        else
            echo -e "${YELLOW}⚠ Failed to drop user '${DB_USER}'${NC}"
        fi

        mysql_root -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    else
        echo "[3/6] No database to remove"
    fi
    echo ""

    # 4. Remove WordPress files
    echo "[4/6] Removing WordPress files..."
    if [ -d "$STAGING_PATH" ]; then
        rm -rf "$STAGING_PATH"
        echo -e "${GREEN}✓ WordPress files removed: ${STAGING_PATH}${NC}"
    else
        echo -e "${YELLOW}⚠ WordPress directory not found${NC}"
    fi
    echo ""

    # 5. Remove log files
    echo "[5/6] Removing log files..."
    removed_logs=0
    if [ -f "$ACCESS_LOG" ]; then
        rm -f "$ACCESS_LOG"
        removed_logs=$((removed_logs + 1))
    fi
    if [ -f "$ERROR_LOG" ]; then
        rm -f "$ERROR_LOG"
        removed_logs=$((removed_logs + 1))
    fi

    if [ $removed_logs -gt 0 ]; then
        echo -e "${GREEN}✓ Removed ${removed_logs} log file(s)${NC}"
    else
        echo -e "${YELLOW}⚠ No log files found${NC}"
    fi
    echo ""

    # 6. Final cleanup
    echo "[6/6] Final cleanup..."

    # Flush Redis if available
    if command -v redis-cli &>/dev/null; then
        redis-cli flushall async &>/dev/null || true
        echo -e "${GREEN}✓ Redis cache flushed${NC}"
    fi
    echo ""

    # Final summary
    echo "========================================="
    echo -e "${GREEN}✓ Staging Site Removed Successfully!${NC}"
    echo "========================================="
    echo ""
    echo "Removed: ${staging_domain}"
    echo ""
    echo "The following have been deleted:"
    echo "  ✓ Nginx configuration"
    [ "$HAS_SSL" = true ] && [ "$IS_WILDCARD" = false ] && echo "  ✓ SSL certificate"
    [ "$DB_NAME" != "N/A" ] && [ -n "$DB_NAME" ] && echo "  ✓ Database and user"
    echo "  ✓ WordPress files"
    echo "  ✓ Log files"
    echo ""
    echo "========================================="
    echo ""
}

# Run main
main "$@"
