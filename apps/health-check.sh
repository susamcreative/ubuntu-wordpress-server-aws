#!/bin/bash
#
# WordPress Health Check - Monitor server and site health
#
# USAGE:
#   ./apps/health-check.sh              # Run full health check
#   ./apps/health-check.sh --quiet      # Only output issues
#   ./apps/health-check.sh --force      # Force webhook notification
#
# DESCRIPTION:
#   Monitors system health, SSL certificates, site availability, and backups.
#   Sends webhook notifications when issues are detected.
#
# WHAT IT MONITORS:
#   System Level:
#     • Disk space (/, /var, /tmp) - Warn: 80%, Critical: 90%
#     • MySQL service status and connectivity
#     • Nginx service status and config validity
#     • PHP-FPM service status (auto-detects version)
#     • Redis service status and connectivity
#
#   Site Level (per WordPress site):
#     • HTTP availability (200/301/302 responses)
#     • SSL certificate expiration - Warn: 30 days, Critical: 7 days
#     • Backup freshness (based on configured frequency)
#     • Error log entries (last 24h) - Warn: 10+, Critical: 50+
#     • Database connectivity
#
#   Certbot & Backups:
#     • SSL renewal failures (parse certbot logs)
#     • Backup cron job execution status
#
# WEBHOOK INTEGRATION:
#   Set WEBHOOK_URL to receive JSON notifications of issues.
#   Works with Make.com, Zapier, n8n, or custom endpoints.
#
#   Example webhook payload:
#   {
#     "timestamp": "2025-01-17T14:30:00Z",
#     "hostname": "web-server-01",
#     "level": "WARNING",
#     "summary": "3 issues detected",
#     "issues": [
#       {
#         "id": "disk_var_critical",
#         "category": "disk",
#         "severity": "critical",
#         "resource": "/var",
#         "message": "Disk usage at 92%",
#         "details": {...},
#         "action": "Clean up old files or expand storage"
#       }
#     ]
#   }
#
# ALERT THROTTLING:
#   Same alerts won't be sent more than once per ALERT_THROTTLE_HOURS.
#   Alerts are re-sent if severity increases (warning → critical).
#   State tracked in the app user's logs/.health-check-alerts file
#
# CRON SETUP:
#   0 * * * * cd /home/user/apps && /bin/bash ./health-check.sh >> /home/user/logs/health-check.log 2>&1
#
# REQUIREMENTS:
#   - WordPress sites in ~/www/
#   - Access to system service status (systemctl)
#   - Access to /etc/letsencrypt/ for SSL certificates
#   - curl for webhook notifications
#
# EXAMPLES:
#   ~/apps/health-check.sh              # Full check with console output
#   ~/apps/health-check.sh --quiet      # Only show issues
#   ~/apps/health-check.sh --force      # Send webhook even if all OK
#

set -euo pipefail

#=============================================================================
# CONFIGURATION
#=============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
APP_OWNER="$(stat -c '%U:%G' "$APP_HOME")"
APP_USER="${APP_OWNER%%:*}"

WEB_ROOT="${APP_HOME}/www"
BACKUP_ROOT="${APP_HOME}/backups"
LOGS_ROOT="${APP_HOME}/logs"
LOG_FILE="${LOGS_ROOT}/health-check.log"
ALERT_STATE_FILE="${LOGS_ROOT}/.health-check-alerts"

# Webhook URL for notifications (leave empty to disable)
WEBHOOK_URL=""

# Certbot log location (configurable)
CERTBOT_LOG="/var/log/letsencrypt/letsencrypt.log"

# Alert thresholds
DISK_WARN_THRESHOLD=80
DISK_CRIT_THRESHOLD=90
SSL_WARN_DAYS=30
SSL_CRIT_DAYS=7
BACKUP_WARN_HOURS_DAILY=36      # Warn if daily backup > 36h old
BACKUP_WARN_HOURS_WEEKLY=192    # Warn if weekly backup > 8 days old
BACKUP_WARN_HOURS_MONTHLY=792   # Warn if monthly backup > 33 days old
ERROR_WARN_COUNT=10
ERROR_CRIT_COUNT=50

# Alert throttling (hours) - same alert won't be sent within this period
ALERT_THROTTLE_HOURS=24

# Colors for console output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Runtime flags
QUIET_MODE=false
FORCE_WEBHOOK=false

#=============================================================================
# LOGGING
#=============================================================================

log_operation() {
    mkdir -p "$LOGS_ROOT" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null || true
    if [ "$(id -u)" -eq 0 ] && [ "$APP_USER" != "root" ]; then
        chown "$APP_OWNER" "$LOGS_ROOT" "$LOG_FILE" 2>/dev/null || true
    fi
}

#=============================================================================
# ALERT THROTTLING
#=============================================================================

