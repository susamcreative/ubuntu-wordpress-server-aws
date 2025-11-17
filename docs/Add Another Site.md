**Core Setup**: [Initial Setup](Initial%20Setup.md) → [Install LEMP Stack](Install%20LEMP.md) → [Wordpress](Wordpress.md) → [SSL Let's Encrypt](SSL%20Let's%20Encrypt.md) → [Automation](Automation.md)

**Additional Workflows**: **Add Another Site** | [Migrate Existing Site](Migrate%20Existing%20Site.md)

# Add Another WordPress Site

Once your server is set up with the LEMP stack, adding additional WordPress sites takes only 10-15 minutes. This guide assumes you've already completed the initial server setup.

**Prerequisites**: Server configured with nginx, PHP, MariaDB, and SSL (Certbot) installed.

---

## Quick Setup (Automated)

We provide an automation script that handles all the steps below with validation and error checking:

```bash
~/apps/add-site.sh
```

**What the script does:**
- Validates prerequisites (nginx, MySQL, templates)
- Checks DNS and offers HTTP-only option if not ready
- Creates directories and database
- Downloads and configures WordPress
- Sets proper permissions
- Creates nginx configuration with template selection
- Obtains SSL certificate (optional)
- Provides resumable workflow if interrupted

**The script will prompt for:**
- Domain name
- Database name and user
- MySQL root password (not stored)

**Important Files:**
- **`~/.add-site-credentials.txt`** - Site credentials (database password, paths)
  - **SECURITY: Copy credentials and delete this file immediately:**
    ```bash
    rm ~/.add-site-credentials.txt
    ```
- **`~/.add-site.state`** - Temporary state file for resume functionality
  - Automatically deleted on successful completion
  - If script is interrupted, allows resuming from where it left off
  - To manually clean up: `rm ~/.add-site.state`

**If the script is interrupted:**
- State is preserved in `~/.add-site.state`
- Run the script again - it will detect incomplete setup
- Choose to resume or start fresh (with automatic rollback)

---

## Manual Setup (Step by Step)

If you prefer to understand each step or customize the process, follow the manual steps below.

### Step 1: Configure DNS

Before starting, point your domain to your server's IP address using your DNS provider:

```
A     newsite.com           your_server_ip
CNAME www.newsite.com       newsite.com
```

Wait for DNS propagation (usually a few minutes, up to 48 hours).

---

## Step 2: Create Directory Structure

```bash
mkdir /home/_user_/www/newsite.com
```

Set permissions:
```bash
sudo chown -R _user_:www-data /home/_user_/www/newsite.com
sudo find /home/_user_/www/newsite.com -type d -exec chmod g+s {} \;
```

---

## Step 3: Obtain SSL Certificate

```bash
sudo certbot --nginx certonly -d newsite.com -d www.newsite.com
```

Certbot will:
- Verify domain ownership
- Generate certificates at `/etc/letsencrypt/live/newsite.com/`
- Configure automatic renewal

**For Cloudflare DNS challenge** (wildcard support):
```bash
sudo certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/.secrets/cloudflare.ini \
  -d newsite.com -d "*.newsite.com"
```

---

## Step 4: Create Nginx Configuration

Copy the template:
```bash
cp /etc/nginx/sites-available/template.conf /etc/nginx/sites-available/newsite.com.conf
```

Edit the configuration:
```bash
sudo nano /etc/nginx/sites-available/newsite.com.conf
```

Replace all instances of `_domain_name_` with `newsite.com`.

Enable the site:
```bash
ln -s /etc/nginx/sites-available/newsite.com.conf /etc/nginx/sites-enabled/newsite.com
```

Test nginx configuration:
```bash
sudo nginx -t
```

If successful, reload nginx:
```bash
sudo service nginx reload
```

---

## Step 5: Create Database

Log into MariaDB:
```bash
mysql -u root -p
```

Create database and user:
```sql
CREATE DATABASE newsite_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;
CREATE USER 'newsite_user'@'localhost' IDENTIFIED BY 'secure_password_here';
GRANT ALL PRIVILEGES ON newsite_db.* TO 'newsite_user'@'localhost';
FLUSH PRIVILEGES;
exit;
```

**Save these credentials** - you'll need them for WordPress installation.

---

## Step 6: Install WordPress

