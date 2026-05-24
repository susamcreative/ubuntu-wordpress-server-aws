- [Initial Setup](Initial%20Setup.md)
- [Install LEMP Stack](Install%20LEMP.md)
- [Wordpress](Wordpress.md)
- [SSL Let's Encrypt](SSL%20Let's%20Encrypt.md)
- **Automation**

---

**Additional Workflows**: [Add Another Site](Add%20Another%20Site.md) | [Migrate Existing Site](Migrate%20Existing%20Site.md)

# Automation

## WordPress Backup Script

The backup system uses a single consolidated script (`backup.sh`) that manages all site backups with cascading frequency logic.

### How It Works

**Automated Configuration**: Sites are automatically added to the backup configuration when using `add-site.sh`. The script prompts for backup frequency (daily, weekly, or monthly) and adds the site to the configuration.

**Cascading Backup Logic**:
- **Daily backups** → backs up sites configured as "daily"
- **Weekly backups** → backs up sites configured as "daily" OR "weekly"
- **Monthly backups** → backs up ALL sites (daily, weekly, AND monthly)

This ensures that every site gets at least monthly backups, while critical sites can receive daily backups.

**Security**: Database credentials are read from each site's `wp-config.php` on-the-fly. No credentials are stored in the backup script.

**Retention Policy**:
- Daily backups: 31 days (4 weeks)
- Weekly backups: 91 days (3 months)
- Monthly backups: 366 days (12 months)

### Manual Site Configuration

If you need to manually add a site to backups (not using `add-site.sh`), edit the backup script:

```bash
nano ~/apps/backup.sh
```

Add your site to the SITES array:
```bash
SITES=(
    "example.com:daily"
    "anothersite.com:weekly"
    "testsite.dev:monthly"
)
```

**Format**: `"domain:frequency"` where frequency is `daily`, `weekly`, or `monthly`

Make sure the backup directory exists:
```bash
mkdir -p ~/backups/yourdomain.com
```

### Testing Backups

Run a manual backup to test:
```bash
# Test daily backup
~/apps/backup.sh daily

# Test weekly backup
~/apps/backup.sh weekly

# Test monthly backup
~/apps/backup.sh monthly
```

Check the backup was created:
```bash
ls -lah ~/backups/yourdomain.com/
```

## Automate WordPress Backups

Create a crontab entry to run the backup script on schedule:
```
sudo crontab -e
```

Add these lines:
```
# WordPress Auto Backup
00 2 * * * cd /home/_user_/apps && /bin/bash ./backup.sh daily >> /home/_user_/logs/backup.log 2>&1
30 2 * * 1 cd /home/_user_/apps && /bin/bash ./backup.sh weekly >> /home/_user_/logs/backup.log 2>&1
00 3 1 * * cd /home/_user_/apps && /bin/bash ./backup.sh monthly >> /home/_user_/logs/backup.log 2>&1
```

This will execute:
- **Daily backups**: Every day at 2:00 AM
- **Weekly backups**: Every Monday at 2:30 AM
- **Monthly backups**: 1st day of each month at 3:00 AM

All output is logged to `/home/_user_/logs/backup.log`. Backup command errors are logged to `/home/_user_/logs/backup-errors.log`.

The cron entries can live in root's crontab for unattended permission safety. The backup script resolves `/home/_user_` from its own location, so it does not depend on `whoami`.

### Monitoring Backups

Check backup status for all sites:
```bash
~/apps/list-sites.sh
```

View backup log:
```bash
tail -f ~/logs/backup.log
```

Check recent backups for a specific site:
```bash
ls -lht ~/backups/yourdomain.com/ | head -10
```


## Automate Log Cleaning

Logs left unattended can grow big in size. In order to clean them up, we will utilize logrotate.

Move the site-logs file to the server.
```
scp site-logs _server_alias_:/home/_user_/
```

Move the file to the right location.
```
mv /home/_user_/site-logs /etc/logrotate.d/
```


## WordPress Health & SSL Monitoring

The health check script (`health-check.sh`) monitors server and site health, SSL certificate expiration, and backup freshness. It can send webhook notifications when issues are detected.

### What It Monitors

**System Health:**
- Disk space (/, /var, /tmp) - Warns at 80%, critical at 90%
- MySQL service status and database connectivity
- Nginx service status and configuration validity
- PHP-FPM service status (auto-detects version)
- Redis service status and connectivity

**Site Health (per WordPress site):**
- HTTP availability (checks for 200/301/302 responses)
- SSL certificate expiration (warns at 30 days, critical at 7 days)
- Backup freshness based on configured frequency
- Error log entries from last 24 hours (warns at 10+, critical at 50+)
- Database connectivity per site

**SSL & Backups:**
- SSL renewal failures (parses certbot logs)
- Backup cron job execution status

### Webhook Notifications

Configure webhook notifications by editing the script:

```bash
nano ~/apps/health-check.sh
```

Set your webhook URL:
```bash
WEBHOOK_URL="https://hook.make.com/your-webhook-id"
```

The script sends JSON payloads with issue details. Works with Make.com, Zapier, n8n, or custom endpoints.

**Alert Throttling:** The same alert won't be sent more than once per 24 hours unless severity increases (warning → critical).

**JSON Payload Example:**
```json
{
  "timestamp": "2025-01-17T14:30:00Z",
  "hostname": "web-server-01",
  "level": "WARNING",
  "summary": "3 issues detected",
  "issues": [
    {
      "id": "disk_var_critical",
      "category": "disk",
      "severity": "critical",
      "resource": "/var",
      "message": "Disk usage at 92%",
      "details": {
        "used": "45GB",
        "total": "49GB",
        "percent": 92
      },
      "action": "Clean up old files or expand storage"
    }
  ]
}
```

### Testing Health Checks

Run a manual check:
```bash
~/apps/health-check.sh
```

Run in quiet mode (only show issues):
```bash
~/apps/health-check.sh --quiet
```

Force webhook notification (even if all OK):
```bash
~/apps/health-check.sh --force
```

Check the log:
```bash
tail -f ~/logs/health-check.log
```

## Automate Health Monitoring

Create a crontab entry:
```
sudo crontab -e
```

Add this line:
```
# WordPress Health Monitoring (runs hourly)
0 * * * * cd /home/_user_/apps && /bin/bash ./health-check.sh >> /home/_user_/logs/health-check.log 2>&1
```

This will run health checks every hour and log all output to `/home/_user_/logs/health-check.log`. Like the backup script, the health check resolves paths from its own location so root cron does not inspect `/home/root`.