generate_alert_id() {
    local category=$1
    local resource=$2
    echo "${category}_${resource}" | tr '.' '_' | tr '/' '_' | tr ' ' '_' | tr -d '"'
}

should_send_alert() {
    local alert_id=$1
    local severity=$2

    # Always send if webhook not configured
    [ -z "$WEBHOOK_URL" ] && return 1

    # Create state file if doesn't exist
    touch "$ALERT_STATE_FILE" 2>/dev/null || return 0
    if [ "$(id -u)" -eq 0 ] && [ "$APP_USER" != "root" ]; then
        chown "$APP_OWNER" "$ALERT_STATE_FILE" 2>/dev/null || true
    fi

    # Check if alert exists
    local existing=$(grep "^${alert_id}|" "$ALERT_STATE_FILE" 2>/dev/null || echo "")

    # New alert - send it
    [ -z "$existing" ] && return 0

    # Parse existing alert
    local old_timestamp=$(echo "$existing" | cut -d'|' -f2)
    local old_severity=$(echo "$existing" | cut -d'|' -f3)
    local now=$(date +%s)
    local hours_since=$(( ($now - $old_timestamp) / 3600 ))

    # Send if severity increased (warning -> critical)
    if [ "$severity" = "critical" ] && [ "$old_severity" = "warning" ]; then
        return 0
    fi

    # Send if outside throttle window
    [ $hours_since -ge $ALERT_THROTTLE_HOURS ] && return 0

    # Otherwise throttle (skip)
    return 1
}

record_alert() {
    local alert_id=$1
    local severity=$2
    local now=$(date +%s)

    # Remove old entry
    sed -i "/^${alert_id}|/d" "$ALERT_STATE_FILE" 2>/dev/null || true

    # Add new entry
    echo "${alert_id}|${now}|${severity}" >> "$ALERT_STATE_FILE" 2>/dev/null || true
}

#=============================================================================
# SERVICE DETECTION
#=============================================================================

detect_php_fpm_service() {
    # Strategy 1: Check nginx global config
    if [ -f "/etc/nginx/global/php-pool.conf" ]; then
        local socket=$(grep "server unix:" "/etc/nginx/global/php-pool.conf" 2>/dev/null | grep -oP "php\d+\.\d+" | head -1)
        if [ -n "$socket" ]; then
            echo "$socket-fpm"
            return 0
        fi
    fi

    # Strategy 2: Check running services
    local running=$(systemctl list-units --type=service --state=running 2>/dev/null | grep -oP "php\d+\.\d+-fpm" | head -1)
    if [ -n "$running" ]; then
        echo "$running"
        return 0
    fi

    # Strategy 3: Check installed services
    local installed=$(systemctl list-unit-files 2>/dev/null | grep -oP "php\d+\.\d+-fpm" | head -1)
    if [ -n "$installed" ]; then
        echo "$installed"
        return 0
    fi

    echo "php-fpm"  # Generic fallback
}

detect_certbot_log() {
    # Check configured location first
    if [ -f "$CERTBOT_LOG" ]; then
        echo "$CERTBOT_LOG"
        return 0
    fi

    # Common alternative locations
    local locations=(
        "/var/log/letsencrypt/letsencrypt.log"
        "/var/log/certbot/certbot.log"
    )

    for loc in "${locations[@]}"; do
        if [ -f "$loc" ]; then
            echo "$loc"
            return 0
        fi
    done

    echo ""  # Not found
}

#=============================================================================
# SYSTEM HEALTH CHECKS
#=============================================================================

