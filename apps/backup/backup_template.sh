# Define variables for the site
THESITE="website_folder_name"
THEDB="db_name"
THEDBUSER="db_user"
THEDBPW="db_password"

# Take backup of the database
mysqldump -u $THEDBUSER -p${THEDBPW} $THEDB | gzip > /home/_user_/www/$THESITE/${THESITE}_${THEDATE}.sql.gz
# Archive the folder containing sql backup without cache and put it under /home/_user_/backups/website_folder_name/
sudo tar -czf /home/_user_/backups/${THESITE}/${THESITE}_${THEFREQ}_${THEDATE}.tar.gz --exclude='wp-content/cache' $THESITE
# Remove the sql backup from the website folder
sudo rm /home/_user_/www/$THESITE/*.sql.gz