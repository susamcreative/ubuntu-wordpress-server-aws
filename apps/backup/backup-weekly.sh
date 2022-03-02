# Define global variables
THEDATE=`date +%y.%m.%d_%H.%M`
THEFREQ="weekly"

# Export global varibles to be used on other scripts
export THEDATE
export THEFREQ

# Go to main directory
cd /home/_user_/www/

# List of Websites
# sh /home/_user_/apps/backup/backup_template.sh

# Remove all the backups older than 3 months
sudo find /home/_user_/backups/ -name \*_weekly_\* -mtime +91 -exec rm {} \;
