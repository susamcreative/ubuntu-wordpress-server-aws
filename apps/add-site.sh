#!/bin/bash
#
# Add WordPress Site - Automated WordPress site creation script
#
# USAGE:
#   ./apps/add-site.sh
#
# DESCRIPTION:
#   Creates a new WordPress site with database, nginx config, and SSL certificate.
#   Includes validation, error handling, and resumable workflow.
#
# WHAT IT DOES:
#   1. Validates prerequisites (nginx, MySQL, PHP, templates)
#   2. Prompts for MySQL root password (not stored)
#   3. Checks DNS with retry loop (offers HTTP-only if not ready)
#   4. Creates directories, database, downloads WordPress
#   5. Configures wp-config.php with security keys
#   6. Sets proper permissions
#   7. Creates nginx configuration from template
#   8. Obtains SSL certificate (optional, doesn't fail if DNS not ready)
#   9. Sets up automated backups (daily/weekly/monthly)
#
# FILES CREATED:
#   ~/.add-site-credentials.txt  - Site credentials (MUST DELETE after copying)
#   ~/.add-site.state            - Temporary state (auto-deleted on success)
#   /tmp/.add-site.lock          - Lock file (auto-deleted on exit)
#
# RESUME FUNCTIONALITY:
#   If interrupted, run script again - it will detect incomplete state
#   and offer to resume or start fresh with automatic rollback.
#
# SECURITY NOTES:
#   - MySQL password is prompted each time, never stored
#   - Credentials saved to ~/.add-site-credentials.txt (chmod 600)
#   - YOU MUST DELETE credentials file after copying: rm ~/.add-site-credentials.txt
#   - State file contains sensitive data, auto-deleted on completion
#
# REQUIREMENTS:
#   - LEMP stack installed (nginx, PHP, MariaDB, Redis)
#   - Nginx templates uploaded to /etc/nginx/sites-available/
#   - Directory structure: ~/www, ~/cache, ~/logs, ~/backups
#   - Certbot installed for SSL (optional)
#
# EXAMPLES:
#   # Normal usage
#   ~/apps/add-site.sh
#
#   # If interrupted, run again to resume
#   ~/apps/add-site.sh
#
#   # Clean up manually if needed
#   rm ~/.add-site.state ~/.add-site-credentials.txt

set -euo pipefail

#=============================================================================
# CONFIGURATION
#=============================================================================

USER=$(whoami)
WEB_ROOT="/home/${USER}/www"
CACHE_ROOT="/home/${USER}/cache"
LOGS_ROOT="/home/${USER}/logs"

STATE_FILE="$HOME/.add-site.state"
CREDS_FILE="$HOME/.add-site-credentials.txt"
LOCKFILE="/tmp/.add-site.lock"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

#=============================================================================
# HELPER FUNCTIONS
#=============================================================================

state_is_complete() {
    local flag=$1
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
        [[ "${!flag}" == "true" ]]
    else
        return 1
    fi
}

update_state() {
    local key=$1
    local value=$2
    if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
        sed -i "s/^${key}=.*/${key}=\"${value}\"/" "$STATE_FILE"
    else
        echo "${key}=\"${value}\"" >> "$STATE_FILE"
    fi
}

validate_domain() {
    local domain=$1

    if [[ ! "$domain" =~ ^[a-z0-9.-]+\.[a-z]+$ ]]; then
        echo -e "${RED}Invalid format. Use lowercase, numbers, dots, hyphens only${NC}"
        return 1
    fi

    if [ -d "${WEB_ROOT}/${domain}" ]; then
        echo -e "${RED}Site already exists: ${WEB_ROOT}/${domain}${NC}"
        return 1
    fi

    return 0
}

