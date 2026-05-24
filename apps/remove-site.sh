#!/bin/bash
#
# Remove WordPress Site - Complete site removal script
#
# USAGE:
#   ./apps/remove-site.sh
#   ./apps/remove-site.sh example.com [--dry-run] [--force] [--preserve-backups]
#
# DESCRIPTION:
#   Safely removes a WordPress production site including all configurations,
#   database, files, backups, and SSL certificates. Multiple confirmations required.
#
# WHAT IT DOES:
#   1. Validates site exists and checks for staging sites (blocks if found)
#   2. Detects site type (production vs staging - suggests remove-staging.sh if staging)
#   3. Extracts all site information (database, SSL, backups, files)
#   4. Shows detailed removal plan
#   5. Requires typing domain name to confirm
#   6. Removes nginx configuration
#   7. Removes from backup.sh SITES array
#   8. Removes SSL certificate (preserves wildcards)
#   9. Optionally drops database (with MySQL root password)
#   10. Optionally deletes WordPress files
#   11. Optionally deletes cache directory
#   12. Removes log files
#   13. Optionally handles backup archives (delete/archive/keep)
#   14. Final cleanup and summary
#
# SAFETY FEATURES:
#   - Blocks removal if staging sites exist (must remove staging first)
#   - Detects staging sites and suggests remove-staging.sh
#   - Lists all items before deletion
#   - Requires typing domain name to confirm
#   - Preserves wildcard SSL certificates
#   - Separate confirmations for destructive actions
#   - Dry-run mode available
#   - Operation logging
#
# FLAGS:
#   --dry-run              Show what would be removed without doing anything
#   --force                Skip all confirmations (use with caution!)
#   --remove-database      Auto-confirm database removal (requires --force)
#   --remove-files         Auto-confirm file removal (requires --force)
#   --remove-backups       Auto-confirm backup removal (requires --force)
#   --preserve-backups     Keep backups in place (default in interactive mode)
#
# ENVIRONMENT VARIABLES:
#   MYSQL_ROOT_PASSWORD    MySQL root password (required for --force --remove-database)
#
# REQUIREMENTS:
#   - MySQL root password (for database deletion)
#   - sudo access for nginx operations
#
# EXAMPLES:
#   # Interactive mode (recommended)
#   ./apps/remove-site.sh
#
#   # Direct mode with domain
#   ./apps/remove-site.sh example.com
#
#   # Dry run to see what would be removed
#   ./apps/remove-site.sh example.com --dry-run
#
#   # Force mode (no confirmations - DANGEROUS!)
#   MYSQL_ROOT_PASSWORD='your-password' ./apps/remove-site.sh example.com --force --remove-database --remove-files
#
# NOTES:
#   - This is PERMANENT - files and database cannot be recovered
#   - Wildcard SSL certificates are preserved (may be used by other staging sites)
#   - Always removes staging sites first before removing production sites
#   - All operations are logged to ~/logs/remove-site.log

set -euo pipefail

#=============================================================================
# CONFIGURATION
#=============================================================================

USER=$(whoami)
WEB_ROOT="/home/${USER}/www"
CACHE_ROOT="/home/${USER}/cache"
LOGS_ROOT="/home/${USER}/logs"
BACKUP_ROOT="/home/${USER}/backups"
BACKUP_SCRIPT="/home/${USER}/apps/backup.sh"
LOG_FILE="${LOGS_ROOT}/remove-site.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [ "$(id -u)" -eq 0 ]; then
    echo -e "${RED}ERROR: Run this script as the app user, not root. It uses sudo internally where needed.${NC}" >&2
    exit 1
fi

# Flags
DRY_RUN=false
FORCE_MODE=false
CONFIRM_DATABASE=false
CONFIRM_FILES=false
CONFIRM_BACKUPS=false
PRESERVE_BACKUPS=false
ARCHIVE_BACKUPS=false

#=============================================================================
# LOGGING
#=============================================================================

log_operation() {
    # Ensure logs directory and log file exist
    mkdir -p "$LOGS_ROOT" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null || true
}