Navigate to the site directory:
```bash
cd /home/_user_/www/newsite.com
```

Download WordPress:
```bash
sudo curl -O https://wordpress.org/latest.tar.gz
sudo tar xzf latest.tar.gz
```

Move files to main directory:
```bash
cd wordpress
sudo mv * ../
cd ..
sudo rm -r wordpress latest.tar.gz
```

Create upgrade directory:
```bash
sudo mkdir wp-content/upgrade
```

Create wp-config:
```bash
sudo cp wp-config-sample.php wp-config.php
```

---

## Step 7: Set Permissions

Set ownership and permissions:
```bash
sudo chown -R _user_:www-data /home/_user_/www/newsite.com
sudo find /home/_user_/www/newsite.com -type d -exec chmod g+s {} \;
sudo chmod g+w /home/_user_/www/newsite.com/wp-content
sudo chmod -R g+w /home/_user_/www/newsite.com/wp-content/themes
sudo chmod -R g+w /home/_user_/www/newsite.com/wp-content/plugins
sudo chmod -R g+w /home/_user_/www/newsite.com/wp-content/uploads
```

---

## Step 8: Configure WordPress

Generate security keys:
```bash
curl -s https://api.wordpress.org/secret-key/1.1/salt/
```

Edit wp-config.php:
```bash
sudo nano /home/_user_/www/newsite.com/wp-config.php
```

1. Paste the security keys from step above
2. Update database credentials:
   ```php
   define( 'DB_NAME', 'newsite_db' );
   define( 'DB_USER', 'newsite_user' );
   define( 'DB_PASSWORD', 'secure_password_here' );
   ```

3. Add at the top of the file:
   ```php
   define( 'WP_CACHE_KEY_SALT', 'newsite_com' );
   ```

4. Add at the end of the file:
   ```php
   define('FS_METHOD', 'direct');
   ```

Save and exit.

---

## Step 9: Complete Installation

Visit your domain in a browser:
```
https://newsite.com
```

Complete the WordPress installation wizard:
- Site title
- Admin username
- Admin password (save this!)
- Admin email

---

## Step 10: Install Caching Plugins

### Redis Object Cache
1. Install "Redis Object Cache" by Till Krüss
2. Activate and enable object caching

### Nginx FastCGI Cache
1. Install "Nginx Cache" by Till Krüss
2. Go to Tools → Nginx Cache
3. Set Cache Zone Path to: `/home/_user_/cache/newsite.com`
4. Create the cache directory:
   ```bash
   mkdir -p /home/_user_/cache/newsite.com
   sudo chown -R www-data:www-data /home/_user_/cache/newsite.com
   ```

---

## Summary

Your new WordPress site is now live at `https://newsite.com` with:
- ✅ SSL certificate (auto-renewing)
- ✅ Nginx configuration
- ✅ Database and user
- ✅ WordPress installed
- ✅ Caching configured

**Total time**: 10-15 minutes

---

**NEXT SITE**: Repeat this process for each additional WordPress site you want to host on this server.

---

## Troubleshooting the Automation Script

### Script says "already running"
```bash
# Check if process is actually running
ps aux | grep add-site.sh

# If not running, remove stale lock file
rm /tmp/.add-site.lock
```

### Script was interrupted, how do I clean up?
```bash
# Remove state file to start fresh
rm ~/.add-site.state

# Remove credentials file
rm ~/.add-site-credentials.txt

# Manually remove site if partially created
# (Check what was created first)
ls ~/www/
mysql -u root -p -e "SHOW DATABASES;"
```

### I forgot to save the credentials
```bash
# Credentials are in the file until you delete it
cat ~/.add-site-credentials.txt

# Database password is also in wp-config.php
grep DB_PASSWORD ~/www/yourdomain.com/wp-config.php
```

### DNS check keeps failing
- Verify DNS is actually configured: `dig yourdomain.com`
- Choose option 2 to create HTTP-only site
- Add SSL manually later with: `sudo certbot --nginx certonly -d yourdomain.com -d www.yourdomain.com`

### MySQL authentication failed
- Ensure you're entering the correct root password
- Test manually: `mysql -u root -p`
- Check if MySQL is running: `sudo service mysql status`

---

**See Also**: [Migrate Existing Site](Migrate%20Existing%20Site.md) - Move WordPress from another server