validate_dbname() {
    local name=$1

    if [ ${#name} -gt 64 ]; then
        echo -e "${RED}Too long (max 64 characters)${NC}"
        return 1
    fi

    if [[ ! "$name" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo -e "${RED}Use only letters, numbers, underscore${NC}"
        return 1
    fi

    if mysql -p"${MYSQL_PASS}" -e "USE ${name}" 2>/dev/null; then
        echo -e "${RED}Database already exists${NC}"
        return 1
    fi

    return 0
}

validate_dbuser() {
    local user=$1

    if [ ${#user} -gt 32 ]; then
        echo -e "${RED}Too long (max 32 characters)${NC}"
        return 1
    fi

    if [[ ! "$user" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo -e "${RED}Use only letters, numbers, underscore${NC}"
        return 1
    fi

    return 0
}

rollback_all() {
    echo ""
    echo "Rolling back ${STATE_DOMAIN}..."

    source "$STATE_FILE"

    # Remove backup configuration
    if [[ "${STATE_BACKUP_CREATED:-false}" == "true" ]]; then
        rm -f "/home/${USER}/apps/backup/site-${STATE_DOMAIN}.sh"
        rm -rf "/home/${USER}/backups/${STATE_DOMAIN}"
        # Remove from backup schedule files
        sed -i "\|/home/${USER}/apps/backup/site-${STATE_DOMAIN}.sh|d" "/home/${USER}/apps/backup/backup-daily.sh" 2>/dev/null || true
        sed -i "\|/home/${USER}/apps/backup/site-${STATE_DOMAIN}.sh|d" "/home/${USER}/apps/backup/backup-weekly.sh" 2>/dev/null || true
        sed -i "\|/home/${USER}/apps/backup/site-${STATE_DOMAIN}.sh|d" "/home/${USER}/apps/backup/backup-monthly.sh" 2>/dev/null || true
    fi

    # Remove nginx config
    if [[ "${STATE_NGINX_CREATED:-false}" == "true" ]]; then
        sudo rm -f "/etc/nginx/sites-enabled/${STATE_DOMAIN}"
        sudo rm -f "/etc/nginx/sites-available/${STATE_DOMAIN}.conf"
        sudo nginx -t &>/dev/null && sudo service nginx reload &>/dev/null || true
    fi

    # Remove files
    if [[ "${STATE_DIRS_CREATED:-false}" == "true" ]]; then
        rm -rf "${WEB_ROOT}/${STATE_DOMAIN}"
        rm -rf "${CACHE_ROOT}/${STATE_DOMAIN}"
    fi

    # Drop database
    if [[ "${STATE_DB_CREATED:-false}" == "true" ]]; then
        mysql -p"${MYSQL_PASS}" -e "DROP DATABASE IF EXISTS ${STATE_DBNAME};" 2>/dev/null || true
        mysql -p"${MYSQL_PASS}" -e "DROP USER IF EXISTS '${STATE_DBUSER}'@'localhost';" 2>/dev/null || true
    fi

    rm -f "$STATE_FILE" "$CREDS_FILE"

    echo -e "${GREEN}✓ Rollback complete${NC}"
}

#=============================================================================
# STEP FUNCTIONS
#=============================================================================

check_prerequisites() {
    echo "Checking prerequisites..."
    local errors=0

    # Check nginx
    if ! command -v nginx &>/dev/null; then
        echo -e "${RED}✗ Nginx not installed${NC}"
        errors=$((errors + 1))
    else
        echo -e "${GREEN}✓ Nginx${NC}"
    fi

    # Check MySQL
    if ! command -v mysql &>/dev/null; then
        echo -e "${RED}✗ MySQL/MariaDB not installed${NC}"
        errors=$((errors + 1))
    else
        echo -e "${GREEN}✓ MySQL/MariaDB${NC}"
    fi

    # Check PHP
    if ! command -v php &>/dev/null; then
        echo -e "${RED}✗ PHP not installed${NC}"
        errors=$((errors + 1))
    else
        echo -e "${GREEN}✓ PHP${NC}"
    fi

    # Check directories
    for dir in www cache logs backups; do
        if [ ! -d "/home/${USER}/${dir}" ]; then
            echo -e "${RED}✗ Directory missing: ~/${dir}${NC}"
            errors=$((errors + 1))
        fi
    done

    if [ $errors -eq 0 ]; then
        echo -e "${GREEN}✓ Required directories${NC}"
    fi

    # Check nginx templates
    local templates_found=0
    for tpl in template.conf template_no_caching.conf template_no_ssl.conf; do
        [ -f "/etc/nginx/sites-available/${tpl}" ] && templates_found=$((templates_found + 1))
    done

    if [ $templates_found -eq 0 ]; then
        echo -e "${RED}✗ No nginx templates found${NC}"
        echo "  Upload nginx configs from repo to /etc/nginx/"
        errors=$((errors + 1))
    else
        echo -e "${GREEN}✓ Nginx templates${NC}"
    fi

    if [ $errors -gt 0 ]; then
        echo ""
        echo -e "${RED}ERROR: Prerequisites not met${NC}"
        exit 1
    fi

    echo ""
}

setup_mysql_auth() {
    echo "MySQL root authentication required"
    read -sp "Enter MySQL root password: " MYSQL_PASS
    echo ""

    # Test connection
    if ! mysql -p"${MYSQL_PASS}" -e "SELECT 1" &>/dev/null; then
        echo -e "${RED}ERROR: MySQL authentication failed${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ MySQL authentication successful${NC}"
    echo ""
}

check_dns() {
    while true; do
        echo "Checking DNS for ${domain}..."

        if dig +short ${domain} | grep -q '^[0-9]'; then
            IP=$(dig +short ${domain} | head -1)
            echo -e "${GREEN}✓ DNS resolves to: ${IP}${NC}"
            USE_SSL=true
            echo ""
            break
        else
            echo -e "${YELLOW}✗ DNS not configured for ${domain}${NC}"
            echo ""
            echo "Options:"
            echo "  1) Check DNS again"
            echo "  2) Create HTTP-only site (skip SSL)"
            echo "  3) Exit and run script later"
            read -p "Choose (1/2/3): " choice

            case $choice in
                1) echo ""; continue ;;
                2)
                    USE_SSL=false
                    echo "Creating HTTP-only site..."
                    echo ""
                    break
                    ;;
                3)
                    echo "Exiting. Run script again when DNS is ready."
                    exit 0
                    ;;
                *)
                    echo -e "${RED}Invalid choice${NC}"
                    echo ""
                    ;;
            esac
        fi
    done
}

select_nginx_template() {
    if [[ "$USE_SSL" == "false" ]]; then
        TEMPLATE="/etc/nginx/sites-available/template_no_ssl.conf"
        echo "Using template: template_no_ssl.conf (HTTP only)"
        return
    fi

    echo "Select nginx template:"
    echo "  1) With caching (recommended for production)"
    echo "  2) Without caching (easier for development)"
    read -p "Choose (1/2) [1]: " choice
    choice=${choice:-1}

    case $choice in
        1) TEMPLATE="/etc/nginx/sites-available/template.conf" ;;
        2) TEMPLATE="/etc/nginx/sites-available/template_no_caching.conf" ;;
        *)
            echo "Invalid choice, using template.conf"
            TEMPLATE="/etc/nginx/sites-available/template.conf"
            ;;
    esac

    if [ ! -f "$TEMPLATE" ]; then
        echo -e "${RED}ERROR: Template not found: $TEMPLATE${NC}"
        exit 1
    fi

    echo "Using template: $(basename $TEMPLATE)"
    echo ""
}

step_create_dirs() {
    if state_is_complete "STATE_DIRS_CREATED"; then
        echo "[1/9] Directories already created, skipping..."
        return 0
    fi

    echo "[1/9] Creating directories..."

    mkdir -p "${WEB_ROOT}/${domain}"
    mkdir -p "${CACHE_ROOT}/${domain}"

    echo -e "${GREEN}✓ Created directories${NC}"
    update_state "STATE_DIRS_CREATED" "true"
}

step_create_database() {
    if state_is_complete "STATE_DB_CREATED"; then
        echo "[2/9] Database already created, skipping..."
        source "$STATE_FILE"  # Load existing credentials
        return 0
    fi

    echo "[2/9] Creating database..."

    if mysql -p"${MYSQL_PASS}" -e "
CREATE DATABASE ${dbname} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;
CREATE USER '${dbuser}'@'localhost' IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON ${dbname}.* TO '${dbuser}'@'localhost';
FLUSH PRIVILEGES;
" 2>/dev/null; then
        echo -e "${GREEN}✓ Database created${NC}"
        update_state "STATE_DB_CREATED" "true"
        update_state "STATE_DBNAME" "${dbname}"
        update_state "STATE_DBUSER" "${dbuser}"
        update_state "STATE_DBPASS" "${dbpass}"
    else
        echo -e "${RED}ERROR: Database creation failed${NC}"
        return 1
    fi
}

step_download_wordpress() {
    if state_is_complete "STATE_FILES_CREATED"; then
        echo "[3/9] WordPress files already exist, skipping..."
        return 0
    fi

    echo "[3/9] Downloading WordPress..."

    cd "${WEB_ROOT}/${domain}"

    local retries=3
    local count=0

    while [ $count -lt $retries ]; do
        if curl -f -sS -o latest.tar.gz https://wordpress.org/latest.tar.gz; then
            echo -e "${GREEN}✓ Downloaded${NC}"
            break
        else
            count=$((count + 1))
            if [ $count -lt $retries ]; then
                echo "Download failed, retrying... ($count/$retries)"
                sleep 2
            else
                echo -e "${RED}ERROR: Failed to download WordPress${NC}"
                return 1
            fi
        fi
    done

    tar xzf latest.tar.gz || { echo -e "${RED}ERROR: Failed to extract${NC}"; return 1; }
    mv wordpress/* ./ 2>/dev/null || true
    rm -rf wordpress latest.tar.gz

    mkdir -p wp-content/upgrade

    echo -e "${GREEN}✓ WordPress files ready${NC}"
    update_state "STATE_FILES_CREATED" "true"
}

step_configure_wpconfig() {
    if state_is_complete "STATE_WPCONFIG_CREATED"; then
        echo "[4/9] wp-config already configured, skipping..."
        return 0
    fi

    echo "[4/9] Configuring wp-config.php..."

    cd "${WEB_ROOT}/${domain}"

    cp wp-config-sample.php wp-config.php

    # Get salts
    echo "Generating security keys..."
    SALTS=$(curl -sf https://api.wordpress.org/secret-key/1.1/salt/)

    if [ -z "$SALTS" ]; then
        echo -e "${YELLOW}⚠ API unavailable, generating local salts${NC}"
        SALTS=$(php -r "
\$keys = ['AUTH_KEY', 'SECURE_AUTH_KEY', 'LOGGED_IN_KEY', 'NONCE_KEY',
         'AUTH_SALT', 'SECURE_AUTH_SALT', 'LOGGED_IN_SALT', 'NONCE_SALT'];
foreach (\$keys as \$key) {
    \$salt = bin2hex(random_bytes(32));
    echo \"define('{\$key}', '\$salt');\n\";
}
")
    fi

    # Update database credentials
    sed -i "s/database_name_here/${dbname}/" wp-config.php
    sed -i "s/username_here/${dbuser}/" wp-config.php
    sed -i "s/password_here/${dbpass}/" wp-config.php

    # Replace salts
    sed -i "/AUTH_KEY/,/NONCE_SALT/d" wp-config.php
    sed -i "/\/\*\*#@-\*\//a\\
${SALTS}" wp-config.php

    # Add cache key salt
    CACHE_SALT="${domain//./_}"
    sed -i "/<?php/a\\
define( 'WP_CACHE_KEY_SALT', '${CACHE_SALT}' );" wp-config.php

    # Add FS_METHOD
    echo "define('FS_METHOD', 'direct');" >> wp-config.php

    echo -e "${GREEN}✓ wp-config.php configured${NC}"
    update_state "STATE_WPCONFIG_CREATED" "true"
}

step_set_permissions() {
    if state_is_complete "STATE_PERMISSIONS_SET"; then
        echo "[5/9] Permissions already set, skipping..."
        return 0
    fi

    echo "[5/9] Setting permissions..."

    local site_path="${WEB_ROOT}/${domain}"

    # Create uploads directory if missing
    mkdir -p "$site_path/wp-content/uploads"

    sudo chown -R ${USER}:www-data "$site_path"
    sudo find "$site_path" -type d -exec chmod g+s {} \;
    sudo chmod g+w "$site_path/wp-content"
    sudo chmod -R g+w "$site_path/wp-content/themes"
    sudo chmod -R g+w "$site_path/wp-content/plugins"
    sudo chmod -R g+w "$site_path/wp-content/uploads"

    sudo chown -R www-data:www-data "${CACHE_ROOT}/${domain}"

    echo -e "${GREEN}✓ Permissions set${NC}"
    update_state "STATE_PERMISSIONS_SET" "true"
}

step_create_nginx_config() {
    if state_is_complete "STATE_NGINX_CREATED"; then
        echo "[6/9] Nginx config already exists, skipping..."
        return 0
    fi

    echo "[6/9] Creating nginx configuration..."

    NGINX_CONF="/etc/nginx/sites-available/${domain}.conf"

    sudo cp "$TEMPLATE" "$NGINX_CONF"
    sudo sed -i "s/_domain_name_/${domain}/g" "$NGINX_CONF"

    # Test before enabling
    if ! sudo nginx -t 2>&1 | grep -q "successful"; then
        echo -e "${RED}ERROR: Nginx configuration test failed${NC}"
        sudo nginx -t
        echo ""
        echo "Config created but has errors: $NGINX_CONF"
        return 1
    fi

    sudo ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/${domain}"
    sudo service nginx reload

    echo -e "${GREEN}✓ Nginx configured and reloaded${NC}"
    update_state "STATE_NGINX_CREATED" "true"
}

step_get_ssl() {
    if [[ "$USE_SSL" == "false" ]]; then
        echo "[7/9] Skipping SSL (HTTP-only site)"
        return 0
    fi

    if state_is_complete "STATE_SSL_CREATED"; then
        echo "[7/9] SSL certificate already exists, skipping..."
        return 0
    fi

    echo "[7/9] Obtaining SSL certificate..."

    if sudo certbot --nginx certonly \
        -d "${domain}" -d "www.${domain}" \
        --non-interactive --agree-tos \
        --register-unsafely-without-email &>/dev/null; then

        sudo service nginx reload
        echo -e "${GREEN}✓ SSL certificate obtained${NC}"
        update_state "STATE_SSL_CREATED" "true"
    else
        echo ""
        echo -e "${YELLOW}⚠ SSL certificate generation failed${NC}"
        echo ""
        echo "Possible reasons:"
        echo "  - DNS not fully propagated (wait 10-30 minutes)"
        echo "  - Port 80/443 not accessible"
        echo "  - Domain doesn't point to this server"
        echo ""
        echo "Site accessible via HTTP: http://${domain}"
        echo ""
        echo "To add SSL later:"
        echo "  sudo certbot --nginx certonly -d ${domain} -d www.${domain}"
        echo ""

        # Don't fail script
        return 0
    fi
}

step_setup_backup() {
    if state_is_complete "STATE_BACKUP_CREATED"; then
        echo "[8/9] Backup already configured, skipping..."
        return 0
    fi

    echo "[8/9] Setting up automated backups..."

    # Create backup directory for this site
    local backup_dir="/home/${USER}/backups/${domain}"
    mkdir -p "$backup_dir"

    # Create site-specific backup script
    local backup_script="/home/${USER}/apps/backup/site-${domain}.sh"
    cat > "$backup_script" << 'BACKUP_EOF'
# Define variables for the site
THESITE="DOMAIN_PLACEHOLDER"
THEDB="DBNAME_PLACEHOLDER"
THEDBUSER="DBUSER_PLACEHOLDER"
THEDBPW="DBPASS_PLACEHOLDER"

# Take backup of the database
mysqldump -u $THEDBUSER -p${THEDBPW} $THEDB | gzip > /home/USER_PLACEHOLDER/www/$THESITE/${THESITE}_${THEDATE}.sql.gz
# Archive the folder containing sql backup without cache and put it under /home/USER_PLACEHOLDER/backups/website_folder_name/
sudo tar -czf /home/USER_PLACEHOLDER/backups/${THESITE}/${THESITE}_${THEFREQ}_${THEDATE}.tar.gz --exclude='wp-content/cache' $THESITE
# Remove the sql backup from the website folder
sudo rm /home/USER_PLACEHOLDER/www/$THESITE/*.sql.gz
BACKUP_EOF

    # Replace placeholders with actual values
    sed -i "s/DOMAIN_PLACEHOLDER/${domain}/g" "$backup_script"
    sed -i "s/DBNAME_PLACEHOLDER/${dbname}/g" "$backup_script"
    sed -i "s/DBUSER_PLACEHOLDER/${dbuser}/g" "$backup_script"
    sed -i "s/DBPASS_PLACEHOLDER/${dbpass}/g" "$backup_script"
    sed -i "s/USER_PLACEHOLDER/${USER}/g" "$backup_script"

    chmod +x "$backup_script"

    echo ""
    echo "Select backup frequency:"
    echo "  1) Daily   (creates daily + weekly + monthly backups)"
    echo "  2) Weekly  (creates weekly + monthly backups)"
    echo "  3) Monthly (creates monthly backups only)"
    read -p "Choose (1/2/3) [1]: " freq_choice
    freq_choice=${freq_choice:-1}

    local daily_script="/home/${USER}/apps/backup/backup-daily.sh"
    local weekly_script="/home/${USER}/apps/backup/backup-weekly.sh"
    local monthly_script="/home/${USER}/apps/backup/backup-monthly.sh"

    case $freq_choice in
        1)
            # Daily: Add to all three schedules (cascading)
            echo "sh /home/${USER}/apps/backup/site-${domain}.sh" >> "$daily_script"
            echo "sh /home/${USER}/apps/backup/site-${domain}.sh" >> "$weekly_script"
            echo "sh /home/${USER}/apps/backup/site-${domain}.sh" >> "$monthly_script"
            echo "Configured for: Daily + Weekly + Monthly backups"
            ;;
        2)
            # Weekly: Add to weekly and monthly schedules (cascading)
            echo "sh /home/${USER}/apps/backup/site-${domain}.sh" >> "$weekly_script"
            echo "sh /home/${USER}/apps/backup/site-${domain}.sh" >> "$monthly_script"
            echo "Configured for: Weekly + Monthly backups"
            ;;
        3)
            # Monthly: Add to monthly schedule only
            echo "sh /home/${USER}/apps/backup/site-${domain}.sh" >> "$monthly_script"
            echo "Configured for: Monthly backups only"
            ;;
        *)
            echo -e "${YELLOW}Invalid choice, defaulting to Daily${NC}"
            echo "sh /home/${USER}/apps/backup/site-${domain}.sh" >> "$daily_script"
            echo "sh /home/${USER}/apps/backup/site-${domain}.sh" >> "$weekly_script"
            echo "sh /home/${USER}/apps/backup/site-${domain}.sh" >> "$monthly_script"
            echo "Configured for: Daily + Weekly + Monthly backups"
            ;;
    esac

    echo -e "${GREEN}✓ Backup configured${NC}"
    echo "  Script: ${backup_script}"
    echo "  Backups stored in: ${backup_dir}"
    update_state "STATE_BACKUP_CREATED" "true"
}

step_finalize() {
    echo "[9/9] Finalizing..."

    # Flush Redis if available
    if command -v redis-cli &>/dev/null; then
        redis-cli flushall async &>/dev/null || true
    fi

    echo -e "${GREEN}✓ Complete${NC}"
}

write_credentials() {
    cat > "$CREDS_FILE" << EOF
========================================
WordPress Site Created
========================================

Created: $(date)

Site URL:      https://${domain}
Admin URL:     https://${domain}/wp-admin

Database Name: ${dbname}
Database User: ${dbuser}
Database Pass: ${dbpass}

Web Root:      ${WEB_ROOT}/${domain}
Cache Path:    ${CACHE_ROOT}/${domain}

========================================
Complete WordPress installation at:
https://${domain}
========================================
EOF

    chmod 600 "$CREDS_FILE"
}

#=============================================================================
# MAIN SCRIPT
#=============================================================================

main() {
    echo "========================================="
    echo "Add WordPress Site"
    echo "========================================="
    echo ""

    # Lock file
    if [ -f "$LOCKFILE" ]; then
        PID=$(cat "$LOCKFILE")
        if kill -0 "$PID" 2>/dev/null; then
            echo -e "${RED}ERROR: Script already running (PID: $PID)${NC}"
            exit 1
        else
            rm -f "$LOCKFILE"
        fi
    fi
    echo $$ > "$LOCKFILE"
    trap "rm -f $LOCKFILE" EXIT

    # Check prerequisites
    check_prerequisites

    # Setup MySQL
    setup_mysql_auth

    # Check for existing state
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
        echo -e "${YELLOW}Found incomplete site creation: ${STATE_DOMAIN}${NC}"
        echo ""
        echo "Options:"
        echo "  1) Resume creation of ${STATE_DOMAIN}"
        echo "  2) Delete and start fresh"
        echo "  3) Exit"
        read -p "Choose (1/2/3): " resume_choice

        case $resume_choice in
            1)
                domain="${STATE_DOMAIN}"
                dbname="${STATE_DBNAME}"
                dbuser="${STATE_DBUSER}"
                dbpass="${STATE_DBPASS}"
                USE_SSL="${STATE_USE_SSL:-true}"
                TEMPLATE="${STATE_TEMPLATE}"
                echo ""
                echo "Resuming ${domain}..."
                echo ""
                ;;
            2)
                rollback_all
                rm -f "$STATE_FILE" "$CREDS_FILE"
                echo ""
                ;;
            3)
                exit 0
                ;;
            *)
                echo "Invalid choice"
                exit 1
                ;;
        esac
    fi

    # Get input if not resuming
    if [ -z "${domain:-}" ]; then
        until validate_domain "$domain"; do
            read -p "Enter domain (e.g., example.com): " domain
        done

        check_dns
        select_nginx_template

        until validate_dbname "$dbname"; do
            read -p "Enter database name: " dbname
        done

        until validate_dbuser "$dbuser"; do
            read -p "Enter database user: " dbuser
        done

        dbpass=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c 20)

        # Initialize state
        cat > "$STATE_FILE" << EOF
STATE_DOMAIN="${domain}"
STATE_DBNAME="${dbname}"
STATE_DBUSER="${dbuser}"
STATE_DBPASS="${dbpass}"
STATE_USE_SSL="${USE_SSL}"
STATE_TEMPLATE="${TEMPLATE}"
STATE_DIRS_CREATED=false
STATE_DB_CREATED=false
STATE_FILES_CREATED=false
STATE_WPCONFIG_CREATED=false
STATE_PERMISSIONS_SET=false
STATE_NGINX_CREATED=false
STATE_SSL_CREATED=false
STATE_BACKUP_CREATED=false
EOF
        echo ""
    fi

    # Execute steps
    step_create_dirs
    step_create_database
    step_download_wordpress
    step_configure_wpconfig
    step_set_permissions
    step_create_nginx_config
    step_get_ssl
    step_setup_backup
    step_finalize

    # Write credentials
    write_credentials

    # Display success
    echo ""
    echo "========================================="
    echo -e "${GREEN}✓ WordPress Site Created Successfully!${NC}"
    echo "========================================="
    echo ""
    cat "$CREDS_FILE"
    echo ""
    echo -e "${YELLOW}⚠  IMPORTANT:${NC}"
    echo "   1. Copy the credentials above"
    echo "   2. Delete the credentials file for security:"
    echo "      rm $CREDS_FILE"
    echo ""

    # Clean up state
    rm -f "$STATE_FILE"
}

# Run main
main
