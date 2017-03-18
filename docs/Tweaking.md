- [Intial Setup](Initial Setup.md)
- [Install LEMP Stack](Install LEMP.md)
- **Tweaking**
- [Wordpress](Wordpress.md)
- [System Monitoring](System Monitoring.md)
- [SSL Let's Encrypt](SSL Let's Encrypt.md)
- [Automation](Automation.md)

# Tweaking

[source](https://www.digitalocean.com/community/tutorials/how-to-install-wordpress-with-lemp-on-ubuntu-16-04)

## Install Additional PHP Extensions

```
sudo apt-get update
sudo apt-get install php-curl php-gd php-mbstring php-mcrypt php-xml php-xmlrpc
```

Then restart php
```
sudo service php7.0-fpm restart
```

## Install PHPmyadmin

[source](https://www.digitalocean.com/community/tutorials/how-to-install-and-secure-phpmyadmin-with-nginx-on-an-ubuntu-14-04-server)

```
sudo add-apt-repository ppa:nijel/phpmyadmin
sudo apt-get install phpmyadmin
```

Clickt `tab` to select `ok` when prompted about the web servers
Then select `yes` when asked for `dbconfig-common` and enter the `root` password for MySQL

Create a shortcut for PHPmyadmin
```
sudo ln -s /usr/share/phpmyadmin /home/ubuntu/www/html
```

and change the address for protection
```
sudo mv /home/ubuntu/www/html/phpmyadmin /home/ubuntu/www/html/phpmyadmin_random_name
```

Test the address
```
http://server's_ip_address/phpmyadmin_random_name
```

## Tweak nginx.conf

[source 1](http://www.digitalocean.com/community/tutorials/how-to-optimize-nginx-configuration)
[source 2](https://deliciousbrains.com/hosting-wordpress-yourself-nginx-php-mysql/)
[source 3](https://codex.wordpress.org/Nginx)

Preserve a dated backup, incase the server goes crashing down!
```
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.$(date "+%b_%d_%Y_%H.%M.%S")
```

Replace nginx.conf
```
scp nginx/nginx.conf server_alias:/etc/nginx/
```

Check how many `worker_connections` there should be
```
ulimit -n
```

Take a note of it and open nginx.conf
```
sudo nano /etc/nginx/nginx.conf
```

Edit `worker_connections` with the result you got from `ulimit -n`

Save and close

Test nginx configuration for errors
```
sudo nginx -t
```

Reload nginx if no errors
```
sudo service nginx reload
```

## nginx Globals

Upload `Globals` folder and templates to the server

```
scp -r nginx/globals server_alias:/etc/nginx/
scp -r nginx/sites-available/* server_alias:/etc/nginx/sites-available/
```

**NEXT STEP** -> [Wordpress](Wordpress.md)
