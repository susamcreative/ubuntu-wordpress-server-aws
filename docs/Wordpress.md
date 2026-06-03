- [Initial Setup](Initial%20Setup.md)
- [Install LEMP Stack](Install%20LEMP.md)
- **Wordpress**
- [SSL Let's Encrypt](SSL%20Let's%20Encrypt.md)
- [Automation](Automation.md)

# Wordpress

[source](https://www.digitalocean.com/community/tutorials/how-to-install-wordpress-with-lemp-on-ubuntu-20-04)

## Configure DNS Records

Using your domain's DNS management panel (your hosting provider, Cloudflare, or domain registrar), create the following records:

```
A     example.com           your_server_ip
CNAME www.example.com       example.com
```

If you use email services with this domain, also create appropriate MX and TXT records as needed.

**Note**: DNS propagation can take up to 48 hours, but usually completes within minutes to a few hours. You can check propagation status with `dig example.com` or online DNS checkers.

## Create nginx Configuration

Create a new configuration using the template

**Note**: `_domain_name_` is the website's domain name without `www` in the beginning.
```
cp /etc/nginx/sites-available/template.conf /etc/nginx/sites-available/_domain_name_.conf
sudo nano /etc/nginx/sites-available/_domain_name_.conf
```

**Note**: If you are not planning to get an ssl certificate, you should use the `template_no_ssl.conf` instead of `template.conf` as your template.

Change all instances of `_domain_name_` in the file with the website address

**Note**: Folder name under /home/_user_/www/ needs to be the same as domain name.

Save and exit

Create a symlink for the configuration file
```
ln -s  /etc/nginx/sites-available/_domain_name_.conf  /etc/nginx/sites-enabled/_domain_name_
```

Test nginx configuration
```
sudo nginx -t
```

If everything is fine, reload nginx config
```
sudo service nginx reload
```

## Create a Database

Log into MariaDB with the root user
```
mysql -u root -p
```

Enter your password

Create the new database
```
CREATE DATABASE _database_name_ CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;
```

Create the user for the new database
```
CREATE USER '_database_username_'@'localhost' IDENTIFIED BY '_database_password_';
```

Grant privileges
```
GRANT ALL PRIVILEGES ON _database_name_.* TO '_database_username_'@'localhost';
```

Flush privileges
```
FLUSH PRIVILEGES;
```

Grant privileges
```
exit;
```

## Download wordpress

Create the website directory and download wordpress
```
sudo mkdir /home/_user_/www/_domain_name_
cd /home/_user_/www/_domain_name_
sudo curl -O https://wordpress.org/latest.tar.gz
```

Extract wordpress from the archive
```
sudo tar xzf latest.tar.gz
```

Move files to the main directory and remove the unnecessary files
```
cd wordpress
sudo mv * ../
cd ..
sudo rm -r wordpress latest.tar.gz
```

Create `upgrade` directory, so there wouldn't be permission issues
```
sudo mkdir wp-content/upgrade
```

Create wp-config
```
sudo cp wp-config-sample.php wp-config.php
```

## Permissions

For detailed information about how and why permissions are set this way, read the [source](https://www.digitalocean.com/community/tutorials/how-to-install-wordpress-with-lemp-on-ubuntu-16-04)

```
sudo chown -R _user_:www-data /home/_user_/www/_domain_name_
sudo find /home/_user_/www/_domain_name_ -type d -exec chmod g+s {} \;
```

Now, let's allow wordpress to install and modify themes and plugins
```
sudo chmod g+w /home/_user_/www/_domain_name_/wp-content
sudo chmod -R g+w /home/_user_/www/_domain_name_/wp-content/themes
sudo chmod -R g+w /home/_user_/www/_domain_name_/wp-content/plugins
sudo chmod -R g+w /home/_user_/www/_domain_name_/wp-content/uploads
```

**Note**: These permissions won't allow wordpress to do an update. Permission changes for updates will be explained later in this guide.

## Set up wp-config.php

```
curl -s https://api.wordpress.org/secret-key/1.1/salt/
```

Copy the output and open `wp-config.php`
```
sudo nano /home/_user_/www/_domain_name_/wp-config.php
```

Paste the output value

Edit `DB_NAME`, `DB_USER` and `DB_PASSWORD`


On top of the file, add
```
define( 'WP_CACHE_KEY_SALT', '_salt_' );
```

Get a 256-bit WEP Key from https://randomkeygen.com/ and change `_salt_` to the key you got

At the end of the file, add the line
```
define('FS_METHOD', 'direct');
```

Save and exit

## Complete the Installation

Complete the installation through browser
```
http://_domain_name_
```

## Install Caching Plugins

For object caching install Redis Object Cache by Till Krüss

For page caching install Nginx Cache by Till Krüss

Go to Tools -> Nginx Cache and change `Cache Zone Path` to `/home/_user_/cache/_domain_name_`

## Register the Site

Tell the management system about this site by creating its **registry record**. This is what makes it visible to backups, health checks, and safe removal. The registry is the single source of truth for which database and files belong to each site, so removal and restore never have to guess.

```bash
cp ~/apps/sites.d/example.com.conf.example ~/apps/sites.d/_domain_name_.conf
nano ~/apps/sites.d/_domain_name_.conf
```

Fill in the fields to match what you just created — `DOMAIN`, `DB_NAME`, `DB_USER`, `TABLE_PREFIX`, `DOC_ROOT` (`/home/_user_/www/_domain_name_`), and `BACKUP_FREQ`. Verify it:

```bash
~/apps/list-sites.sh        # the site appears, cross-checked against reality
```

(When you use `create-site.sh` instead of these manual steps, the record is written for you.)

## Upgrade Wordpress

When there is an update available, login to the server and change permissions
```
sudo chown -R www-data /home/_user_/www/_domain_name_
```

When update is finished, change the permissions again for security reasons
```
sudo chown -R _user_ /home/_user_/www/_domain_name_
```

**NEXT STEP** -> [SSL Let's Encrypt](SSL%20Let's%20Encrypt.md)