- [Initial Setup](Initial%20Setup.md)
- **Install LEMP Stack**
- [Wordpress](Wordpress.md)
- [SSL Let's Encrypt](SSL%20Let's%20Encrypt.md)
- [Automation](Automation.md)

# Install LEMP

[source](https://spinupwp.com/hosting-wordpress-yourself-nginx-php-mysql/)

## Install PHP

Add the repository
```
sudo add-apt-repository ppa:ondrej/php -y
sudo apt update
```

Install PHP 8.5
```
sudo apt install php8.5-fpm php8.5-common php8.5-mysql \
php8.5-xml php8.5-xmlrpc php8.5-curl php8.5-gd \
php8.5-imagick php8.5-cli php8.5-dev php8.5-imap \
php8.5-mbstring php8.5-opcache php8.5-redis \
php8.5-soap php8.5-zip -y
```

Configure php-fpm

```
sudo sed -i 's/;listen.mode = 0660/listen.mode = 0660/g' /etc/php/8.5/fpm/pool.d/www.conf
sudo sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/g' /etc/php/8.5/fpm/php.ini
sudo sed -i "s/upload_max_filesize = .*/upload_max_filesize = 512M/" /etc/php/8.5/fpm/php.ini
sudo sed -i "s/post_max_size = .*/post_max_size = 512M/" /etc/php/8.5/fpm/php.ini
sudo sed -i "s/max_execution_time = .*/max_execution_time = 180/" /etc/php/8.5/fpm/php.ini
```

Check that the configuration file syntax is correct
```
sudo php-fpm8.5 -t
```

Restart php-fpm
```
sudo service php8.5-fpm restart
```

## Install MariaDB

Add the MariaDB repository for the 10.11 LTS series
```
curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | sudo bash -s -- --mariadb-server-version=10.11
```

Install MariaDB 10.11 LTS
```
sudo apt update
sudo apt install mariadb-server mariadb-client
```

Secure the installation
```
sudo mysql_secure_installation
```

**Important:** the management scripts authenticate as MySQL root with a **password**
(`MYSQL_ROOT_PASS`), so root must have one — do NOT leave it on unix_socket-only auth.

- Type `n` for "switch to unix_socket authentication" (keep password auth)
- Type `y` for "change/set the root password", choose a strong one and save it
- Type `y` to remove anonymous users
- Type `y` to disallow root login remotely
- Type `y` to remove test database and access to it
- Type `y` to reload privilege tables

If root still has no password afterward, set one explicitly:
```
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'YOUR_STRONG_PASSWORD'; FLUSH PRIVILEGES;"
```
The lifecycle scripts read this via the `MYSQL_ROOT_PASS` environment variable
(backups don't need it — they read each site's credentials from wp-config.php).

## Install Nginx

[source 1](http://www.digitalocean.com/community/tutorials/how-to-optimize-nginx-configuration)
[source 2](https://spinupwp.com/hosting-wordpress-yourself-nginx-php-mysql/)
[source 3](https://codex.wordpress.org/Nginx)

Add the official nginx **mainline** repository (the templates use `http2 on;`, which
requires nginx ≥ 1.25.1 — the Ubuntu stable 1.24 package will fail).
```
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor | sudo tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/ubuntu $(lsb_release -cs) nginx" | sudo tee /etc/apt/sources.list.d/nginx.list
printf 'Package: nginx*\nPin: origin nginx.org\nPin-Priority: 900\n' | sudo tee /etc/apt/preferences.d/nginx-org
sudo apt update
```

Install nginx
```
sudo apt install nginx -y
nginx -v   # confirm 1.25.1 or newer
```

Generate the Diffie-Hellman parameters the SSL config references (do this now, before
any site config is loaded):
```
sudo openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048
```

**Note**: The nginx mainline branch receives all new features and bug fixes. It's recommended over the stable branch by nginx.org for production use.

Allow Nginx in the firewall
```
sudo ufw allow 'Nginx Full'
```

Then check status
```
sudo ufw status
```

Check if Nginx is working and if firewall is blocking
```
http://_ip_of_the_server_
```

## Configure Nginx

First, get ownership of the nginx folder
```
sudo chown -R _user_ /etc/nginx/
```

Create a dated backup, incase the server goes crashing down!
```
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.$(date "+%b_%d_%Y_%H.%M.%S")
```

Upload custom config files [source](https://github.com/deliciousbrains/wordpress-nginx)
```
scp -r nginx/* _server_alias_:/etc/nginx/
```

In order to check how many `worker_connections` there should be we will need to take a note of
1. The number of our cpu cores
```
grep processor /proc/cpuinfo | wc -l
```

2. Our server's open file limit
```
ulimit -n
```

By multiplying these two numbers, we get our `worker_connections`

Take a note of that number and open nginx.conf
```
sudo nano /etc/nginx/nginx.conf
```

Edit `worker_connections`, save and close

Test nginx configuration for errors
```
sudo nginx -t
```

Reload nginx if no errors
```
sudo service nginx reload
```

In order for Nginx to correctly serve PHP you also need to ensure the `fastcgi_param  SCRIPT_FILENAME` directive is set, otherwise you will receive a blank white screen when accessing any PHP scripts. Open the `fastcgi_params` file:
```
sudo nano /etc/nginx/fastcgi_params
```

Due to permission changes in Ubuntu 24.04, add nginx user to your user's group:
```
gpasswd -a www-data _user_
```

Ensure the following directive exists, if not add it to the file:
```
fastcgi_param  SCRIPT_FILENAME  $document_root$fastcgi_script_name;
```

Test nginx configuration for errors
```
sudo nginx -t
```

Restart nginx if no errors
```
sudo service nginx restart
```

## Install Redis

```
sudo apt install redis-server
sudo service php8.5-fpm restart
```

**NEXT STEP** -> [Wordpress](Wordpress.md)
