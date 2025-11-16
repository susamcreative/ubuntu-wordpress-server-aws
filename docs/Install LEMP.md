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

Install PHP 8.4
```
sudo apt install php8.4-fpm php8.4-common php8.4-mysql \
php8.4-xml php8.4-xmlrpc php8.4-curl php8.4-gd \
php8.4-imagick php8.4-cli php8.4-dev php8.4-imap \
php8.4-mbstring php8.4-opcache php8.4-redis \
php8.4-soap php8.4-zip -y
```

Configure php-fpm

```
sudo sed -i 's/;listen.mode = 0660/listen.mode = 0660/g' /etc/php/8.4/fpm/pool.d/www.conf
sudo sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/g' /etc/php/8.4/fpm/php.ini
sudo sed -i "s/upload_max_filesize = .*/upload_max_filesize = 512M/" /etc/php/8.4/fpm/php.ini
sudo sed -i "s/post_max_size = .*/post_max_size = 512M/" /etc/php/8.4/fpm/php.ini
sudo sed -i "s/max_execution_time = .*/max_execution_time = 180/" /etc/php/8.4/fpm/php.ini
```

Check that the configuration file syntax is correct
```
sudo php-fpm8.4 -t
```

Restart php-fpm
```
sudo service php8.4-fpm restart
```

## Install MariaDB

Add the MariaDB repository for the latest LTS version
```
curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | sudo bash -s -- --mariadb-server-version=11.8
```

Install MariaDB 11.8 LTS
```
sudo apt update
sudo apt install mariadb-server mariadb-client
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
- Type `y` to reload privilege tables.

## Install Nginx

[source 1](http://www.digitalocean.com/community/tutorials/how-to-optimize-nginx-configuration)
[source 2](https://spinupwp.com/hosting-wordpress-yourself-nginx-php-mysql/)
[source 3](https://codex.wordpress.org/Nginx)

Add the nginx mainline repository and update the package lists
```
sudo add-apt-repository ppa:ondrej/nginx-mainline -y
sudo apt update
sudo apt dist-upgrade -y
```

Install nginx
```
sudo apt install nginx -y
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
sudo service php8.4-fpm restart
```

**NEXT STEP** -> [Wordpress](Wordpress.md)
