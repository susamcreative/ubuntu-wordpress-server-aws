# Define variables for the site
THESITE="website_folder_name"
THEDB="db_name"
THEDBUSER="db_user"
THEDBPW="db_password"

# Take backup of the database
mysqldump -u $THEDBUSER -p${THEDBPW} $THEDB | gzip > /home/ubuntu/www/$THESITE/${THESITE}_${THEDATE}.sql.gz
# Archive the folder containing sql backup without cache and put it under /home/ubuntu/backups/website_folder_name/
sudo tar -czf /home/ubuntu/backups/${THESITE}/${THESITE}_${THEFREQ}_${THEDATE}.tar.gz $THESITE --exclude='wp-content/cache'
# Remove the sql backup from the website folder
sudo rm /home/ubuntu/www/$THESITE/*.sql.gz
