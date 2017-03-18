- [Intial Setup](Initial\ Setup.md)
- **Install LEMP Stack**
- [Tweaking](Tweaking.md)
- [Wordpress](Wordpress.md)
- [System Monitoring](System\ Monitoring.md)
- [SSL Let's Encrypt](SSL\ Let's\ Encrypt.md)
- [Automation](Automation.md)

# Install LEMP

[source](https://www.digitalocean.com/community/tutorials/how-to-install-linux-nginx-mysql-php-lemp-stack-in-ubuntu-16-04)

## Install PHP

```
sudo apt-get install php-fpm php-mysql
```

Configure php-fpm

Open `www.conf`
```
sudo nano /etc/php/7.0/fpm/pool.d/www.conf
```

and remove `;` before
```
listen.mode = 0660
```

Save and exit

Open `php.ini`
```
sudo nano /etc/php/7.0/fpm/php.ini
```

Search for
```
;cgi.fix_pathinfo=1
```

using `ctrl + w` and replace it with
```
cgi.fix_pathinfo=0
```

Also, change `upload_max_filesize` and `post_max_size` to `32M` or `64M`

Save, exit and restart php-fpm
```
sudo service php7.0-fpm restart
```

## Install MySQL

```
sudo apt-get install mysql-server
```

Choose a root password, don't forget to save it.

## Install Nginx

Install nginx
```
sudo apt-get install nginx
```

Allow Nginx in the firewall
```
sudo ufw allow 'Nginx HTTP'
```

Then check status
```
sudo ufw status
```

Check if Nginx is working and if firewall is blocking
```
http://server's_public_ip
```

## Configure Nginx

First, get ownership of nginx folder
```
sudo chown -R ubuntu /etc/nginx/
```

Replace the default config
```
scp nginx/sites-available/default server_alias:/etc/nginx/sites-available/
```

Test nginx configuration for errors
```
sudo nginx -t
```

Reload nginx if no errors
```
sudo service nginx reload
```

Move default nginx contents under user folder
```
sudo mv /var/www/html/* /home/ubuntu/www/html
```

To test if everything is working, create info.php
```
sudo nano /home/ubuntu/www/html/info.php
```

Write this and save
```
<?php
phpinfo();
?>
```

Visit
```
http://server's_public_ip/info.php
```

If everything is fine, remove the file to not give any information away
```
sudo rm /home/ubuntu/www/html/info.php
```

**NEXT STEP** -> [Tweaking](Tweaking.md)
