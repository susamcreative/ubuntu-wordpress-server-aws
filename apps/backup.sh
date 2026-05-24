#!/bin/bash
#
# WordPress Backup Script - Consolidated backup system
#
# USAGE:
#   ./apps/backup.sh {daily|weekly|monthly}
#
# DESCRIPTION:
#   Backs up WordPress sites based on configured frequency with cascading logic.
#   Reads database credentials from wp-config.php on-the-fly (no hardcoded credentials).
#
# CASCADING FREQUENCY LOGIC:
#   - backup.sh daily   → backs up only sites with :daily frequency
#   - backup.sh weekly  → backs up sites with :daily AND :weekly frequencies
#   - backup.sh monthly → backs up ALL sites (daily, weekly, AND monthly)
#
# RETENTION PERIODS:
#   - Daily backups:   31 days (4 weeks)
#   - Weekly backups:  91 days (3 months)
#   - Monthly backups: 366 days (12 months)
#
# CRON SETUP:
#   00 2 * * * /home/user/apps/backup.sh daily >> /home/user/logs/backup.log 2>&1
#   30 2 * * 1 /home/user/apps/backup.sh weekly >> /home/user/logs/backup.log 2>&1
#   00 3 1 * * /home/user/apps/backup.sh monthly >> /home/user/logs/backup.log 2>&1
#
# ADDING NEW SITES:
#   Sites are automatically added to this array by add-site.sh
#   Manual format: "domain.com:frequency" where frequency is daily, weekly, or monthly
#

set -euo pipefail

#=============================================================================
# CONFIGURATION
#=============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

WEB_ROOT="${APP_HOME}/www"
BACKUP_ROOT="${APP_HOME}/backups"

# Site configuration array
# Format: "domain:frequency"
# Frequencies: daily, weekly, monthly
SITES=(
    # Sites will be added here by add-site.sh
    # Example: "example.com:daily"
)

#=============================================================================
# VALIDATION
#=============================================================================

if [ $# -ne 1 ]; then
    echo "Usage: $0 {daily|weekly|monthly}"
    exit 1
fi

FREQUENCY=$1
THEDATE=$(date +%y.%m.%d_%H.%M)
THEFREQ="${FREQUENCY}"

export THEDATE
export THEFREQ

# Validate frequency
case "$FREQUENCY" in
    daily|weekly|monthly) ;;
    *)
        echo "ERROR: Invalid frequency. Use: daily, weekly, or monthly"
        exit 1
        ;;
esac

#=============================================================================
# BACKUP FUNCTIONS
#=============================================================================

backup_site() {
    local domain=$1
    local site_path="${WEB_ROOT}/${domain}"
    local wp_config="${site_path}/wp-config.php"

    # Validate site exists
    if [ ! -d "$site_path" ]; then
        echo "⚠ Skipping ${domain}: Directory not found"
        return 1
    fi

    if [ ! -f "$wp_config" ]; then
        echo "⚠ Skipping ${domain}: wp-config.php not found"
        return 1
    fi

    # Extract database credentials from wp-config.php
    local dbname=$(grep "DB_NAME" "$wp_config" | cut -d "'" -f 4)
    local dbuser=$(grep "DB_USER" "$wp_config" | cut -d "'" -f 4)
    local dbpass=$(grep "DB_PASSWORD" "$wp_config" | cut -d "'" -f 4)

    if [ -z "$dbname" ] || [ -z "$dbuser" ] || [ -z "$dbpass" ]; then
        echo "⚠ Skipping ${domain}: Could not extract database credentials"
        return 1
    fi

    echo "Backing up: ${domain}"

    # Create database backup (credentials via process substitution to avoid exposure in ps output)
    if mysqldump --defaults-extra-file=<(printf "[client]\nuser=%s\npassword=%s\n" "$dbuser" "$dbpass") "$dbname" 2>/dev/null | gzip > "${site_path}/${domain}_${THEDATE}.sql.gz"; then
        echo "  ✓ Database backup created"
    else
        echo "  ✗ Database backup failed"
        rm -f "${site_path}/${domain}_${THEDATE}.sql.gz"
        return 1
    fi

    # Create archive
    if sudo tar -czf "${BACKUP_ROOT}/${domain}/${domain}_${THEFREQ}_${THEDATE}.tar.gz" \
        --exclude='wp-content/cache' \
        --exclude="${domain}/wp-content/litespeed" \
        -C "$WEB_ROOT" \
        "$domain" 2>/dev/null; then
        echo "  ✓ Archive created"
    else
        echo "  ✗ Archive creation failed"
        rm -f "${site_path}/${domain}_${THEDATE}.sql.gz"
        return 1
    fi

    # Remove temporary SQL backup
    rm -f "${site_path}/${domain}_${THEDATE}.sql.gz"
    echo "  ✓ ${domain} backup complete"
    echo ""

    return 0
}

#=============================================================================
# MAIN BACKUP PROCESS
#=============================================================================

# Change to web root
cd "$WEB_ROOT" || exit 1

echo "========================================="
echo "Backup Run: ${FREQUENCY}"
echo "Date: ${THEDATE}"
echo "========================================="
echo ""

# Check if there are any sites configured
if [ ${#SITES[@]} -eq 0 ]; then
    echo "No sites configured for backup"
    echo "Add sites using: ~/apps/add-site.sh"
    echo ""
    exit 0
fi

# Process sites based on frequency
BACKUP_COUNT=0
SKIPPED_COUNT=0

for entry in "${SITES[@]}"; do
    # Skip empty entries
    if [ -z "$entry" ]; then
        continue
    fi

    # Parse domain:frequency
    domain="${entry%%:*}"
    site_freq="${entry##*:}"

    # Determine if this site should be backed up based on cascading logic
    should_backup=false
    case "$FREQUENCY" in
        monthly)
            # Monthly backs up ALL sites
            should_backup=true
            ;;
        weekly)
            # Weekly backs up daily and weekly sites
            if [ "$site_freq" = "daily" ] || [ "$site_freq" = "weekly" ]; then
                should_backup=true
            fi
            ;;
        daily)
            # Daily backs up only daily sites
            if [ "$site_freq" = "daily" ]; then
                should_backup=true
            fi
            ;;
    esac

    if [ "$should_backup" = true ]; then
        if backup_site "$domain"; then
            BACKUP_COUNT=$((BACKUP_COUNT + 1))
        else
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        fi
    fi
done

echo "========================================="
echo "Backup Complete"
echo "  Successfully backed up: ${BACKUP_COUNT} sites"
if [ $SKIPPED_COUNT -gt 0 ]; then
    echo "  Skipped (errors):       ${SKIPPED_COUNT} sites"
fi
echo "========================================="
echo ""

#=============================================================================
# CLEANUP OLD BACKUPS
#=============================================================================

echo "Cleaning up old backups..."

case "$FREQUENCY" in
    daily)
        echo "Removing daily backups older than 31 days..."
        sudo find "$BACKUP_ROOT" -name "*_daily_*" -type f -mtime +31 -delete 2>/dev/null || true
        ;;
    weekly)
        echo "Removing weekly backups older than 91 days..."
        sudo find "$BACKUP_ROOT" -name "*_weekly_*" -type f -mtime +91 -delete 2>/dev/null || true
        ;;
    monthly)
        echo "Removing monthly backups older than 366 days..."
        sudo find "$BACKUP_ROOT" -name "*_monthly_*" -type f -mtime +366 -delete 2>/dev/null || true
        ;;
esac

echo "Cleanup complete"
echo ""
