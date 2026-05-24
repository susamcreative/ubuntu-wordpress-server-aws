#!/bin/bash
#
# Restore WordPress Backup - Restore WordPress site from backup
#
# USAGE:
#   ./apps/restore-backup.sh
#
# DESCRIPTION:
#   Restores a WordPress site from backup archives created by the backup system.
#   Lists available sites and their backups, validates compatibility, and restores
#   database and/or files with safety confirmations.
#
# WHAT IT DOES:
#   1. Lists all WordPress sites on the server
#   2. Shows available backups for selected site
#   3. Validates backup belongs to the selected site
#   4. Prompts for restoration options (database, files, or both)
#   5. Creates safety backup before restoration
#   6. Restores selected components
#   7. Verifies restoration success
#
# SAFETY FEATURES:
#   - Validates backup filename matches site
#   - Creates pre-restoration backup
#   - Confirms before overwriting data
#   - Tests database restoration
#   - Validates file integrity
#
# REQUIREMENTS:
#   - MySQL root password (prompted)
#   - Backup archives in ~/backups/{site}/
#   - Sufficient disk space for extraction
#
# EXAMPLES:
#   # Interactive restoration
#   ~/apps/restore-backup.sh

set -euo pipefail

#=============================================================================
# CONFIGURATION
#=============================================================================

USER=$(whoami)
WEB_ROOT="/home/${USER}/www"
BACKUP_ROOT="/home/${USER}/backups"
TEMP_DIR="/tmp/restore-$$"

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

cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

mysql_root() {
    mysql --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s\n" "$MYSQL_ROOT_PASS") "$@"
}

mysql_with_credentials() {
    local dbuser=$1
    local dbpass=$2
    shift 2

    mysql --defaults-extra-file=<(printf "[client]\nuser=%s\npassword=%s\n" "$dbuser" "$dbpass") "$@"
}

mysqldump_with_credentials() {
    local dbuser=$1
    local dbpass=$2
    shift 2

    mysqldump --defaults-extra-file=<(printf "[client]\nuser=%s\npassword=%s\n" "$dbuser" "$dbpass") "$@"
}

#=============================================================================
# SITE LISTING
#=============================================================================

