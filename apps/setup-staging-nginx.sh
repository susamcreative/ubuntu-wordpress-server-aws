#!/bin/bash
#
# Setup Staging Nginx - Configure nginx/SSL for WordPress staging sites
#
# USAGE:
#   ./apps/setup-staging-nginx.sh
#
# DESCRIPTION:
#   Configures nginx and SSL for staging WordPress sites created by cloning plugins
#   (WP Time Capsule, WP Staging, Duplicator, etc.). Staging-platform agnostic.
#
# WHAT IT DOES:
#   1. Validates parent production site exists
#   2. Auto-discovers staging WordPress installations
#   3. Validates WordPress core files exist
#   4. Creates nginx configuration (no caching for easier development)
#   5. Smart SSL: uses wildcard cert if available, or creates specific cert
#   6. Blocks search engines via robots.txt and X-Robots-Tag
#   7. Creates separate log files for staging
#   8. Sets proper file permissions
#
# COMMON STAGING LOCATIONS:
#   ~/www/example.com/staging/              (WP Time Capsule)
#   ~/www/example.com/wp-content/staging/   (Some plugins)
#   ~/www/example-staging.com/              (Sibling staging domain)
#   ~/www/staging.example.com/              (Manual/separate)
#
# REQUIREMENTS:
#   - Parent production site already configured
#   - Staging WordPress files created by plugin
#   - Valid wp-config.php in staging location
#
# EXAMPLES:
#   # After using WP Time Capsule to clone example.com to staging
#   ./apps/setup-staging-nginx.sh
#
# NOTES:
#   - Does NOT create WordPress files (use your cloning plugin)
#   - Only handles nginx/SSL layer that plugins can't configure
#   - Staging sites are NOT added to automated backups

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

validate_wordpress() {
    local path=$1

    # Check critical WordPress files
    if [ ! -f "$path/wp-config.php" ]; then
        return 1
    fi

    if [ ! -f "$path/wp-load.php" ]; then
        return 1
    fi

    if [ ! -d "$path/wp-includes" ]; then
        return 1
    fi

    if [ ! -d "$path/wp-content" ]; then
        return 1
    fi

    return 0
}

extract_base_domain() {
    local subdomain=$1
    echo "$subdomain" | sed 's/^[^.]*\.//'
}

default_staging_domain() {
    local parent=$1
    local label="${parent%%.*}"
    local base="${parent#*.}"

    if [ "$base" != "$parent" ]; then
        echo "${label}-staging.${base}"
    else
        echo "staging-${parent}"
    fi
}

is_staging_domain() {
    local domain=$1

    if [[ "$domain" == staging.* ]] || [[ "$domain" == *.staging.* ]] || [[ "$domain" == staging-*.* ]] || [[ "$domain" == *-staging.* ]]; then
        return 0
    fi

    return 1
}

is_staging_for_parent() {
    local staging=$1
    local parent=$2
    local label="${parent%%.*}"
    local base="${parent#*.}"

    if [[ "$staging" == "staging.${parent}" ]] || [[ "$staging" == "staging-${parent}" ]]; then
        return 0
    fi

    if [ "$base" != "$parent" ] && [[ "$staging" == "${label}-staging.${base}" ]]; then
        return 0
    fi

    return 1
}

#=============================================================================
# MAIN SCRIPT
#=============================================================================

