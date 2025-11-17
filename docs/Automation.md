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
00 2 * * * /home/_user_/apps/backup.sh daily >> /home/_user_/logs/backup.log 2>&1
30 2 * * 1 /home/_user_/apps/backup.sh weekly >> /home/_user_/logs/backup.log 2>&1
00 3 1 * * /home/_user_/apps/backup.sh monthly >> /home/_user_/logs/backup.log 2>&1
```

This will execute:
- **Daily backups**: Every day at 2:00 AM
- **Weekly backups**: Every Monday at 2:30 AM
- **Monthly backups**: 1st day of each month at 3:00 AM

All output is logged to `/home/_user_/logs/backup.log`.

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