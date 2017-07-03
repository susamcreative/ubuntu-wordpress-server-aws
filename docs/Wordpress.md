- [Intial Setup](Initial%20Setup.md)
- [Install LEMP Stack](Install%20LEMP.md)
- [Tweaking](Tweaking.md)
- **Wordpress**
- [System Monitoring](System%20Monitoring.md)
- [SSL Let's Encrypt](SSL%20Let's%20Encrypt.md)
- [Automation](Automation.md)

# Wordpress

[source](https://www.digitalocean.com/community/tutorials/how-to-install-wordpress-with-lemp-on-ubuntu-16-04)

## Set Up a Website

### Set up a Domain on Route 53 [#](https://console.aws.amazon.com/route53/home)

Make sure you have the following records
```
A website_address server_ip
CNAME *.website_address website_address
```

Then create MX, TXT records if needed.

### Create a Database

Open phpmyadmin from `http://server's_public_ip/phpmyadmin_random_name`

Create a database and create a user.

Take a note of the db name, username and password.

### Create nginx Configuration

Create a new configuration using the template

**Note**: `domain_name` is the website's domain name without `www` in the beginning.
```
cp /etc/nginx/sites-available/template_before_ssl.conf /etc/nginx/sites-available/domain_name.conf
sudo nano /etc/nginx/sites-available/domain_name.conf
```

**Note**: If you are not planning to get an ssl certificate, you should use the `template_no_ssl.conf` instead of `template_before_ssl.conf` as your template.

Change all instances of `domain_name` in the file with the website address

**Note**: Folder name under /home/ubuntu/www/ needs to be the same as domain name.

Save and exit

Create a symlink for the configuration file
```
ln -s  /etc/nginx/sites-available/domain_name.conf  /etc/nginx/sites-enabled/domain_name
```

Test nginx configuration
```
sudo nginx -t
```

If everything is fine, reload nginx config
```
sudo service nginx reload
```

### Download wordpress

Create the website directory and download wordpress
```
sudo mkdir /home/ubuntu/www/domain_name
cd /home/ubuntu/www/domain_name
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

### Permissions

For detailed information about how and why permissions are set this way, read the [source](https://www.digitalocean.com/community/tutorials/how-to-install-wordpress-with-lemp-on-ubuntu-16-04)

```
sudo chown -R ubuntu:www-data /home/ubuntu/www/domain_name
sudo find /home/ubuntu/www/domain_name -type d -exec chmod g+s {} \;
```

Now, let's allow wordpress to install and modify themes and plugins
```
sudo chmod g+w /home/ubuntu/www/domain_name/wp-content
sudo chmod -R g+w /home/ubuntu/www/domain_name/wp-content/themes
sudo chmod -R g+w /home/ubuntu/www/domain_name/wp-content/plugins
sudo chmod -R g+w /home/ubuntu/www/domain_name/wp-content/uploads
```

**Note**: These permissions won't allow wordpress to do an update. Permissions change for update will be explained later in this guide.

### Set up wp-config.php

```
curl -s https://api.wordpress.org/secret-key/1.1/salt/
```

Copy the output and open `wp-config.php`
```
sudo nano /home/ubuntu/www/domain_name/wp-config.php
```

Edit `DB_NAME`, `DB_USER` and `DB_PASSWORD`

Paste the output value

At the end of the file, add the line
```
define('FS_METHOD', 'direct');
```

Save and exit

### Complete the Installation

Complete the installation through browser
```
http://domain_name
```

### Upgrade Wordpress

When there is an update available, login to the server and change permissions
```
sudo chown -R www-data /home/ubuntu/www/domain_name
```

When update is finished, change the permissions again for security reasons
```
sudo chown -R ubuntu /home/ubuntu/www/domain_name
```

**NEXT STEP** -> [System Monitoring](System%20Monitoring.md)
