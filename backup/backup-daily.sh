# Define global variables
THEDATE=`date +%y.%m.%d_%H.%M`
THEFREQ="daily"

# Export global varibles to be used on other scripts
export THEDATE
export THEFREQ

# Go to main directory
cd /home/ubuntu/www/

# List of Websites
sh /home/ubuntu/apps/backup/backup_template.sh

# Remove all the backups older than 4 weeks
sudo find /home/ubuntu/backups/ -name \*_daily_\* -mtime +31 -exec rm {} \;