main() {
    echo "========================================="
    echo "Setup Staging Nginx Configuration"
    echo "========================================="
    echo ""

    # Step 1: Get parent domain
    echo "Step 1: Identify parent production site"
    echo ""

    read -p "Enter parent production domain (e.g., example.com): " parent_domain

    # Validate parent site exists
    if [ ! -d "${WEB_ROOT}/${parent_domain}" ]; then
        error_exit "Parent site directory not found: ${WEB_ROOT}/${parent_domain}"
    fi

    if [ ! -f "${WEB_ROOT}/${parent_domain}/wp-config.php" ]; then
        error_exit "Parent site is not a WordPress installation (wp-config.php not found)"
    fi

    if [ ! -f "/etc/nginx/sites-available/${parent_domain}.conf" ]; then
        error_exit "Parent site nginx config not found: /etc/nginx/sites-available/${parent_domain}.conf"
    fi

    echo -e "${GREEN}✓ Parent site validated: ${parent_domain}${NC}"
    echo ""

    # Step 2: Get staging subdomain
    echo "Step 2: Define staging domain"
    echo ""

    default_staging=$(default_staging_domain "$parent_domain")
    read -p "Enter staging domain [${default_staging}]: " staging_domain
    staging_domain=${staging_domain:-$default_staging}

    # Validate domain format
    if [[ ! "$staging_domain" =~ ^[a-z0-9.-]+\.[a-z]+$ ]]; then
        error_exit "Invalid domain format. Use lowercase, numbers, dots, hyphens only"
    fi

    # Validate it is an explicit staging domain for this parent site.
    if ! is_staging_domain "$staging_domain" || ! is_staging_for_parent "$staging_domain" "$parent_domain"; then
        error_exit "Staging domain must be explicit and related to ${parent_domain}. Use ${default_staging}, staging.${parent_domain}, or staging-${parent_domain}"
    fi

    # Check if nginx config already exists
    if [ -f "/etc/nginx/sites-available/${staging_domain}.conf" ]; then
        error_exit "Nginx config already exists for ${staging_domain}"
    fi

    echo -e "${GREEN}✓ Staging subdomain validated: ${staging_domain}${NC}"
    echo ""

    # Step 3: Auto-discover staging WordPress installation
    echo "Step 3: Locate staging WordPress installation"
    echo ""
    echo "Searching for WordPress installations..."
    echo ""

    # Common staging locations
    search_paths=(
        "${WEB_ROOT}/${parent_domain}/staging"
        "${WEB_ROOT}/${parent_domain}/wp-content/staging"
        "${WEB_ROOT}/${default_staging}"
        "${WEB_ROOT}/staging.${parent_domain}"
        "${WEB_ROOT}/${parent_domain}_staging"
        "${WEB_ROOT}/staging-${parent_domain}"
    )

    suggestions=()
    for path in "${search_paths[@]}"; do
        if validate_wordpress "$path"; then
            suggestions+=("$path")
        fi
    done

    # Display suggestions
    if [ ${#suggestions[@]} -gt 0 ]; then
        echo "Found potential staging WordPress installations:"
        for i in "${!suggestions[@]}"; do
            echo "  $((i+1))) ${suggestions[$i]}"
        done
        echo "  $((${#suggestions[@]}+1))) Enter custom path"
        echo ""

        read -p "Choose (1-$((${#suggestions[@]}+1))): " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#suggestions[@]}" ]; then
            staging_path="${suggestions[$((choice-1))]}"
        elif [ "$choice" -eq "$((${#suggestions[@]}+1))" ]; then
            read -p "Enter full path to staging WordPress: " staging_path
        else
            error_exit "Invalid choice"
        fi
    else
        echo "No WordPress installations found in common locations."
        echo ""
        read -p "Enter full path to staging WordPress: " staging_path
    fi

    # Validate the chosen path
    if [ ! -d "$staging_path" ]; then
        error_exit "Directory does not exist: $staging_path"
    fi

    if ! validate_wordpress "$staging_path"; then
        error_exit "Not a valid WordPress installation: $staging_path"
    fi

    echo -e "${GREEN}✓ WordPress installation validated: ${staging_path}${NC}"
    echo ""

    # Step 4: Check DNS
    echo "Step 4: Check DNS configuration"
    echo ""
    echo "Checking DNS for ${staging_domain}..."

    USE_SSL=true
    if dig +short "${staging_domain}" | grep -q '^[0-9]'; then
        IP=$(dig +short "${staging_domain}" | head -1)
        echo -e "${GREEN}✓ DNS resolves to: ${IP}${NC}"
    else
        echo -e "${YELLOW}⚠ DNS not configured for ${staging_domain}${NC}"
        echo ""
        echo "Options:"
        echo "  1) Continue with HTTP-only (no SSL)"
        echo "  2) Exit and configure DNS first"
        read -p "Choose (1/2): " dns_choice

        case $dns_choice in
            1)
                USE_SSL=false
                echo "Creating HTTP-only site..."
                ;;
            2)
                echo "Exiting. Run script again when DNS is ready."
                exit 0
                ;;
            *)
                error_exit "Invalid choice"
                ;;
        esac
    fi
    echo ""

    # Step 5: Select nginx template
    echo "Step 5: Prepare nginx configuration"
    echo ""

    if [ "$USE_SSL" = "true" ]; then
        TEMPLATE="/etc/nginx/sites-available/template_no_caching.conf"
        echo "Using template: template_no_caching.conf (no cache for easier development)"
    else
        TEMPLATE="/etc/nginx/sites-available/template_no_ssl.conf"
        echo "Using template: template_no_ssl.conf (HTTP only, no cache)"
    fi

    if [ ! -f "$TEMPLATE" ]; then
        error_exit "Template not found: $TEMPLATE"
    fi

    echo ""

    # Step 6: Create nginx config
    echo "Step 6: Creating nginx configuration..."
    echo ""

    NGINX_CONF="/etc/nginx/sites-available/${staging_domain}.conf"

    # Copy template
    sudo cp "$TEMPLATE" "$NGINX_CONF"

    # Replace placeholders
    sudo sed -i "s|_domain_name_|${staging_domain}|g" "$NGINX_CONF"
    sudo sed -i "s|/home/_user_/www/_domain_name_|${staging_path}|g" "$NGINX_CONF"

    # Add search engine blocking
    # Insert after "index index.php;" line
    sudo sed -i "/index index.php;/a\\
