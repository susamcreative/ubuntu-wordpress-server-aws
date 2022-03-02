- [Intial Setup](Initial%20Setup.md)
- [Install LEMP Stack](Install%20LEMP.md)
- [Wordpress](Wordpress.md)
- [SSL Let's Encrypt](SSL%20Let's%20Encrypt.md)
- **Automation**

# Automation

## Wordpress Backup Script

[source](http://lifehacker.com/5885392/automatically-back-up-your-web-site-every-night)

Create the necessary folders for backups and create folders for every website
```
mkdir ~/backups
mkdir ~/backups/website_folder_name
```

Upload `apps` folder to the server inside the user folder
```
scp -r apps _server_alias_:/home/_user_/
```

Create a new file using `backup_template.sh`
```
cp ~/apps/backup/backup_template.sh ~/apps/backup/site-website_folder_name.sh
```

**How it works**: *`backup_template.sh` includes the variables for the websites, it backs up the website folder including the database inside the main directory.*

Edit website variables
```
nano ~/apps/backup/site-website_folder_name.sh
```

Save it and close.
After repeating this procedure for every website that needs to be backed up, include them inside `backup-daily.sh`, `backup-weekly.sh` or `backup-monthly` depending on your needs.

**How it works**: *`backup-daily.sh` or other variants run the website scripts that was specified and remove the old backups.*

## Automate Wordpress Backups

Create a crontab entry to run `backup-daily.sh`, `backup-weekly.sh` and `backup-monthly`
```
sudo crontab -e
```

And add these lines
```
# Wordpress Auto Backup
00 2 * * * sh /home/_user_/apps/backup/backup-daily.sh >> /home/_user_/logs/backup.log 2>&1
30 2 * * 1 sh /home/_user_/apps/backup/backup-weekly.sh >> /home/_user_/logs/backup.log 2>&1
00 3 1 * * sh /home/_user_/apps/backup/backup-monthly.sh >> /home/_user_/logs/backup.log 2>&1
```

This will create a new cron job that will execute `backup-daily.sh` command everyday at 2:00, `backup-weekly.sh` command every Monday at 2:30 and `backup-monthly.sh` command on 1st day of every month at 3:00. The output produced by the commands will be piped to a log file located at `/home/_user_/logs/backup.log`.