check_disk_space() {
    local issues=()
    local mounts=("/" "/var" "/tmp")

    for mount in "${mounts[@]}"; do
        # Get disk usage percentage
        local usage=$(df -h "$mount" 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//')

        if [ -z "$usage" ]; then
            continue
        fi

        local severity=""
        local message=""
        local action=""

        if [ "$usage" -ge "$DISK_CRIT_THRESHOLD" ]; then
            severity="critical"
            message="Disk usage at ${usage}%"
            action="Clean up old files or expand storage"
        elif [ "$usage" -ge "$DISK_WARN_THRESHOLD" ]; then
            severity="warning"
            message="Disk usage at ${usage}%"
            action="Monitor disk usage, consider cleanup"
        else
            continue
        fi

        # Get disk details
        local df_output=$(df -h "$mount" 2>/dev/null | tail -1)
        local used=$(echo "$df_output" | awk '{print $3}')
        local total=$(echo "$df_output" | awk '{print $2}')

        local alert_id=$(generate_alert_id "disk" "${mount}")

        if should_send_alert "$alert_id" "$severity"; then
            local issue=$(cat <<EOF
{
  "id": "${alert_id}",
  "category": "disk",
  "severity": "${severity}",
  "resource": "${mount}",
  "message": "${message}",
  "details": {
    "used": "${used}",
    "total": "${total}",
    "percent": ${usage}
  },
  "action": "${action}"
}
EOF
)
            issues+=("$issue")
            record_alert "$alert_id" "$severity"
        fi
    done

    # Return issues as JSON array
    if [ ${#issues[@]} -gt 0 ]; then
        local IFS=","
        echo "[${issues[*]}]"
    else
        echo "[]"
    fi
}

check_mysql_service() {
    local issues=()

    # Check if MySQL service is running
    if ! systemctl is-active --quiet mysql 2>/dev/null && ! systemctl is-active --quiet mariadb 2>/dev/null; then
        local alert_id=$(generate_alert_id "service" "mysql")

        if should_send_alert "$alert_id" "critical"; then
            local issue=$(cat <<EOF
{
  "id": "${alert_id}",
  "category": "service",
  "severity": "critical",
  "resource": "mysql",
  "message": "MySQL service not running",
  "details": {
    "service": "mysql/mariadb",
    "status": "stopped"
  },
  "action": "Start MySQL service: systemctl start mysql"
}
EOF
)
            issues+=("$issue")
            record_alert "$alert_id" "critical"
        fi
    fi

    # Return issues as JSON array
    if [ ${#issues[@]} -gt 0 ]; then
        local IFS=","
        echo "[${issues[*]}]"
    else
        echo "[]"
    fi
}

check_nginx_service() {
    local issues=()

    # Check if Nginx service is running
    if ! systemctl is-active --quiet nginx 2>/dev/null; then
        local alert_id=$(generate_alert_id "service" "nginx")

        if should_send_alert "$alert_id" "critical"; then
            local issue=$(cat <<EOF
{
  "id": "${alert_id}",
  "category": "service",
  "severity": "critical",
  "resource": "nginx",
  "message": "Nginx service not running",
  "details": {
    "service": "nginx",
    "status": "stopped"
  },
  "action": "Start Nginx service: systemctl start nginx"
}
EOF
)
            issues+=("$issue")
            record_alert "$alert_id" "critical"
        fi
    else
        # Test nginx config
        if ! sudo nginx -t &>/dev/null; then
            local alert_id=$(generate_alert_id "service" "nginx_config")

            if should_send_alert "$alert_id" "critical"; then
                local issue=$(cat <<EOF
{
  "id": "${alert_id}",
  "category": "service",
  "severity": "critical",
  "resource": "nginx",
  "message": "Nginx configuration test failed",
  "details": {
    "service": "nginx",
    "status": "running",
    "config_test": "failed"
  },
  "action": "Check nginx configuration: nginx -t"
}
EOF
)
                issues+=("$issue")
                record_alert "$alert_id" "critical"
            fi
        fi
    fi

    # Return issues as JSON array
    if [ ${#issues[@]} -gt 0 ]; then
        local IFS=","
        echo "[${issues[*]}]"
    else
        echo "[]"
    fi
}

check_php_fpm_service() {
    local issues=()
    local php_service=$(detect_php_fpm_service)

    # Check if PHP-FPM service is running
    if ! systemctl is-active --quiet "$php_service" 2>/dev/null; then
        local alert_id=$(generate_alert_id "service" "php_fpm")

        if should_send_alert "$alert_id" "critical"; then
            local issue=$(cat <<EOF
{
  "id": "${alert_id}",
  "category": "service",
  "severity": "critical",
  "resource": "php-fpm",
  "message": "PHP-FPM service not running",
  "details": {
    "service": "${php_service}",
    "status": "stopped"
  },
  "action": "Start PHP-FPM service: systemctl start ${php_service}"
}
EOF
)
            issues+=("$issue")
            record_alert "$alert_id" "critical"
        fi
    fi

    # Return issues as JSON array
    if [ ${#issues[@]} -gt 0 ]; then
        local IFS=","
        echo "[${issues[*]}]"
    else
        echo "[]"
    fi
}

check_redis_service() {
    local issues=()

    # Check if Redis is installed
    if ! command -v redis-cli &>/dev/null; then
        return  # Redis not installed, skip check
    fi

    # Check Redis connectivity
    if ! redis-cli ping 2>/dev/null | grep -q "PONG"; then
        local alert_id=$(generate_alert_id "service" "redis")

        if should_send_alert "$alert_id" "warning"; then
            local issue=$(cat <<EOF
{
  "id": "${alert_id}",
  "category": "service",
  "severity": "warning",
  "resource": "redis",
  "message": "Redis not responding to ping",
  "details": {
    "service": "redis",
    "connectivity": "failed"
  },
  "action": "Check Redis service: systemctl status redis"
}
EOF
)
            issues+=("$issue")
            record_alert "$alert_id" "warning"
        fi
    fi

    # Return issues as JSON array
    if [ ${#issues[@]} -gt 0 ]; then
        local IFS=","
        echo "[${issues[*]}]"
    else
        echo "[]"
    fi
}

#=============================================================================
# SITE HEALTH CHECKS (duplicated from list-sites.sh for independence)
#=============================================================================

get_http_status() {
    local domain=$1

    # Try HTTPS first
    local status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "https://${domain}" 2>/dev/null || echo "000")

    # If HTTPS fails, try HTTP
    if [ "$status" = "000" ]; then
        status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "http://${domain}" 2>/dev/null || echo "000")
    fi

    if [ "$status" = "200" ] || [ "$status" = "301" ] || [ "$status" = "302" ]; then
        echo "UP"
    else
        echo "DOWN"
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
        local expiry_date=$(sudo openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
        local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
        local now_epoch=$(date +%s)
        local days_left=$(( ($expiry_epoch - $now_epoch) / 86400 ))
        echo "$days_left"
    else
        echo "-1"  # No SSL
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
        sudo openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2 | xargs -I{} date -d "{}" '+%Y-%m-%d' 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

get_backup_frequency() {
    local domain=$1
    local backup_script="${APP_HOME}/apps/backup.sh"

    if [ ! -f "$backup_script" ]; then
        echo "none"
        return
    fi

    local frequency=$(grep "\"${domain}:" "$backup_script" 2>/dev/null | sed 's/.*"\(.*\):\(.*\)".*/\2/' | tr -d '[:space:]')

    if [ -n "$frequency" ]; then
        echo "$frequency"
    else
        echo "none"
    fi
}

get_last_backup_hours() {
    local domain=$1
    local backup_dir="${BACKUP_ROOT}/${domain}"

    if [ ! -d "$backup_dir" ]; then
        echo "-1"
        return
    fi

    local last_backup=$(find "$backup_dir" -name "*.tar.gz" -type f -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1)

    if [ -z "$last_backup" ]; then
        echo "-1"
        return
    fi

    local backup_epoch=$(echo "$last_backup" | cut -d' ' -f1 | cut -d. -f1)
    local now_epoch=$(date +%s)
    local hours_ago=$(( ($now_epoch - $backup_epoch) / 3600 ))
    echo "$hours_ago"
}

get_error_count() {
    local domain=$1
    local error_log="${LOGS_ROOT}/${domain}.error.log"

    if [ ! -f "$error_log" ]; then
        echo "0"
        return
    fi

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

    local dbname=$(grep "DB_NAME" "$wp_config" 2>/dev/null | cut -d "'" -f 4)
    local dbuser=$(grep "DB_USER" "$wp_config" 2>/dev/null | cut -d "'" -f 4)
    local dbpass=$(grep "DB_PASSWORD" "$wp_config" 2>/dev/null | cut -d "'" -f 4)

    echo "$dbname $dbuser $dbpass"
}

check_site_health() {
    local domain=$1
    local site_path="${WEB_ROOT}/${domain}"
    local issues=()

    # Check HTTP status
    local http_status=$(get_http_status "$domain")
    if [ "$http_status" = "DOWN" ]; then
        local alert_id=$(generate_alert_id "http" "$domain")

        if should_send_alert "$alert_id" "critical"; then
            local issue=$(cat <<EOF
{
  "id": "${alert_id}",
  "category": "http",
  "severity": "critical",
  "site": "${domain}",
  "message": "Site is not responding",
  "details": {
    "http_status": "DOWN"
  },
  "action": "Check nginx configuration and site files"
}
EOF
)
            issues+=("$issue")
            record_alert "$alert_id" "critical"
        fi
    fi

    # Check SSL expiration
    local ssl_days=$(get_ssl_days "$domain")
    if [ "$ssl_days" -ge 0 ]; then
        local severity=""
        local message=""
        local action=""

        if [ "$ssl_days" -le "$SSL_CRIT_DAYS" ]; then
            severity="critical"
            message="SSL certificate expires in ${ssl_days} days"
            action="Renew certificate immediately: certbot renew --cert-name ${domain}"
        elif [ "$ssl_days" -le "$SSL_WARN_DAYS" ]; then
            severity="warning"
            message="SSL certificate expires in ${ssl_days} days"
            action="Monitor certbot auto-renewal or renew manually"
        fi

        if [ -n "$severity" ]; then
            local expiry_date=$(get_ssl_expiry_date "$domain")
            local alert_id=$(generate_alert_id "ssl" "$domain")

            if should_send_alert "$alert_id" "$severity"; then
                local issue=$(cat <<EOF
{
  "id": "${alert_id}",
  "category": "ssl",
  "severity": "${severity}",
  "site": "${domain}",
  "message": "${message}",
  "details": {
    "days_remaining": ${ssl_days},
    "expiry_date": "${expiry_date}"
  },
  "action": "${action}"
}
EOF
)
                issues+=("$issue")
                record_alert "$alert_id" "$severity"
            fi
        fi
    fi

    # Check backup freshness
    local backup_freq=$(get_backup_frequency "$domain")
    local backup_hours=$(get_last_backup_hours "$domain")

    if [ "$backup_freq" != "none" ] && [ "$backup_hours" -ge 0 ]; then
        local threshold=0
        case "$backup_freq" in
            daily)
                threshold=$BACKUP_WARN_HOURS_DAILY
                ;;
            weekly)
                threshold=$BACKUP_WARN_HOURS_WEEKLY
                ;;
            monthly)
                threshold=$BACKUP_WARN_HOURS_MONTHLY
                ;;
        esac

        if [ "$backup_hours" -gt "$threshold" ]; then
            local days=$(( $backup_hours / 24 ))
            local alert_id=$(generate_alert_id "backup" "$domain")

            if should_send_alert "$alert_id" "warning"; then
                local issue=$(cat <<EOF
{
  "id": "${alert_id}",
  "category": "backup",
  "severity": "warning",
  "site": "${domain}",
  "message": "Last backup ${days}d ago (expected ${backup_freq})",
  "details": {
    "last_backup_hours": ${backup_hours},
    "frequency": "${backup_freq}",
    "threshold_hours": ${threshold}
  },
  "action": "Check backup cron job and logs at ${LOGS_ROOT}/backup.log"
}
EOF
)
                issues+=("$issue")
                record_alert "$alert_id" "warning"
            fi
        fi
    fi

    # Check error count
    local error_count=$(get_error_count "$domain")
    if [ "$error_count" -gt 0 ]; then
        local severity=""
        local message=""
        local action=""

        if [ "$error_count" -ge "$ERROR_CRIT_COUNT" ]; then
            severity="critical"
            message="${error_count} errors in last 24h"
            action="Check error log: tail -f ${LOGS_ROOT}/${domain}.error.log"
        elif [ "$error_count" -ge "$ERROR_WARN_COUNT" ]; then
            severity="warning"
            message="${error_count} errors in last 24h"
            action="Review error log: ${LOGS_ROOT}/${domain}.error.log"
        fi

        if [ -n "$severity" ]; then
            local alert_id=$(generate_alert_id "errors" "$domain")

            if should_send_alert "$alert_id" "$severity"; then
                local issue=$(cat <<EOF
{
  "id": "${alert_id}",
  "category": "errors",
  "severity": "${severity}",
  "site": "${domain}",
  "message": "${message}",
  "details": {
    "error_count_24h": ${error_count}
  },
  "action": "${action}"
}
EOF
)
                issues+=("$issue")
                record_alert "$alert_id" "$severity"
            fi
        fi
    fi

    # Check database connectivity
    read dbname dbuser dbpass <<< $(get_db_credentials "$site_path")
    if [ "$dbname" != "N/A" ]; then
        if ! mysql -u"$dbuser" -p"${dbpass}" -e "USE ${dbname}; SELECT 1" &>/dev/null; then
            local alert_id=$(generate_alert_id "database" "$domain")

            if should_send_alert "$alert_id" "critical"; then
                local issue=$(cat <<EOF
{
  "id": "${alert_id}",
  "category": "database",
  "severity": "critical",
  "site": "${domain}",
  "message": "Cannot connect to database",
  "details": {
    "database": "${dbname}"
  },
  "action": "Check database credentials and MySQL service"
}
EOF
)
                issues+=("$issue")
                record_alert "$alert_id" "critical"
            fi
        fi
    fi

    # Return issues as JSON array
    if [ ${#issues[@]} -gt 0 ]; then
        local IFS=","
        echo "[${issues[*]}]"
    else
        echo "[]"
    fi
}

#=============================================================================
# CERTBOT & BACKUP CHECKS
#=============================================================================

check_certbot_renewal() {
    local issues=()
    local certbot_log=$(detect_certbot_log)

    if [ -z "$certbot_log" ]; then
        return  # No certbot log found, skip
    fi

    # Check for renewal failures in last 7 days
    local seven_days_ago=$(date -d '7 days ago' '+%Y-%m-%d')
    local failures=$(grep -A 5 "Failed to renew certificate" "$certbot_log" 2>/dev/null | grep -A 5 "$seven_days_ago" | grep "Failed to renew certificate" | wc -l)

    if [ "$failures" -gt 0 ]; then
        local alert_id=$(generate_alert_id "certbot" "renewal_failed")

        if should_send_alert "$alert_id" "critical"; then
            local issue=$(cat <<EOF
{
  "id": "${alert_id}",
  "category": "certbot",
  "severity": "critical",
  "resource": "ssl-renewal",
  "message": "SSL renewal failures detected (${failures} in last 7 days)",
  "details": {
    "failures_count": ${failures},
    "log_file": "${certbot_log}"
  },
  "action": "Check certbot logs: tail -100 ${certbot_log}"
}
EOF
)
            issues+=("$issue")
            record_alert "$alert_id" "critical"
        fi
    fi

    # Return issues as JSON array
    if [ ${#issues[@]} -gt 0 ]; then
        local IFS=","
        echo "[${issues[*]}]"
    else
        echo "[]"
    fi
}

check_backup_cron() {
    local issues=()
    local backup_log="${LOGS_ROOT}/backup.log"

    if [ ! -f "$backup_log" ]; then
        return  # No backup log, skip
    fi

    # Check if daily backup ran in last 30 hours.
    # backup.sh logs dates as YY.MM.DD_HH.MM because that timestamp is also used in archive names.
    local daily_raw=$(awk '
        /Backup Run: daily/ { in_daily = 1; next }
        in_daily && /^Date: / { print $2; in_daily = 0 }
    ' "$backup_log" 2>/dev/null | tail -1)

    if [ -n "$daily_raw" ]; then
        local daily_last="$daily_raw"
        if [[ "$daily_raw" =~ ^([0-9]{2})\.([0-9]{2})\.([0-9]{2})_([0-9]{2})\.([0-9]{2})$ ]]; then
            daily_last="20${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:00"
        fi

        local last_epoch=$(date -d "$daily_last" +%s 2>/dev/null || echo "0")
        local now_epoch=$(date +%s)
        local hours_since=$(( (now_epoch - last_epoch) / 3600 ))

        if [ "$last_epoch" -gt 0 ] && [ "$hours_since" -gt 30 ]; then
            local alert_id=$(generate_alert_id "cron" "backup_daily")

            if should_send_alert "$alert_id" "warning"; then
                local issue=$(cat <<EOF
{
  "id": "${alert_id}",
  "category": "cron",
  "severity": "warning",
  "resource": "backup-daily",
  "message": "Daily backup cron hasn't run in ${hours_since}h",
  "details": {
    "last_run": "${daily_last}",
    "hours_since": ${hours_since}
  },
  "action": "Check crontab: sudo crontab -l | grep backup"
}
EOF
)
                issues+=("$issue")
                record_alert "$alert_id" "warning"
            fi
        fi
    fi

    # Return issues as JSON array
    if [ ${#issues[@]} -gt 0 ]; then
        local IFS=","
        echo "[${issues[*]}]"
    else
        echo "[]"
    fi
}

#=============================================================================
# WEBHOOK FUNCTIONS
#=============================================================================

send_webhook() {
    local payload=$1

    if [ -z "$WEBHOOK_URL" ]; then
        return 0  # No webhook configured
    fi

    local response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$WEBHOOK_URL" 2>&1)

    if [ $? -eq 0 ]; then
        log_operation "Webhook sent successfully"
        return 0
    else
        log_operation "ERROR: Webhook failed - $response"
        return 1
    fi
}

merge_json_arrays() {
    # Merge multiple JSON arrays into one
    local merged="["
    local first=true

    for arr in "$@"; do
        # Skip empty arrays
        if [ "$arr" = "[]" ]; then
            continue
        fi

        # Remove brackets
        local items="${arr#[}"
        items="${items%]}"

        if [ -n "$items" ]; then
            if [ "$first" = true ]; then
                merged="${merged}${items}"
                first=false
            else
                merged="${merged},${items}"
            fi
        fi
    done

    merged="${merged}]"
    echo "$merged"
}

generate_webhook_payload() {
    local issues_json=$1
    local level=$2
    local summary=$3

    cat <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hostname": "$(hostname)",
  "level": "${level}",
  "summary": "${summary}",
  "issues": ${issues_json}
}
EOF
}

#=============================================================================
# CONSOLE OUTPUT
#=============================================================================

print_header() {
    if [ "$QUIET_MODE" = false ]; then
        echo "========================================="
        echo "WordPress Health Check"
        echo "========================================="
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Hostname: $(hostname)"
        echo ""
    fi
}

print_system_health() {
    local disk_issues=$1
    local mysql_issues=$2
    local nginx_issues=$3
    local php_issues=$4
    local redis_issues=$5

    if [ "$QUIET_MODE" = false ]; then
        echo "[SYSTEM HEALTH]"

        # Disk space
        for mount in "/" "/var" "/tmp"; do
            local usage=$(df -h "$mount" 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//')
            if [ -z "$usage" ]; then
                continue
            fi

            if [ "$usage" -ge "$DISK_CRIT_THRESHOLD" ]; then
                echo -e "  ${RED}✗ Disk Space ($mount):     ${usage}% used [CRITICAL]${NC}"
            elif [ "$usage" -ge "$DISK_WARN_THRESHOLD" ]; then
                echo -e "  ${YELLOW}⚠ Disk Space ($mount):     ${usage}% used [WARNING]${NC}"
            else
                echo -e "  ${GREEN}✓ Disk Space ($mount):     ${usage}% used${NC}"
            fi
        done

        # MySQL
        if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then
            echo -e "  ${GREEN}✓ MySQL Service:         Running${NC}"
        else
            echo -e "  ${RED}✗ MySQL Service:         Not running [CRITICAL]${NC}"
        fi

        # Nginx
        if systemctl is-active --quiet nginx 2>/dev/null; then
            if sudo nginx -t &>/dev/null; then
                echo -e "  ${GREEN}✓ Nginx Service:         Running${NC}"
            else
                echo -e "  ${RED}✗ Nginx Service:         Config test failed [CRITICAL]${NC}"
            fi
        else
            echo -e "  ${RED}✗ Nginx Service:         Not running [CRITICAL]${NC}"
        fi

        # PHP-FPM
        local php_service=$(detect_php_fpm_service)
        if systemctl is-active --quiet "$php_service" 2>/dev/null; then
            echo -e "  ${GREEN}✓ PHP-FPM Service:       Running ($php_service)${NC}"
        else
            echo -e "  ${RED}✗ PHP-FPM Service:       Not running [CRITICAL]${NC}"
        fi

        # Redis
        if command -v redis-cli &>/dev/null; then
            if redis-cli ping 2>/dev/null | grep -q "PONG"; then
                echo -e "  ${GREEN}✓ Redis Service:         Running${NC}"
            else
                echo -e "  ${YELLOW}⚠ Redis Service:         Not responding [WARNING]${NC}"
            fi
        fi

        echo ""
    fi
}

print_site_health() {
    local domain=$1
    local http_status=$(get_http_status "$domain")
    local ssl_days=$(get_ssl_days "$domain")
    local backup_hours=$(get_last_backup_hours "$domain")
    local backup_freq=$(get_backup_frequency "$domain")
    local error_count=$(get_error_count "$domain")

    if [ "$QUIET_MODE" = false ]; then
        echo "[SITE: $domain]"

        # HTTP status
        if [ "$http_status" = "UP" ]; then
            echo -e "  ${GREEN}✓ HTTP Status:           UP${NC}"
        else
            echo -e "  ${RED}✗ HTTP Status:           DOWN [CRITICAL]${NC}"
        fi

        # SSL
        if [ "$ssl_days" -ge 0 ]; then
            local expiry_date=$(get_ssl_expiry_date "$domain")
            if [ "$ssl_days" -le "$SSL_CRIT_DAYS" ]; then
                echo -e "  ${RED}✗ SSL Expires:           ${ssl_days} days ($expiry_date) [CRITICAL]${NC}"
            elif [ "$ssl_days" -le "$SSL_WARN_DAYS" ]; then
                echo -e "  ${YELLOW}⚠ SSL Expires:           ${ssl_days} days ($expiry_date) [WARNING]${NC}"
            else
                echo -e "  ${GREEN}✓ SSL Expires:           ${ssl_days} days ($expiry_date)${NC}"
            fi
        else
            echo -e "  ${CYAN}  SSL:                   Not configured${NC}"
        fi

        # Backup
        if [ "$backup_freq" != "none" ] && [ "$backup_hours" -ge 0 ]; then
            local days=$(( $backup_hours / 24 ))
            local threshold=0
            case "$backup_freq" in
                daily) threshold=$BACKUP_WARN_HOURS_DAILY ;;
                weekly) threshold=$BACKUP_WARN_HOURS_WEEKLY ;;
                monthly) threshold=$BACKUP_WARN_HOURS_MONTHLY ;;
            esac

            if [ "$backup_hours" -gt "$threshold" ]; then
                echo -e "  ${YELLOW}⚠ Last Backup:           ${days}d ago (expected $backup_freq) [WARNING]${NC}"
            else
                echo -e "  ${GREEN}✓ Last Backup:           ${days}d ago${NC}"
            fi
        else
            echo -e "  ${CYAN}  Last Backup:           Not configured${NC}"
        fi

        # Errors
        if [ "$error_count" -ge "$ERROR_CRIT_COUNT" ]; then
            echo -e "  ${RED}✗ Error Count (24h):     ${error_count} errors [CRITICAL]${NC}"
        elif [ "$error_count" -ge "$ERROR_WARN_COUNT" ]; then
            echo -e "  ${YELLOW}⚠ Error Count (24h):     ${error_count} errors [WARNING]${NC}"
        else
            echo -e "  ${GREEN}✓ Error Count (24h):     ${error_count} errors${NC}"
        fi

        # Database
        local site_path="${WEB_ROOT}/${domain}"
        read dbname dbuser dbpass <<< $(get_db_credentials "$site_path")
        if [ "$dbname" != "N/A" ]; then
            if mysql -u"$dbuser" -p"${dbpass}" -e "USE ${dbname}; SELECT 1" &>/dev/null; then
                echo -e "  ${GREEN}✓ Database:              Connected${NC}"
            else
                echo -e "  ${RED}✗ Database:              Cannot connect [CRITICAL]${NC}"
            fi
        fi

        echo ""
    fi
}

print_summary() {
    local total_issues=$1
    local critical_count=$2
    local warning_count=$3
    local webhook_sent=$4
    local throttled_count=$5

    if [ "$QUIET_MODE" = false ]; then
        echo "========================================="
        if [ "$total_issues" -eq 0 ]; then
            echo -e "${GREEN}Summary: All systems healthy${NC}"
        else
            echo -e "${BOLD}Summary: ${total_issues} issues detected${NC}"
            if [ "$critical_count" -gt 0 ]; then
                echo -e "  ${RED}Critical: ${critical_count}${NC}"
            fi
            if [ "$warning_count" -gt 0 ]; then
                echo -e "  ${YELLOW}Warning: ${warning_count}${NC}"
            fi
        fi
        echo "========================================="

        if [ -n "$WEBHOOK_URL" ]; then
            if [ "$webhook_sent" = true ]; then
                echo "Webhook: Alert sent"
            else
                echo "Webhook: No new alerts to send"
            fi

            if [ "$throttled_count" -gt 0 ]; then
                echo "Throttled: ${throttled_count} alerts skipped (recently sent)"
            fi
        fi

        echo ""
    fi
}

#=============================================================================
# MAIN
#=============================================================================

main() {
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --quiet)
                QUIET_MODE=true
                shift
                ;;
            --force)
                FORCE_WEBHOOK=true
                shift
                ;;
            *)
                echo "Unknown option: $1"
                echo "Usage: $0 [--quiet] [--force]"
                exit 1
                ;;
        esac
    done

    log_operation "=== Starting health check ==="

    # Print header
    print_header

    # Collect all issues
    local all_issues=()

    # System health checks
    local disk_issues=$(check_disk_space)
    local mysql_issues=$(check_mysql_service)
    local nginx_issues=$(check_nginx_service)
    local php_issues=$(check_php_fpm_service)
    local redis_issues=$(check_redis_service)

    all_issues+=("$disk_issues" "$mysql_issues" "$nginx_issues" "$php_issues" "$redis_issues")

    # Print system health
    print_system_health "$disk_issues" "$mysql_issues" "$nginx_issues" "$php_issues" "$redis_issues"

    # Site health checks
    if [ -d "$WEB_ROOT" ]; then
        for site_dir in "$WEB_ROOT"/*/ ; do
            if [ -d "$site_dir" ] && [ -f "${site_dir}/wp-config.php" ]; then
                local domain=$(basename "$site_dir")
                local site_issues=$(check_site_health "$domain")
                all_issues+=("$site_issues")

                # Print site health
                print_site_health "$domain"
            fi
        done
    fi

    # Certbot and backup checks
    local certbot_issues=$(check_certbot_renewal)
    local backup_cron_issues=$(check_backup_cron)
    all_issues+=("$certbot_issues" "$backup_cron_issues")

    # Merge all issues
    local merged_issues=$(merge_json_arrays "${all_issues[@]}")

    # Count issues
    local total_issues=$(echo "$merged_issues" | grep -o '"id":' | wc -l)
    local critical_count=$(echo "$merged_issues" | grep -o '"severity": "critical"' | wc -l)
    local warning_count=$(echo "$merged_issues" | grep -o '"severity": "warning"' | wc -l)

    # Determine alert level
    local level="INFO"
    if [ "$critical_count" -gt 0 ]; then
        level="CRITICAL"
    elif [ "$warning_count" -gt 0 ]; then
        level="WARNING"
    fi

    # Generate summary
    local summary="All systems healthy"
    if [ "$total_issues" -gt 0 ]; then
        summary="${total_issues} issues detected"
    fi

    # Send webhook if issues found or forced
    local webhook_sent=false
    if [ -n "$WEBHOOK_URL" ]; then
        if [ "$total_issues" -gt 0 ] || [ "$FORCE_WEBHOOK" = true ]; then
            local payload=$(generate_webhook_payload "$merged_issues" "$level" "$summary")
            send_webhook "$payload"
            webhook_sent=true
            log_operation "Webhook notification sent - Level: $level, Issues: $total_issues"
        fi
    fi

    # Count throttled alerts (issues detected but not in webhook)
    local all_issues_count=$(echo "$merged_issues" | grep -o '"id":' | wc -l)
    local throttled_count=0

    # Print summary
    print_summary "$total_issues" "$critical_count" "$warning_count" "$webhook_sent" "$throttled_count"

    log_operation "Health check completed - Issues: $total_issues (Critical: $critical_count, Warning: $warning_count)"
}

main "$@"
