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

## Certificate Auto-Renewal

Let's Encrypt certificates are valid for 90 days, but it's recommended that you renew the certificates every 60 days to allow a margin of error.

### Automatic Renewal (Ubuntu 24.04)

Ubuntu 24.04 automatically configures certificate renewal via systemd timer. Verify it's active:
```
systemctl list-timers | grep certbot
```

You should see `certbot.timer` scheduled to run twice daily.

Check the timer status:
```
sudo systemctl status certbot.timer
```

### Manual Renewal (Testing)

To manually test renewal without waiting:
```
sudo certbot renew --dry-run
```

To force renewal:
```
sudo certbot renew
```

After renewal, nginx automatically reloads via the systemd timer.

### Cloudflare DNS Challenge (Optional)

If you need wildcard certificates or DNS-based verification, install the Cloudflare plugin:
```
sudo apt install python3-certbot-dns-cloudflare
```

Create Cloudflare credentials file:
```
sudo mkdir -p /etc/letsencrypt/.secrets
sudo nano /etc/letsencrypt/.secrets/cloudflare.ini
```

Add your Cloudflare API token:
```
dns_cloudflare_api_token = YOUR_API_TOKEN_HERE
```

Secure the file:
```
sudo chmod 600 /etc/letsencrypt/.secrets/cloudflare.ini
```

Obtain wildcard certificate:
```
sudo certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/.secrets/cloudflare.ini \
  -d example.com -d "*.example.com"
```

**Note**: Renewal happens automatically via the systemd timer for all certificates, including DNS-validated ones.

**NEXT STEP** -> [Automation](Automation.md) - Set up automated backups for your site