\\
\t# Block search engines from indexing staging site\\
\tlocation = /robots.txt {\\
\t\tadd_header Content-Type text/plain;\\
\t\treturn 200 \"User-agent: *\\\\nDisallow: /\\\\n\";\\
\t}\\
\\
\t# Add noindex header to all responses\\
\tadd_header X-Robots-Tag \"noindex, nofollow\" always;" "$NGINX_CONF"

    # Test nginx config
    if ! sudo nginx -t 2>&1 | grep -q "successful"; then
        echo -e "${RED}ERROR: Nginx configuration test failed${NC}"
        sudo nginx -t
        sudo rm -f "$NGINX_CONF"
        error_exit "Invalid nginx configuration"
    fi

    # Enable site
    sudo ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/${staging_domain}"
    sudo service nginx reload

    echo -e "${GREEN}✓ Nginx configured and enabled${NC}"
    echo ""

    # Step 7: SSL Certificate
    if [ "$USE_SSL" = "true" ]; then
        echo "Step 7: Configure SSL certificate"
        echo ""

        # Check for wildcard certificate
        base_domain=$(extract_base_domain "$staging_domain")
        WILDCARD_CERT="/etc/letsencrypt/live/*.${base_domain}"

        if compgen -G "$WILDCARD_CERT" > /dev/null; then
            echo -e "${GREEN}✓ Wildcard certificate found for *.${base_domain}${NC}"
            echo "Using existing wildcard certificate"

            # Update nginx config to use wildcard cert
            sudo sed -i "s|/etc/letsencrypt/live/${staging_domain}/|/etc/letsencrypt/live/*.${base_domain}/|g" "$NGINX_CONF"
            sudo service nginx reload
        elif [ -d "/etc/letsencrypt/live/${staging_domain}" ]; then
            echo -e "${GREEN}✓ Existing certificate found for ${staging_domain}${NC}"
            echo "Using existing certificate"
        else
            echo "Requesting SSL certificate for ${staging_domain}..."

            if sudo certbot --nginx certonly \
                -d "${staging_domain}" \
                --non-interactive --agree-tos \
                --register-unsafely-without-email &>/dev/null; then

                sudo service nginx reload
                echo -e "${GREEN}✓ SSL certificate obtained${NC}"
            else
                echo ""
                echo -e "${YELLOW}⚠ SSL certificate generation failed${NC}"
                echo ""
                echo "Possible reasons:"
                echo "  - DNS not fully propagated (wait 10-30 minutes)"
                echo "  - Port 80/443 not accessible"
                echo "  - Domain doesn't point to this server"
                echo ""
                echo "Site accessible via HTTP: http://${staging_domain}"
                echo ""
                echo "To add SSL later:"
                echo "  sudo certbot --nginx certonly -d ${staging_domain}"
                echo ""
            fi
        fi
        echo ""
    else
        echo "Step 7: Skipping SSL (HTTP-only site)"
        echo ""
    fi

    # Step 8: Set permissions
    echo "Step 8: Setting file permissions..."
    echo ""

    sudo chown -R "${USER}:www-data" "$staging_path"
    sudo find "$staging_path" -type d -exec chmod 755 {} \;
    sudo find "$staging_path" -type f -exec chmod 644 {} \;
    sudo chmod -R g+w "$staging_path/wp-content"

    echo -e "${GREEN}✓ Permissions set${NC}"
    echo ""

    # Step 9: Create log files
    echo "Step 9: Creating log files..."
    echo ""

    touch "${LOGS_ROOT}/${staging_domain}.access.log"
    touch "${LOGS_ROOT}/${staging_domain}.error.log"

    echo -e "${GREEN}✓ Log files created${NC}"
    echo ""

    # Final summary
    echo "========================================="
    echo -e "${GREEN}✓ Staging Site Configured Successfully!${NC}"
    echo "========================================="
    echo ""
    echo "Staging Site:      https://${staging_domain}"
    echo "WordPress Path:    ${staging_path}"
    echo "Nginx Config:      ${NGINX_CONF}"
    echo "Logs:              ${LOGS_ROOT}/${staging_domain}.{access,error}.log"
    echo ""
    echo "Search Engines:    Blocked (robots.txt + X-Robots-Tag)"
    echo "FastCGI Cache:     Disabled (easier for development)"
    echo "Backups:           Not configured (staging is expendable)"
    echo ""
    echo "========================================="
    echo ""
}

# Run main
main
