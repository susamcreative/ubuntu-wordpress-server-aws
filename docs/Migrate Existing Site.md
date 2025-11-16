**Core Setup**: [Initial Setup](Initial%20Setup.md) → [Install LEMP Stack](Install%20LEMP.md) → [Wordpress](Wordpress.md) → [SSL Let's Encrypt](SSL%20Let's%20Encrypt.md) → [Automation](Automation.md)

**Additional Workflows**: [Add Another Site](Add%20Another%20Site.md) | **Migrate Existing Site**

# Migrate Existing WordPress Site

This guide covers moving a WordPress site from an old server to your new Ubuntu 24.04 server with minimal downtime.

**Prerequisites**: New server configured with LEMP stack and SSH access to both servers.

---

## Migration Strategy

1. Prepare both servers for file transfer
2. Transfer files and database
3. Test on new server (without affecting live site)
4. Minimize downtime with final sync
5. Update DNS
6. Complete setup with fresh SSL certificates

---

## Step 1: Prepare SSH Access Between Servers

On your **new server**, generate an SSH key:
```bash
ssh-keygen -t ed25519 -C "server-migration"
```

Press Enter to accept defaults (no passphrase for automation).

Copy the public key:
```bash
cat ~/.ssh/id_ed25519.pub
```

On your **old server**, add this key to authorized_keys:
```bash
nano ~/.ssh/authorized_keys
```

Paste the public key, save and exit.

Test connection from **new server**:
```bash
ssh user@old-server-ip
```

If successful, you can proceed with automated file transfers.

---

## Step 2: Create Database on New Server

Log into MariaDB on the **new server**:
```bash
mysql -u root -p
```

Create database and user:
```sql
CREATE DATABASE migrated_site CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;
CREATE USER 'migrated_user'@'localhost' IDENTIFIED BY 'new_secure_password';
GRANT ALL PRIVILEGES ON migrated_site.* TO 'migrated_user'@'localhost';
FLUSH PRIVILEGES;
exit;
```

**Note**: You can use different database credentials on the new server (more secure).

---

## Step 3: Transfer Site Files

From your **new server**, copy files from old server:

```bash
scp -r user@old-server-ip:~/www/example.com /home/_user_/www/
```

This transfers directly between servers without downloading to your local machine.

**Alternative for large sites** (compressed transfer):
```bash
# On old server: create compressed archive
ssh user@old-server-ip
cd ~/www
tar -czf example.com.tar.gz example.com/
exit

# On new server: transfer and extract
scp user@old-server-ip:~/www/example.com.tar.gz /home/_user_/www/
cd /home/_user_/www
tar -xzf example.com.tar.gz
rm example.com.tar.gz
```

---

## Step 4: Set Permissions on New Server

```bash
sudo chown -R _user_:www-data /home/_user_/www/example.com
sudo find /home/_user_/www/example.com -type d -exec chmod g+s {} \;
sudo chmod g+w /home/_user_/www/example.com/wp-content
sudo chmod -R g+w /home/_user_/www/example.com/wp-content/themes
sudo chmod -R g+w /home/_user_/www/example.com/wp-content/plugins
sudo chmod -R g+w /home/_user_/www/example.com/wp-content/uploads
```

---

## Step 5: Export Database from Old Server

On the **old server**:
```bash
mysqldump -u dbuser -p dbname > example_com.sql
```

Enter the database password when prompted.

Verify the export:
```bash
ls -lh example_com.sql
```

You should see the file size (larger than 0 bytes).

---

## Step 6: Transfer and Import Database

Transfer the SQL file from **new server**:
```bash
scp user@old-server-ip:~/example_com.sql /home/_user_/
```

Import to new database:
```bash
mysql -u migrated_user -p migrated_site < /home/_user_/example_com.sql
```

Clean up:
```bash
rm /home/_user_/example_com.sql
```

On **old server**, also clean up:
```bash
ssh user@old-server-ip "rm ~/example_com.sql"
```

---

## Step 7: Update wp-config.php

Edit wp-config on the **new server**:
```bash
sudo nano /home/_user_/www/example.com/wp-config.php
```

Update database credentials:
```php
define( 'DB_NAME', 'migrated_site' );
define( 'DB_USER', 'migrated_user' );
define( 'DB_PASSWORD', 'new_secure_password' );
define( 'DB_HOST', 'localhost' );
```

Ensure these lines exist:
```php
define( 'WP_CACHE_KEY_SALT', 'example_com' );
define('FS_METHOD', 'direct');
```

Save and exit.

---

## Step 8: Configure Nginx on New Server

Create nginx configuration:
```bash
cp /etc/nginx/sites-available/template.conf /etc/nginx/sites-available/example.com.conf
sudo nano /etc/nginx/sites-available/example.com.conf
```

Replace all `_domain_name_` with `example.com`.