#=============================================================================
# HELPER FUNCTIONS
#=============================================================================

error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    log_operation "ERROR: $1"
    exit 1
}

warning() {
    echo -e "${YELLOW}⚠ WARNING: $1${NC}"
    log_operation "WARNING: $1"
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
    log_operation "SUCCESS: $1"
}

info() {
    echo -e "${CYAN}ℹ $1${NC}"
}

extract_db_credentials() {
    local wp_config=$1

    if [ ! -f "$wp_config" ]; then
        echo "N/A N/A N/A N/A"
        return 1
    fi

    # Extract credentials (handles both single and double quotes)
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

find_staging_sites_for_domain() {
    local parent_domain=$1
    local staging_sites=()
    local parent_label="${parent_domain%%.*}"
    local parent_base="${parent_domain#*.}"

    # Look for nginx configs that are explicit staging sites for this domain.
    if [ -d "/etc/nginx/sites-available" ]; then
        for conf in /etc/nginx/sites-available/*.conf; do
            if [ -f "$conf" ]; then
                local conf_domain=$(basename "$conf" .conf)

                # Skip if it's a template
                if [[ "$conf_domain" == "template"* ]] || [[ "$conf_domain" == "default" ]]; then
                    continue
                fi

                if [[ "$conf_domain" == "staging.${parent_domain}" ]] || [[ "$conf_domain" == "staging-${parent_domain}" ]]; then
                    staging_sites+=("$conf_domain")
                elif [ "$parent_base" != "$parent_domain" ] && [[ "$conf_domain" == "${parent_label}-staging.${parent_base}" ]]; then
                    staging_sites+=("$conf_domain")
                fi
            fi
        done
    fi

    echo "${staging_sites[@]}"
}

is_staging_site() {
    local domain=$1

    # Only treat explicit staging-style names as staging. Ordinary subdomains
    # such as app.example.com or client.dev.example.com are regular sites.
    if [[ "$domain" == staging.* ]] || [[ "$domain" == *.staging.* ]] || [[ "$domain" == staging-*.* ]] || [[ "$domain" == *-staging.* ]]; then
        return 0
    fi

    return 1
}

get_backup_frequency() {
    local domain=$1

    if [ ! -f "$BACKUP_SCRIPT" ]; then
        echo "N/A"
        return
    fi

    # Extract frequency from SITES array (exact match, not subdomains)
    local frequency=$(awk -F: "/\"${domain}:/ && !/\\.${domain}:/ {gsub(/[\" )]/,\"\",\$2); print \$2}" "$BACKUP_SCRIPT" | head -1)

    if [ -z "$frequency" ]; then
        echo "N/A"
    else
        echo "$frequency"
    fi
}

count_backup_archives() {
    local domain=$1
    local backup_dir="${BACKUP_ROOT}/${domain}"

    if [ ! -d "$backup_dir" ]; then
        echo "0 0"
        return
    fi

    local count=$(find "$backup_dir" -name "*.tar.gz" 2>/dev/null | wc -l)
    local size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1 || echo "0")

    echo "$count $size"
}

#=============================================================================
# MAIN SCRIPT
#=============================================================================

show_usage() {
    echo "Usage: $0 [domain] [options]"
    echo ""
    echo "Options:"
    echo "  --dry-run              Show what would be removed without doing anything"
    echo "  --force                Skip all confirmations (use with caution!)"
    echo "  --remove-database      Auto-confirm database removal (requires --force)"
    echo "  --remove-files         Auto-confirm file removal (requires --force)"
    echo "  --remove-backups       Auto-confirm backup removal (requires --force)"
    echo "  --preserve-backups     Keep backups in place"
    echo ""
    echo "Examples:"
    echo "  $0                               # Interactive mode"
    echo "  $0 example.com                   # Remove specific site"
    echo "  $0 example.com --dry-run         # Show what would be removed"
    echo "  $0 example.com --preserve-backups # Keep backups"
    exit 0
}

main() {
    echo "========================================="
    echo "Remove WordPress Site"
    echo "========================================="
    echo ""

    log_operation "=== Starting remove-site.sh ==="

    # Parse arguments
    local domain=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                info "Dry-run mode enabled - no changes will be made"
                echo ""
                shift
                ;;
            --force)
                FORCE_MODE=true
                warning "Force mode enabled - confirmations will be skipped"
                echo ""
                shift
                ;;
            --remove-database)
                CONFIRM_DATABASE=true
                shift
                ;;
            --remove-files)
                CONFIRM_FILES=true
                shift
                ;;
            --remove-backups)
                CONFIRM_BACKUPS=true
                shift
                ;;
            --preserve-backups)
                PRESERVE_BACKUPS=true
                shift
                ;;
            --help|-h)
                show_usage
                ;;
            -*)
                error_exit "Unknown option: $1"
                ;;
            *)
                if [ -z "$domain" ]; then
                    domain="$1"
                else
                    error_exit "Multiple domains specified"
                fi
                shift
                ;;
        esac
    done

    # Validate force mode options
    if [ "$CONFIRM_DATABASE" = true ] || [ "$CONFIRM_FILES" = true ] || [ "$CONFIRM_BACKUPS" = true ]; then
        if [ "$FORCE_MODE" != true ]; then
            error_exit "Auto-confirm options require --force flag"
        fi
    fi

    # Interactive mode if no domain specified
    if [ -z "$domain" ]; then
        echo "Available WordPress sites:"
        echo ""

        if [ -d "$WEB_ROOT" ]; then
            local sites_found=false
            for site_dir in "$WEB_ROOT"/*; do
                if [ -d "$site_dir" ] && [ -f "$site_dir/wp-config.php" ]; then
                    local site_domain=$(basename "$site_dir")
                    echo "  • $site_domain"
                    sites_found=true
                fi
            done

            if [ "$sites_found" = false ]; then
                echo "  No WordPress sites found in $WEB_ROOT"
            fi
        else
            echo "  Web root not found: $WEB_ROOT"
        fi

        echo ""
        read -p "Enter domain to remove: " domain
    fi

    if [ -z "$domain" ]; then
        error_exit "No domain specified"
    fi

    # Validate domain format (basic check to prevent injection/traversal)
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
        error_exit "Invalid domain format: $domain"
    fi

    # Additional safety check: no path traversal characters
    if [[ "$domain" == *".."* ]] || [[ "$domain" == *"/"* ]]; then
        error_exit "Domain contains invalid characters: $domain"
    fi

    log_operation "Attempting to remove domain: $domain"

    echo ""
    echo -e "Domain to remove: ${BOLD}${domain}${NC}"
    echo ""

    #=========================================================================
    # PRE-REMOVAL VALIDATION
    #=========================================================================

    echo "Running pre-removal checks..."
    echo ""

    # Check if site is actually a staging site
    if is_staging_site "$domain"; then
        warning "This appears to be a staging site"
        echo ""
        echo "For staging sites, it's recommended to use:"
        echo -e "  ${CYAN}./remove-staging.sh ${domain}${NC}"
        echo ""

        if [ "$FORCE_MODE" != true ]; then
            read -p "Continue anyway? [y/N]: " continue_staging
            if [[ ! "$continue_staging" =~ ^[Yy]$ ]]; then
                echo "Aborting."
                exit 0
            fi
            echo ""
        fi
    fi

    # Check for staging sites (BLOCKING CHECK)
    echo "Checking for staging sites..."
    local staging_sites=($(find_staging_sites_for_domain "$domain"))

    if [ ${#staging_sites[@]} -gt 0 ]; then
        echo ""
        error_exit "Cannot remove ${domain} - staging sites exist:

${staging_sites[@]}

You must remove staging sites first using:
$(for staging in "${staging_sites[@]}"; do echo "  ./remove-staging.sh $staging"; done)

This prevents orphaned staging configurations."
    fi

    success "No staging sites found"
    echo ""

    # Validate site exists
    SITE_DIR="${WEB_ROOT}/${domain}"
    WP_CONFIG="${SITE_DIR}/wp-config.php"
    NGINX_CONF="/etc/nginx/sites-available/${domain}.conf"
    CACHE_DIR="${CACHE_ROOT}/${domain}"

    local site_exists=false

    if [ -f "$WP_CONFIG" ]; then
        site_exists=true
        success "Found WordPress installation"
    else
        warning "WordPress installation not found: $SITE_DIR"
    fi

    if [ -f "$NGINX_CONF" ]; then
        site_exists=true
        success "Found nginx configuration"
    else
        warning "Nginx configuration not found: $NGINX_CONF"
    fi

    if [ "$site_exists" = false ]; then
        error_exit "Site not found. Already removed?"
    fi

    echo ""

    #=========================================================================
    # INFORMATION GATHERING
    #=========================================================================

    echo "Gathering site information..."
    echo ""

    # Extract database credentials
    read DB_NAME DB_USER DB_PASS DB_HOST <<< $(extract_db_credentials "$WP_CONFIG")

    # Check SSL certificate
    SSL_CERT_PATH="/etc/letsencrypt/live/${domain}"
    HAS_SSL=false
    IS_WILDCARD=false

    if [ -d "$SSL_CERT_PATH" ]; then
        HAS_SSL=true
        if is_wildcard_cert "$domain"; then
            IS_WILDCARD=true
        fi
    else
        # Check if nginx config references a cert
        if [ -f "$NGINX_CONF" ] && grep -q "ssl_certificate" "$NGINX_CONF" 2>/dev/null; then
            HAS_SSL=true
            # Extract actual cert path
            SSL_CERT_PATH=$(grep "ssl_certificate " "$NGINX_CONF" | grep -v "#" | head -1 | awk '{print $2}' | tr -d ';' | xargs dirname 2>/dev/null || echo "$SSL_CERT_PATH")
            if [[ "$SSL_CERT_PATH" == *"*."* ]]; then
                IS_WILDCARD=true
            fi
        fi
    fi

    # Check log files
    ACCESS_LOG="${LOGS_ROOT}/${domain}.access.log"
    ERROR_LOG="${LOGS_ROOT}/${domain}.error.log"

    # Get backup info
    BACKUP_FREQ=$(get_backup_frequency "$domain")
    read BACKUP_COUNT BACKUP_SIZE <<< $(count_backup_archives "$domain")
    BACKUP_DIR="${BACKUP_ROOT}/${domain}"

    # Get file sizes
    if [ -d "$SITE_DIR" ]; then
        SITE_SIZE=$(du -sh "$SITE_DIR" 2>/dev/null | cut -f1 || echo "unknown")
    else
        SITE_SIZE="N/A"
    fi

    if [ -d "$CACHE_DIR" ]; then
        CACHE_SIZE=$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1 || echo "unknown")
        HAS_CACHE=true
    else
        CACHE_SIZE="N/A"
        HAS_CACHE=false
    fi

    #=========================================================================
    # DISPLAY REMOVAL PLAN
    #=========================================================================

    echo "========================================="
    echo -e "SITE REMOVAL PLAN for: ${BOLD}${domain}${NC}"
    echo "========================================="
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN MODE - NO CHANGES WILL BE MADE]${NC}"
        echo ""
    fi

    echo -e "${RED}THE FOLLOWING WILL BE REMOVED:${NC}"
    echo ""

    # Nginx configuration
    echo -e "${YELLOW}[NGINX CONFIGURATION]${NC}"
    if [ -f "$NGINX_CONF" ]; then
        echo "  ✓ /etc/nginx/sites-available/${domain}.conf"
        echo "  ✓ /etc/nginx/sites-enabled/${domain} (symlink)"
    else
        echo "  - Not found"
    fi
    echo ""

    # SSL certificate
    if [ "$HAS_SSL" = true ]; then
        echo -e "${YELLOW}[SSL CERTIFICATE]${NC}"
        if [ "$IS_WILDCARD" = true ]; then
            echo "  ✓ ${SSL_CERT_PATH}"
            echo -e "    ${CYAN}└─ Type: Wildcard (will be PRESERVED)${NC}"
        else
            echo "  ✓ ${SSL_CERT_PATH}"
            echo "    └─ Type: Specific (will be removed)"
        fi
    else
        echo -e "${YELLOW}[SSL CERTIFICATE]${NC}"
        echo "  - No SSL certificate found"
    fi
    echo ""

    # Database
    if [ "$DB_NAME" != "N/A" ] && [ -n "$DB_NAME" ]; then
        echo -e "${YELLOW}[DATABASE]${NC} ${CYAN}(with confirmation)${NC}"
        echo "  • Database: ${DB_NAME}"
        echo "  • User:     ${DB_USER}@'${DB_HOST}'"
    else
        echo -e "${YELLOW}[DATABASE]${NC}"
        echo "  - No database credentials found"
    fi
    echo ""

    # WordPress files
    if [ -d "$SITE_DIR" ]; then
        echo -e "${YELLOW}[WORDPRESS FILES]${NC} ${CYAN}(with confirmation)${NC}"
        echo "  • ${SITE_DIR}"
        echo "  • Size: ${SITE_SIZE}"
    else
        echo -e "${YELLOW}[WORDPRESS FILES]${NC}"
        echo "  - Directory not found"
    fi
    echo ""

    # Cache directory
    if [ "$HAS_CACHE" = true ]; then
        echo -e "${YELLOW}[CACHE DIRECTORY]${NC}"
        echo "  • ${CACHE_DIR}"
        echo "  • Size: ${CACHE_SIZE}"
        echo ""
    fi

    # Log files
    if [ -f "$ACCESS_LOG" ] || [ -f "$ERROR_LOG" ]; then
        echo -e "${YELLOW}[LOG FILES]${NC}"
        [ -f "$ACCESS_LOG" ] && echo "  • ${ACCESS_LOG}"
        [ -f "$ERROR_LOG" ] && echo "  • ${ERROR_LOG}"
    else
        echo -e "${YELLOW}[LOG FILES]${NC}"
        echo "  - No log files found"
    fi
    echo ""

    # Backup configuration
    if [ "$BACKUP_FREQ" != "N/A" ]; then
        echo -e "${YELLOW}[BACKUP CONFIGURATION]${NC}"
        echo "  • Entry in backup.sh (frequency: ${BACKUP_FREQ})"
        echo "  • Will be removed from SITES array"
    else
        echo -e "${YELLOW}[BACKUP CONFIGURATION]${NC}"
        echo "  - Not in backup.sh SITES array"
    fi
    echo ""

    # Backup archives
    if [ "$BACKUP_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}[BACKUP ARCHIVES]${NC} ${CYAN}(with confirmation)${NC}"
        echo "  • ${BACKUP_DIR}/"
        echo "  • ${BACKUP_COUNT} backup file(s) (${BACKUP_SIZE} total)"
    else
        echo -e "${YELLOW}[BACKUP ARCHIVES]${NC}"
        echo "  - No backup archives found"
    fi
    echo ""

    # Warnings
    echo -e "${YELLOW}[WARNINGS]${NC}"
    echo "  ⚠ No staging sites detected for this domain"
    if [ "$DB_NAME" != "N/A" ] || [ -d "$SITE_DIR" ]; then
        echo "  ⚠ Database and files cannot be recovered after deletion"
    fi
    if [ "$BACKUP_COUNT" -gt 0 ]; then
        echo "  ⚠ Backup archives contain historical site data"
    fi
    echo ""

    echo "========================================="
    echo ""

    # Exit if dry-run
    if [ "$DRY_RUN" = true ]; then
        echo -e "${GREEN}Dry-run complete. No changes were made.${NC}"
        echo ""
        echo "To perform actual removal, run without --dry-run flag"
        exit 0
    fi

    #=========================================================================
    # CONFIRMATIONS
    #=========================================================================

    # Confirmation 1: Type domain name
    if [ "$FORCE_MODE" != true ]; then
        echo -e "${RED}${BOLD}Type the domain name to confirm deletion:${NC}"
        read -p "> " confirmation

        if [ "$confirmation" != "$domain" ]; then
            echo "Domain mismatch. Aborting."
            log_operation "Aborted - domain confirmation failed"
            exit 0
        fi
        echo ""
    fi

    # Confirmation 2: Database
    local mysql_root_pass=""
    if [ "$DB_NAME" != "N/A" ] && [ -n "$DB_NAME" ]; then
        if [ "$FORCE_MODE" != true ]; then
            read -p "Remove database '${DB_NAME}'? [y/N]: " remove_db
            if [[ "$remove_db" =~ ^[Yy]$ ]]; then
                CONFIRM_DATABASE=true
            fi
            echo ""
        fi

        if [ "$CONFIRM_DATABASE" = true ]; then
            if [ "$FORCE_MODE" != true ]; then
                echo "MySQL root authentication required for database deletion"
                read -sp "Enter MySQL root password: " mysql_root_pass
                echo ""
                echo ""

                # Test MySQL connection
                if ! mysql --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s\n" "$mysql_root_pass") -e "SELECT 1" &>/dev/null; then
                    error_exit "MySQL authentication failed"
                fi

                success "MySQL authentication successful"
                echo ""
            else
                warning "Force mode: Database will be removed (ensure MySQL credentials are available)"
                echo ""
            fi
        fi
    fi

    # Confirmation 3: WordPress files
    if [ -d "$SITE_DIR" ]; then
        if [ "$FORCE_MODE" != true ]; then
            echo "WordPress files: ${SITE_DIR} (${SITE_SIZE})"
            read -p "Delete WordPress files? [y/N]: " remove_files
            if [[ "$remove_files" =~ ^[Yy]$ ]]; then
                CONFIRM_FILES=true
            fi
            echo ""
        fi
    fi

    # Confirmation 4: Backup archives
    if [ "$BACKUP_COUNT" -gt 0 ]; then
        if [ "$PRESERVE_BACKUPS" = true ]; then
            info "Preserving backup archives (--preserve-backups flag)"
            CONFIRM_BACKUPS=false
            echo ""
        elif [ "$FORCE_MODE" != true ]; then
            echo "Backup archives: ${BACKUP_COUNT} files (${BACKUP_SIZE})"
            echo "1) Delete all backups"
            echo "2) Move to archive (${BACKUP_ROOT}/_archived/${domain}/)"
            echo "3) Keep backups in place (default)"
            read -p "Choice [3]: " backup_choice

            case $backup_choice in
                1)
                    CONFIRM_BACKUPS=true
                    ;;
                2)
                    ARCHIVE_BACKUPS=true
                    ;;
                *)
                    CONFIRM_BACKUPS=false
                    ;;
            esac
            echo ""
        fi
    fi

    #=========================================================================
    # REMOVAL OPERATIONS
    #=========================================================================

    echo "Starting removal process..."
    echo ""

    local step=1
    local total_steps=9

    # Step 1: Remove from backup.sh
    echo "[${step}/${total_steps}] Removing from backup.sh..."
    if [ "$BACKUP_FREQ" != "N/A" ] && [ -f "$BACKUP_SCRIPT" ]; then
        sed -i "\|\"${domain}:|d" "$BACKUP_SCRIPT"
        success "Removed from backup.sh SITES array"
        log_operation "Removed ${domain} from backup.sh"
    else
        info "Not in backup.sh SITES array"
    fi
    echo ""
    step=$((step + 1))

    # Step 2: Remove nginx config
    echo "[${step}/${total_steps}] Removing nginx configuration..."
    if [ -f "$NGINX_CONF" ]; then
        sudo rm -f "/etc/nginx/sites-enabled/${domain}" 2>/dev/null || true
        sudo rm -f "$NGINX_CONF"

        if sudo nginx -t &>/dev/null; then
            sudo service nginx reload &>/dev/null
            success "Nginx configuration removed and reloaded"
            log_operation "Removed nginx config for ${domain}"
        else
            warning "Nginx config test failed, but files removed"
            log_operation "Nginx config removed but test failed for ${domain}"
        fi
    else
        info "Nginx configuration not found"
    fi
    echo ""
    step=$((step + 1))

    # Step 3: Remove SSL certificate
    echo "[${step}/${total_steps}] Handling SSL certificate..."
    if [ "$HAS_SSL" = true ]; then
        if [ "$IS_WILDCARD" = true ]; then
            success "Wildcard certificate preserved (may be used by other sites)"
            log_operation "Preserved wildcard SSL cert for ${domain}"
        else
            if [ -d "$SSL_CERT_PATH" ]; then
                sudo certbot delete --cert-name "${domain}" --non-interactive &>/dev/null || true
                success "SSL certificate removed"
                log_operation "Removed SSL cert for ${domain}"
            else
                info "SSL certificate path not found"
            fi
        fi
    else
        info "No SSL certificate to remove"
    fi
    echo ""
    step=$((step + 1))

    # Step 4: Drop database
    echo "[${step}/${total_steps}] Handling database..."
    if [ "$CONFIRM_DATABASE" = true ] && [ "$DB_NAME" != "N/A" ] && [ -n "$DB_NAME" ]; then
        # Get MySQL password if not already provided
        if [ -z "$mysql_root_pass" ]; then
            if [ "$FORCE_MODE" = true ]; then
                # In force mode, check for environment variable
                if [ -n "${MYSQL_ROOT_PASSWORD:-}" ]; then
                    mysql_root_pass="$MYSQL_ROOT_PASSWORD"
                else
                    error_exit "Force mode requires MYSQL_ROOT_PASSWORD environment variable for database deletion"
                fi
            else
                # This should not happen as password was collected earlier, but just in case
                read -sp "Enter MySQL root password: " mysql_root_pass
                echo ""
            fi
        fi

        if mysql --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s\n" "$mysql_root_pass") -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" 2>/dev/null; then
            success "Database '${DB_NAME}' dropped"
            log_operation "Dropped database ${DB_NAME}"
        else
            warning "Failed to drop database '${DB_NAME}'"
            log_operation "Failed to drop database ${DB_NAME}"
        fi

        if mysql --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s\n" "$mysql_root_pass") -e "DROP USER IF EXISTS '${DB_USER}'@'${DB_HOST}';" 2>/dev/null; then
            success "Database user '${DB_USER}' removed"
            log_operation "Dropped user ${DB_USER}"
        else
            warning "Failed to drop user '${DB_USER}'"
            log_operation "Failed to drop user ${DB_USER}"
        fi

        mysql --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s\n" "$mysql_root_pass") -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    else
        info "Database preserved (not confirmed for deletion)"
    fi
    echo ""
    step=$((step + 1))

    # Step 5: Remove cache directory
    echo "[${step}/${total_steps}] Removing cache directory..."
    if [ "$HAS_CACHE" = true ]; then
        rm -rf "$CACHE_DIR"
        success "Cache directory removed: ${CACHE_DIR}"
        log_operation "Removed cache dir for ${domain}"
    else
        info "No cache directory found"
    fi
    echo ""
    step=$((step + 1))

    # Step 6: Remove WordPress files
    echo "[${step}/${total_steps}] Handling WordPress files..."
    if [ "$CONFIRM_FILES" = true ] && [ -d "$SITE_DIR" ]; then
        rm -rf "$SITE_DIR"
        success "WordPress files removed: ${SITE_DIR}"
        log_operation "Removed WordPress files for ${domain}"
    elif [ -d "$SITE_DIR" ]; then
        info "WordPress files preserved (not confirmed for deletion)"
        info "Manual removal: rm -rf ${SITE_DIR}"
    else
        info "WordPress directory not found"
    fi
    echo ""
    step=$((step + 1))

    # Step 7: Remove log files
    echo "[${step}/${total_steps}] Removing log files..."
    local removed_logs=0
    if [ -f "$ACCESS_LOG" ]; then
        rm -f "$ACCESS_LOG"
        removed_logs=$((removed_logs + 1))
    fi
    if [ -f "$ERROR_LOG" ]; then
        rm -f "$ERROR_LOG"
        removed_logs=$((removed_logs + 1))
    fi

    if [ $removed_logs -gt 0 ]; then
        success "Removed ${removed_logs} log file(s)"
        log_operation "Removed ${removed_logs} log files for ${domain}"
    else
        info "No log files found"
    fi
    echo ""
    step=$((step + 1))

    # Step 8: Handle backup archives
    echo "[${step}/${total_steps}] Handling backup archives..."
    if [ "$BACKUP_COUNT" -gt 0 ]; then
        if [ "$CONFIRM_BACKUPS" = true ]; then
            rm -rf "$BACKUP_DIR"
            success "Deleted ${BACKUP_COUNT} backup archive(s)"
            log_operation "Deleted backup archives for ${domain}"
        elif [ "${ARCHIVE_BACKUPS:-false}" = true ]; then
            local archive_dir="${BACKUP_ROOT}/_archived/${domain}"
            mkdir -p "$archive_dir"
            mv "$BACKUP_DIR"/* "$archive_dir/" 2>/dev/null || true
            rmdir "$BACKUP_DIR" 2>/dev/null || true
            success "Moved backups to: ${archive_dir}"
            log_operation "Archived backups for ${domain}"
        else
            info "Backup archives preserved in: ${BACKUP_DIR}"
        fi
    else
        # Remove empty backup directory if exists
        if [ -d "$BACKUP_DIR" ]; then
            rmdir "$BACKUP_DIR" 2>/dev/null || true
        fi
        info "No backup archives found"
    fi
    echo ""
    step=$((step + 1))

    # Step 9: Final cleanup
    echo "[${step}/${total_steps}] Final cleanup..."

    # Flush Redis if available
    if command -v redis-cli &>/dev/null; then
        redis-cli flushall async &>/dev/null || true
        success "Redis cache flushed"
    fi

    # Clean up empty parent directories
    rmdir "$BACKUP_DIR" 2>/dev/null || true

    echo ""

    #=========================================================================
    # FINAL SUMMARY
    #=========================================================================

    echo "========================================="
    echo -e "${GREEN}${BOLD}✓ Site Removal Complete!${NC}"
    echo "========================================="
    echo ""
    echo -e "Removed: ${BOLD}${domain}${NC}"
    echo ""
    echo "The following have been removed:"
    echo "  ✓ Nginx configuration"
    [ "$BACKUP_FREQ" != "N/A" ] && echo "  ✓ Backup.sh entry"
    [ "$HAS_SSL" = true ] && [ "$IS_WILDCARD" = false ] && echo "  ✓ SSL certificate"
    [ "$CONFIRM_DATABASE" = true ] && [ "$DB_NAME" != "N/A" ] && echo "  ✓ Database and user"
    [ "$HAS_CACHE" = true ] && echo "  ✓ Cache directory"
    [ "$CONFIRM_FILES" = true ] && echo "  ✓ WordPress files"
    [ $removed_logs -gt 0 ] && echo "  ✓ Log files"
    [ "$CONFIRM_BACKUPS" = true ] && echo "  ✓ Backup archives"
    [ "${ARCHIVE_BACKUPS:-false}" = true ] && echo "  ✓ Backups archived"
    echo ""

    if [ "$CONFIRM_FILES" != true ] && [ -d "$SITE_DIR" ]; then
        echo "Preserved items:"
        echo "  • WordPress files: ${SITE_DIR}"
        echo ""
    fi

    if [ "$CONFIRM_DATABASE" != true ] && [ "$DB_NAME" != "N/A" ]; then
        echo "Preserved items:"
        echo "  • Database: ${DB_NAME}"
        echo "  • Database user: ${DB_USER}"
        echo ""
    fi

    if [ "$BACKUP_COUNT" -gt 0 ] && [ "$CONFIRM_BACKUPS" != true ] && [ "${ARCHIVE_BACKUPS:-false}" != true ]; then
        echo "Preserved items:"
        echo "  • Backup archives: ${BACKUP_DIR}"
        echo ""
    fi

    echo "Operation log: ${LOG_FILE}"
    echo "========================================="
    echo ""

    log_operation "=== Site removal completed for ${domain} ==="
}

# Run main
main "$@"
