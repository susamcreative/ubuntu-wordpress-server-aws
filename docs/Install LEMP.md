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
sudo apt install php8.1-fpm php8.1-common php8.1-mysql \
php8.1-xml php8.1-xmlrpc php8.1-curl php8.1-gd \
php8.1-imagick php8.1-cli php8.1-dev php8.1-imap \
php8.1-mbstring php8.1-opcache php8.1-redis \
php8.1-soap php8.1-zip -y
```

Configure php-fpm

```
sudo sed -i 's/;listen.mode = 0660/listen.mode = 0660/g' /etc/php/8.1/fpm/pool.d/www.conf
sudo sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/g' /etc/php/8.1/fpm/php.ini
sudo sed -i "s/upload_max_filesize = .*/upload_max_filesize = 256M/" /etc/php/8.1/fpm/php.ini
sudo sed -i "s/post_max_size = .*/post_max_size = 256M/" /etc/php/8.1/fpm/php.ini
```

Check that the configuration file syntax is correct
```
sudo php-fpm8.1 -t
```

Restart php-fpm
```
sudo service php8.1-fpm restart
```

## Install MariaDB

Install MariaDB
```
sudo apt install mariadb-server
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
sudo service php8.1-fpm restart
```

**NEXT STEP** -> [Wordpress](Wordpress.md)