list_sites() {
    echo "Scanning for WordPress sites..."
    echo ""

    local sites=()
    local index=1

    if [ ! -d "$WEB_ROOT" ]; then
        error_exit "Web root directory not found: $WEB_ROOT"
    fi

    for site_dir in "$WEB_ROOT"/*/ ; do
        if [ -d "$site_dir" ]; then
            local site=$(basename "$site_dir")
            # Check if it's a WordPress installation
            if [ -f "$site_dir/wp-config.php" ]; then
                sites+=("$site")
                echo "  ${index}) ${site}"
                index=$((index + 1))
            fi
        fi
    done

    if [ ${#sites[@]} -eq 0 ]; then
        error_exit "No WordPress sites found in $WEB_ROOT"
    fi

    echo ""
    read -p "Select site number: " site_choice

    if ! [[ "$site_choice" =~ ^[0-9]+$ ]] || [ "$site_choice" -lt 1 ] || [ "$site_choice" -gt ${#sites[@]} ]; then
        error_exit "Invalid selection"
    fi

    SELECTED_SITE="${sites[$((site_choice - 1))]}"
    echo -e "${GREEN}Selected: ${SELECTED_SITE}${NC}"
    echo ""
}

#=============================================================================
# BACKUP LISTING
#=============================================================================

list_backups() {
    local site=$1
    local backup_dir="${BACKUP_ROOT}/${site}"

    if [ ! -d "$backup_dir" ]; then
        error_exit "No backups found for site: $site (directory missing: $backup_dir)"
    fi

    echo "Available backups for ${site}:"
    echo ""

    local backups=()
    local index=1

    # Find all backup archives, sort by date (newest first)
    while IFS= read -r backup_file; do
        if [ -f "$backup_file" ]; then
            local filename=$(basename "$backup_file")
            local filesize=$(du -h "$backup_file" | cut -f1)

            # Extract date and frequency from filename
            # Format: sitename_frequency_YY.MM.DD_HH.MM.tar.gz
            if [[ "$filename" =~ ${site}_([^_]+)_([0-9.]+_[0-9.]+)\.tar\.gz ]]; then
                local frequency="${BASH_REMATCH[1]}"
                local datetime="${BASH_REMATCH[2]}"

                backups+=("$backup_file")
                printf "  %2d) %-10s %s (%s)\n" "$index" "[$frequency]" "$datetime" "$filesize"
                index=$((index + 1))
            fi
        fi
    done < <(find "$backup_dir" -name "${site}_*.tar.gz" -type f | sort -r)

    if [ ${#backups[@]} -eq 0 ]; then
        error_exit "No backup archives found for site: $site"
    fi

    echo ""
    read -p "Select backup number: " backup_choice

    if ! [[ "$backup_choice" =~ ^[0-9]+$ ]] || [ "$backup_choice" -lt 1 ] || [ "$backup_choice" -gt ${#backups[@]} ]; then
        error_exit "Invalid selection"
    fi

    SELECTED_BACKUP="${backups[$((backup_choice - 1))]}"
    echo -e "${GREEN}Selected: $(basename "$SELECTED_BACKUP")${NC}"
    echo ""
}

#=============================================================================
# VALIDATION
#=============================================================================

validate_backup() {
    local site=$1
    local backup_file=$2
    local filename=$(basename "$backup_file")

    # Validate filename starts with site name
    if [[ ! "$filename" =~ ^${site}_ ]]; then
        error_exit "Backup validation failed: Backup '$filename' does not belong to site '$site'"
    fi

    # Check file integrity
    if ! tar -tzf "$backup_file" &>/dev/null; then
        error_exit "Backup validation failed: Archive is corrupted or invalid"
    fi

    echo -e "${GREEN}✓ Backup validation passed${NC}"
    echo ""
}

#=============================================================================
# DATABASE OPERATIONS
#=============================================================================

get_db_credentials() {
    local site=$1
    local wp_config="${WEB_ROOT}/${site}/wp-config.php"

    if [ ! -f "$wp_config" ]; then
        error_exit "wp-config.php not found for site: $site"
    fi

    # Extract database credentials from wp-config.php
    DB_NAME=$(grep "DB_NAME" "$wp_config" | cut -d "'" -f 4)
    DB_USER=$(grep "DB_USER" "$wp_config" | cut -d "'" -f 4)
    DB_PASS=$(grep "DB_PASSWORD" "$wp_config" | cut -d "'" -f 4)

    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
        error_exit "Failed to extract database credentials from wp-config.php"
    fi

    echo -e "${GREEN}✓ Database credentials extracted${NC}"
}

setup_mysql_auth() {
    echo "MySQL root authentication required for restoration"
    read -sp "Enter MySQL root password: " MYSQL_ROOT_PASS
    echo ""

    # Test connection
    if ! mysql_root -e "SELECT 1" &>/dev/null; then
        error_exit "MySQL authentication failed"
    fi

    echo -e "${GREEN}✓ MySQL authentication successful${NC}"
    echo ""
}

restore_database() {
    local site=$1
    local backup_file=$2

    echo "[1/2] Restoring database..."

    mkdir -p "$TEMP_DIR"

    # Extract the backup archive
    echo "  Extracting backup archive..."
    tar -xzf "$backup_file" -C "$TEMP_DIR" 2>/dev/null || error_exit "Failed to extract backup archive"

    # Find the SQL dump inside the extracted site directory
    local sql_file=$(find "$TEMP_DIR" -name "${site}_*.sql.gz" -type f | head -1)

    if [ -z "$sql_file" ]; then
        error_exit "No database dump found in backup archive"
    fi

    echo "  Found database dump: $(basename "$sql_file")"

    # Create a safety backup of current database
    echo "  Creating safety backup of current database..."
    local safety_backup="${BACKUP_ROOT}/${site}/safety_backup_$(date +%y.%m.%d_%H.%M).sql.gz"
    mkdir -p "${BACKUP_ROOT}/${site}"
    mysqldump_with_credentials "$DB_USER" "$DB_PASS" "$DB_NAME" 2>/dev/null | gzip > "$safety_backup" || {
        echo -e "${YELLOW}  ⚠ Could not create safety backup (database might not exist)${NC}"
    }

    # Drop and recreate database
    echo "  Recreating database..."
    mysql_root -e "DROP DATABASE IF EXISTS ${DB_NAME}; CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;" 2>/dev/null || error_exit "Failed to recreate database"

    # Restore database from dump
    echo "  Importing database dump..."
    gunzip -c "$sql_file" | mysql_with_credentials "$DB_USER" "$DB_PASS" "$DB_NAME" 2>/dev/null || error_exit "Failed to import database dump"

    # Verify restoration
    local table_count=$(mysql_with_credentials "$DB_USER" "$DB_PASS" "$DB_NAME" -e "SHOW TABLES;" 2>/dev/null | wc -l)
    if [ "$table_count" -lt 2 ]; then
        error_exit "Database restoration verification failed (no tables found)"
    fi

    echo -e "${GREEN}✓ Database restored successfully (${table_count} tables)${NC}"

    if [ -f "$safety_backup" ]; then
        echo -e "${BLUE}  Safety backup saved: $safety_backup${NC}"
    fi
}

#=============================================================================
# FILE OPERATIONS
#=============================================================================

restore_files() {
    local site=$1
    local backup_file=$2

    echo "[2/2] Restoring files..."

    local site_path="${WEB_ROOT}/${site}"

    # Create safety backup of wp-content/uploads (most important user content)
    local uploads_path="${site_path}/wp-content/uploads"
    if [ -d "$uploads_path" ]; then
        echo "  Creating safety backup of uploads folder..."
        local safety_uploads="${BACKUP_ROOT}/${site}/safety_uploads_$(date +%y.%m.%d_%H.%M).tar.gz"
        tar -czf "$safety_uploads" -C "${site_path}/wp-content" uploads 2>/dev/null || {
            echo -e "${YELLOW}  ⚠ Could not backup uploads folder${NC}"
        }
    fi

    # Extract files
    echo "  Extracting files from backup..."
    mkdir -p "$TEMP_DIR/extract"
    tar -xzf "$backup_file" -C "$TEMP_DIR/extract" 2>/dev/null || error_exit "Failed to extract backup files"

    # Find the site directory in the extracted backup
    local extracted_site=$(find "$TEMP_DIR/extract" -maxdepth 1 -type d -name "$site" | head -1)

    if [ -z "$extracted_site" ]; then
        error_exit "Site directory not found in backup archive"
    fi

    # Preserve wp-config.php (don't overwrite current database credentials)
    echo "  Preserving current wp-config.php..."
    cp "${site_path}/wp-config.php" "$TEMP_DIR/wp-config.php.current" || error_exit "Failed to preserve wp-config.php"

    # Remove current files (except wp-config.php)
    echo "  Removing current files..."
    find "$site_path" -mindepth 1 ! -name 'wp-config.php' -delete 2>/dev/null || error_exit "Failed to remove current files"

    # Copy restored files
    echo "  Copying restored files..."
    cp -r "$extracted_site"/* "$site_path/" 2>/dev/null || error_exit "Failed to copy restored files"

    # Restore the preserved wp-config.php
    echo "  Restoring current wp-config.php..."
    cp "$TEMP_DIR/wp-config.php.current" "${site_path}/wp-config.php" || error_exit "Failed to restore wp-config.php"

    # Fix permissions
    echo "  Setting permissions..."
    sudo chown -R ${USER}:www-data "$site_path"
    sudo find "$site_path" -type d -exec chmod g+s {} \;
    sudo chmod g+w "$site_path/wp-content"
    sudo chmod -R g+w "$site_path/wp-content/themes" 2>/dev/null || true
    sudo chmod -R g+w "$site_path/wp-content/plugins" 2>/dev/null || true
    sudo chmod -R g+w "$site_path/wp-content/uploads" 2>/dev/null || true

    echo -e "${GREEN}✓ Files restored successfully${NC}"

    if [ -f "$safety_uploads" ]; then
        echo -e "${BLUE}  Safety backup saved: $safety_uploads${NC}"
    fi
}

#=============================================================================
# MAIN SCRIPT
#=============================================================================

main() {
    echo "========================================="
    echo "Restore WordPress Backup"
    echo "========================================="
    echo ""

    # List and select site
    list_sites

    # List and select backup
    list_backups "$SELECTED_SITE"

    # Validate backup belongs to site
    validate_backup "$SELECTED_SITE" "$SELECTED_BACKUP"

    # Get database credentials
    get_db_credentials "$SELECTED_SITE"

    # Display restore plan
    echo "========================================="
    echo "Restoration Plan"
    echo "========================================="
    echo "Site:   $SELECTED_SITE"
    echo "Backup: $(basename "$SELECTED_BACKUP")"
    echo "Database: $DB_NAME"
    echo ""

    # Ask what to restore
    echo "What would you like to restore?"
    echo "  1) Database only"
    echo "  2) Files only"
    echo "  3) Both database and files (recommended)"
    read -p "Choose (1/2/3) [3]: " restore_choice
    restore_choice=${restore_choice:-3}

    echo ""
    echo -e "${YELLOW}WARNING: This will overwrite current data!${NC}"
    echo "Safety backups will be created before restoration."
    echo ""
    read -p "Type 'yes' to continue: " confirm

    if [ "$confirm" != "yes" ]; then
        echo "Restoration cancelled."
        exit 0
    fi

    echo ""

    # Setup MySQL authentication if needed
    if [ "$restore_choice" = "1" ] || [ "$restore_choice" = "3" ]; then
        setup_mysql_auth
    fi

    # Perform restoration
    case $restore_choice in
        1)
            restore_database "$SELECTED_SITE" "$SELECTED_BACKUP"
            ;;
        2)
            restore_files "$SELECTED_SITE" "$SELECTED_BACKUP"
            ;;
        3)
            restore_database "$SELECTED_SITE" "$SELECTED_BACKUP"
            restore_files "$SELECTED_SITE" "$SELECTED_BACKUP"
            ;;
        *)
            error_exit "Invalid restoration choice"
            ;;
    esac

    # Flush cache if Redis is available
    if command -v redis-cli &>/dev/null; then
        echo ""
        echo "Flushing Redis cache..."
        redis-cli flushall async &>/dev/null || true
    fi

    # Display success
    echo ""
    echo "========================================="
    echo -e "${GREEN}✓ Restoration Complete!${NC}"
    echo "========================================="
    echo ""
    echo "Site: https://${SELECTED_SITE}"
    echo "Database: $DB_NAME"
    echo ""
    echo "Next steps:"
    echo "  1. Test the website functionality"
    echo "  2. Check wp-admin access"
    echo "  3. Verify content and uploads"
    echo "  4. Safety backups are in: ${BACKUP_ROOT}/${SELECTED_SITE}/"
    echo ""
}

# Run main
main