Enable the site:
```bash
ln -s /etc/nginx/sites-available/example.com.conf /etc/nginx/sites-enabled/example.com
sudo nginx -t
sudo service nginx reload
```

---

## Step 9: Obtain Temporary SSL Certificate

Even though DNS still points to old server, you can get a certificate using DNS challenge (if using Cloudflare):

```bash
sudo certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/.secrets/cloudflare.ini \
  -d example.com -d www.example.com
```

**OR** wait until after DNS update to get certificates via HTTP challenge.

---

## Step 10: Test Without DNS Change

Test the new server before updating DNS by editing `/etc/hosts` on your **local computer**:

**On macOS/Linux**:
```bash
sudo nano /etc/hosts
```

**On Windows**:
```
C:\Windows\System32\drivers\etc\hosts
```

Add this line (replace with your new server IP):
```
new_server_ip  example.com www.example.com
```

Save and visit `https://example.com` in your browser. You should see your site running on the new server.

**Verify**:
- Homepage loads correctly
- Admin panel accessible (`/wp-admin`)
- Images display properly
- Plugins working
- Forms submitting

**Important**: Remove this `/etc/hosts` entry when testing is complete.

---

## Step 11: Minimize Downtime (Final Sync)

To minimize downtime during final cutover:

### On Old Server: Enable Maintenance Mode
Create `.maintenance` file:
```bash
ssh user@old-server-ip
cd ~/www/example.com
echo '<?php $upgrading = time(); ?>' | sudo tee .maintenance
```

Visitors will see "Briefly unavailable for scheduled maintenance."

### Perform Final Sync

Export latest database from **old server**:
```bash
ssh user@old-server-ip
mysqldump -u dbuser -p dbname > example_com_final.sql
exit
```

Transfer and import to **new server**:
```bash
scp user@old-server-ip:~/example_com_final.sql /home/_user_/
mysql -u migrated_user -p migrated_site < /home/_user_/example_com_final.sql
rm /home/_user_/example_com_final.sql
```

Sync any new uploads:
```bash
rsync -avz user@old-server-ip:~/www/example.com/wp-content/uploads/ \
  /home/_user_/www/example.com/wp-content/uploads/
```

**Downtime**: Only 5-15 minutes during this final sync.

---

## Step 12: Update DNS

Change DNS records to point to your new server's IP:

```
A     example.com           new_server_ip
CNAME www.example.com       example.com
```

DNS propagation typically takes 5 minutes to 48 hours (usually under 1 hour).

Check propagation:
```bash
dig example.com
```

The A record should show your new server IP.

---

## Step 13: Generate Fresh SSL Certificates

If you didn't use DNS challenge earlier, now generate certificates via HTTP challenge:

```bash
sudo certbot --nginx certonly -d example.com -d www.example.com
```

Update nginx if certificate paths changed:
```bash
sudo nano /etc/nginx/sites-available/example.com.conf
```

Test and reload:
```bash
sudo nginx -t
sudo service nginx reload
```

---

## Step 14: Set Up Caching

Create cache directory:
```bash
mkdir -p /home/_user_/cache/example.com
sudo chown -R www-data:www-data /home/_user_/cache/example.com
```

In WordPress admin:
1. **Redis Object Cache**: Enable object caching
2. **Nginx Cache**: Set cache path to `/home/_user_/cache/example.com`

Disable maintenance mode if still active:
```bash
sudo rm /home/_user_/www/example.com/.maintenance
```

---

## Step 15: Verify and Clean Up

### Verify Everything Works
- Visit site in incognito/private browser
- Test all major functionality
- Check admin panel
- Monitor error logs: `tail -f /home/_user_/logs/example.com-error.log`

### Clean Up Old Server
Once confirmed working for 24-48 hours:
- Remove maintenance mode: `rm .maintenance` (if not already done)
- Keep old server running for 1-2 weeks as backup
- Cancel old server when fully confident

---

## Troubleshooting

### Site shows old content
- Check DNS propagation: `dig example.com`
- Clear browser cache
- Check your local `/etc/hosts` file

### SSL certificate errors
- Regenerate certificates after DNS update
- Verify DNS points to new server: `dig example.com`

### Database connection errors
- Verify wp-config.php credentials
- Test database connection: `mysql -u migrated_user -p migrated_site`

### Permission errors
- Re-run permission commands from Step 4

### Images missing
- Verify uploads directory transferred: `ls -la /home/_user_/www/example.com/wp-content/uploads`
- Re-run rsync sync from Step 11

---

## Summary

Your WordPress site has been successfully migrated with:
- ✅ All files transferred
- ✅ Database migrated
- ✅ Fresh SSL certificates
- ✅ Nginx configured
- ✅ Caching enabled
- ✅ Minimal downtime (5-15 minutes)

**Total migration time**: 1-2 hours (including testing)

**See Also**: [Add Another Site](Add%20Another%20Site.md) - Add more sites to this server
