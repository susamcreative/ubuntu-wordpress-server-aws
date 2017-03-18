- **Intial Setup**
- [Install LEMP Stack](Install\ LEMP.md)
- [Tweaking](Tweaking.md)
- [Wordpress](Wordpress.md)
- [System Monitoring](System\ Monitoring.md)
- [SSL Let's Encrypt](SSL\ Let's\ Encrypt.md)
- [Automation](Automation.md)

# Initial Setup

[source](https://www.digitalocean.com/community/tutorials/how-to-connect-to-your-droplet-with-ssh)

## Create a Server

### Create Instance [#](https://console.aws.amazon.com/ec2)

Select `Ubuntu Server`

1. Choose AMI: Ubuntu Server
2. Choose Instance Type
3. Configure Instance
4. Add Storage: 20GB or more for keeping the backups
5. Add Tags
6. Configure Security Group
  - Add rule for HTTP: Source `Anywhere`
  - Add rule for HTTPS: Source `Anywhere`
  - Add rule for SSH: Source `Static IP` or `Anywhere`
  - Add custom rule for SSH: Create a custom TCP rule to configure the port, Source `Static IP` or `Anywhere`
7. Review

Choose an existing key pair or Create a new key pair
Move the key pair under .ssh folder and change permissions
```
chmod 400 ~/.ssh/key_pair.pem
```

Create an [Elastic IP](https://console.aws.amazon.com/ec2/v2/home?#Addresses:sort=PublicIp)

**Note**: `ubuntu` is the username for the server, if another username is used, make sure to change `ubuntu` to desired username in every file.

### SSH Login as Root

First, initiate the connection to your server
```
ssh ubuntu@SERVER_IP_ADDRESS
```

The first time you attempt to connect to your server, you will likely see a warning that looks like this:
```
The authenticity of host '123.123.123.123 (123.123.123.123)' can't be established.
ECDSA key fingerprint is SHA256:CsYXAxsTdjpbTwc21AlfXId/h0FSyNct3NOdDtlmJf1.
Are you sure you want to continue connecting (yes/no)?
```

Go ahead and type `yes` to continue to connect. Here, your computer is telling you that the remote server is not recognized. Since this is your first time connecting, this is completely expected.

**Note**: Since root login is disabled by default and `ubuntu` user has `root` privileges, there is no need for editing settings or creating another user.

### Remote SSH Config

Pass this step if not using custom SSH Port

Edit server SSH Config file, change the port and save
```
sudo nano /etc/ssh/sshd_config
```

Restart SSH service
```
sudo service sshd restart
```

### Local SSH Config

Configure local ssh config file for easier connection
```
nano ~/.ssh/config
```

Create an alias using this template
```
Host server_alias
Hostname ip_of_the_server
User username
Port custom_port (remove the line if 22)
IdentityFile ~/.ssh/key_pair.pem
```

**Remove default SSH port from security group**

## Install oh-my-zsh

**Note**: If you don't want to use `oh-my-zsh`, you can skip this part

zsh needs to be installed before `oh-my-zsh`
```
sudo apt-get install zsh
```

and it needs to be made the default shell
```
sudo chsh -s $(which zsh) `whoami`
```

And to install `oh-my-zsh`
```
sudo sh -c "$(wget https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh -O -)"
```

### Customize oh-my-zsh

First get ownership of the user folder
```
sudo chown -R ubuntu ~/
```

Install `Powerlevel9k Theme`
```
git clone https://github.com/bhilburn/powerlevel9k.git ~/.oh-my-zsh/custom/themes/powerlevel9k
```

Install `zsh-syntax-highlighting Plugin`
```
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting
```

Edit `server_alias` inside the configuration file to server
```
nano .zshrc
```

Move the configuration file to server
```
scp .zshrc server_alias:/home/ubuntu/
```

Install `bc` to display `load`
```
sudo apt-get install bc
```

Activate the configuration
```
source ~/.zshrc
```

## Do a System Update & Upgrade

Update the system
```
sudo apt-get update && sudo apt-get upgrade && sudo apt-get dist-upgrade
```

And cleanup
```
sudo apt-get autoclean && sudo apt-get autoremove
```

Restart the server
```
sudo reboot
```

## Setup a Basic Firewall

```
sudo ufw app list
```

**If using custom SSH port**: Allow custom SSH port
```
sudo ufw allow custom_port
```
**If not using custom SSH port**: Make sure `OpenSSH` is listed under `Available applications` and then, add it to allowed list
```
sudo ufw allow OpenSSH
```

Enable the firewall
```
sudo ufw enable
```

Check status of the Firewall
```
sudo ufw status
```

## Add Swap Space

[source](https://www.digitalocean.com/community/tutorials/how-to-add-swap-space-on-ubuntu-16-04)

Check if there is already a swap space
```
sudo swapon --show
```

If there is no output, then there is no swap space. Create it with these lines (size is `1GB` in this example)
```
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

Check if swap is on
```
sudo swapon --show
```

Example output
```
NAME      TYPE  SIZE USED PRIO
/swapfile file 1024M   0B   -1
```

To make swap permanent
```
sudo cp /etc/fstab /etc/fstab.bak
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

To tweak the settings open `sysctl.conf`
```
sudo nano /etc/sysctl.conf
```

Add these lines to the end of the file and save
```
vm.swappiness=10
vm.vfs_cache_pressure=50
```

## Install htop

```
sudo apt-get install htop
```

## System Usage on Welcome Message

Install `landscape-common`
```
sudo apt-get install landscape-common
```

## Folder Structure

Websites will be created under `/home/ubuntu/www` folder
Logs will be under `/home/ubuntu/logs`
And apps and scripts used will be under `/home/ubuntu/apps`

So, under `/home/ubuntu` it should look like

```
+-- apps
+-- logs
+-- www
    +-- html
    +-- website.com
```

Create the necessary folders
```
mkdir /home/ubuntu/apps
mkdir /home/ubuntu/logs
mkdir /home/ubuntu/www
mkdir /home/ubuntu/www/html
```

**NEXT STEP** -> [Install LEMP Stack](Install\ LEMP.md)
