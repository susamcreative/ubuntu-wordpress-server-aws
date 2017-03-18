- [Intial Setup](Initial%20Setup.md)
- [Install LEMP Stack](Install%20LEMP.md)
- [Tweaking](Tweaking.md)
- [Wordpress](Wordpress.md)
- **System Monitoring**
- [SSL Let's Encrypt](SSL%20Let's%20Encrypt.md)
- [Automation](Automation.md)

# System Monitoring with netdata

[source](https://github.com/firehol/netdata/wiki/Installation)

## Install netdata

```
sudo apt-get install zlib1g-dev uuid-dev libmnl-dev gcc make git autoconf autoconf-archive autogen automake pkg-config curl
```

Go to apps folder and download netdata inside
```
cd ~/apps
sudo git clone https://github.com/firehol/netdata.git --depth=1
```

Go to the folder and install netdata
```
cd ~/apps/netdata
sudo ./netdata-installer.sh
```

Change default port to a random number for protection
```
sudo nano /etc/netdata/netdata.conf
```

Uncomment the line containing `default port` and change it to random number and take a note of that port (Let's call it `netdata_port`)

Then restart netdata
```
sudo service netdata restart
```

## Create Firewall rules

### Amazon Security Groups

First, go to AWS to create the rule [#](https://console.aws.amazon.com/ec2/v2/home?#SecurityGroups)

Edit Inbound Rules and Create a custom TCP rule for the netdata_port and Source `Anywhere`

### ufw Firewall

Allow `netdata_port` on the firewall
```
sudo ufw allow `netdata_port`
```

## Access netdata

Bookmark the address to be able to reach it easily
```
http://ip_of_the_server:netdata_port
```

## Update netdata

Go to netdata folder, do a `git pull` and update netdata
```
cd ~/apps/netdata
git pull
sudo ./netdata-installer.sh
```

**NEXT STEP** -> [SSL Let's Encrypt](SSL\ Let's\ Encrypt.md)
