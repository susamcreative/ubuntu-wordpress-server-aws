- [Intial Setup](Initial%20Setup.md)
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

Install php
```
sudo apt install php8.0-fpm php8.0-common php8.0-mysql \
php8.0-xml php8.0-xmlrpc php8.0-curl php8.0-gd \
php8.0-imagick php8.0-cli php8.0-dev php8.0-imap \
php8.0-mbstring php8.0-opcache php8.0-redis \
php8.0-soap php8.0-zip -y
```

Configure php-fpm

```
sudo sed -i 's/;listen.mode = 0660/listen.mode = 0660/g' /etc/php/8.0/fpm/pool.d/www.conf
sudo sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/g' /etc/php/8.0/fpm/php.ini
sudo sed -i "s/upload_max_filesize = .*/upload_max_filesize = 128M/" /etc/php/8.0/fpm/php.ini
sudo sed -i "s/post_max_size = .*/post_max_size = 128M/" /etc/php/8.0/fpm/php.ini
```

Check that the configuration file syntax is correct
```
sudo php-fpm8.0 -t
```

Restart php-fpm
```
sudo service php8.0-fpm restart
```

## Install MariaDB

Add the repository and update the package lists
```
sudo apt-get install software-properties-common
sudo apt-key adv --fetch-keys 'https://mariadb.org/mariadb_release_signing_key.asc'
sudo add-apt-repository 'deb [arch=amd64,arm64,ppc64el] http://mirrors.up.pt/pub/mariadb/repo/10.4/ubuntu focal main'
```

Install MariaDB
```
sudo apt install mariadb-server -y
```

Secure the installation
```
sudo mysql_secure_installation
```

Choose a password and don't forget to save it.

- Type `y` to switch to unix_socket authentication.
- Type `n` to change the root password.
- Type `y` to remove anonymous users.
- Type `y` to disallow root login remotely.
- Type `y` to remove test database and access to it.
- Type `y` to reload privilage tables.

## Install Nginx

[source 1](http://www.digitalocean.com/community/tutorials/how-to-optimize-nginx-configuration)
[source 2](https://spinupwp.com/hosting-wordpress-yourself-nginx-php-mysql/)
[source 3](https://codex.wordpress.org/Nginx)

Add the repository and update the package lists
```
sudo add-apt-repository ppa:ondrej/nginx -y
sudo apt update
sudo apt dist-upgrade -y
```

Install nginx
```
sudo apt install nginx -y
```

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
sudo service php8.0-fpm restart
```

**NEXT STEP** -> [Wordpress](Wordpress.md)
