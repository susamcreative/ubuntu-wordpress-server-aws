- [Intial Setup](Initial%20Setup.md)
- [Install LEMP Stack](Install%20LEMP.md)
- [Wordpress](Wordpress.md)
- **SSL Let's Encrypt**
- [Automation](Automation.md)

# SSL Let's Encrypt

[source](https://www.digitalocean.com/community/tutorials/how-to-secure-nginx-with-let-s-encrypt-on-ubuntu-16-04)

## Install Certbot

```
sudo apt install software-properties-common
sudo add-apt-repository universe
sudo apt update
sudo apt install certbot python3-certbot-nginx
```

Now, get the SSL certificate with following command
```
sudo certbot --nginx certonly -d _domain_name_ -d www._domain_name_
```

## Generate Strong Diffie-Hellman Group

This is only needed once per server
```
sudo openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048
```

## Configure TLS/SSL on nginx

Reconfigure the nginx.conf of the website, according to `template.conf`

**Note**: `_domain_name_` is the website's domain name without `www` in the beginning.
```
cp /etc/nginx/sites-available/template.conf /etc/nginx/sites-available/_domain_name_.conf
sudo nano /etc/nginx/sites-available/_domain_name_.conf
```

Change all instances of `_domain_name_` in the file with the website address

## Enable the Changes & Test

Check if there are no errors in nginx
```
sudo nginx -t
```

If it's fine, reload
```
sudo service nginx reload
```

Test the SSL certificate, this setup should get an A+
```
https://www.ssllabs.com/ssltest/analyze.html?d=_domain_name_
```

## Setup Auto Renewal

Let’s Encrypt certificates are valid for 90 days, but it’s recommended that you renew the certificates every 60 days to allow a margin of error.

To manually trigger a renewal, following line should be entered
```
sudo letsencrypt renew
```

Let's Encrypt only renews certificates if it's less than 30 days away from expiration. A cron job can be created to renew the certificates when needed.

To edit the crontab
```
sudo crontab -e
```

And add these lines
```
# Let's Encrypt Certificate Renewal
30 0 * * 1 /usr/bin/letsencrypt renew >> /home/_user_/logs/le-renew.log
35 0 * * 1 /bin/systemctl reload nginx
```

This will create a new cron job that will execute the `letsencrypt renew` command every Monday at 0:30, and reload Nginx at 0:35 (so the renewed certificate will be used). The output produced by the command will be piped to a log file located at `/home/_user_/logs/le-renewal.log`.

**NEXT STEP** -> [Automation](Automation.md)
