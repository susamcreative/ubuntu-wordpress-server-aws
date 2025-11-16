- **Initial Setup**
- [Install LEMP Stack](Install%20LEMP.md)
- [Wordpress](Wordpress.md)
- [SSL Let's Encrypt](SSL%20Let's%20Encrypt.md)
- [Automation](Automation.md)

# Initial Setup

[source](https://www.digitalocean.com/community/tutorials/how-to-connect-to-your-droplet-with-ssh)

## Choose a Username & Server Alias

1. Open these documents on a file editor and replace every instance of `_user_` with the username you'd like to use on your server.
2. Open these documents on a file editor and replace every instance of `_server_alias_` with the server alias you'd like to use for your server.

**PS:Anything you see in this repo that's in between underscores are placeholders to be replaced, make sure you do that for every instance.**

## Create a Server

Create an Ubuntu 24.04 LTS server with your preferred VPS provider (Hetzner, DigitalOcean, Vultr, AWS, etc.).

### Server Requirements

- **OS**: Ubuntu 24.04 LTS (64-bit)
- **RAM**: Minimum 1GB (2GB+ recommended for multiple sites)
- **Storage**: 20GB+ (to accommodate backups)
- **SSH Access**: Required

### Server Creation Steps

The exact steps vary by provider, but generally:

1. **Choose OS**: Select **Ubuntu 24.04 LTS** (not Ubuntu 22.04 or 20.04)
2. **Select Size**: Choose appropriate CPU/RAM for your needs
3. **SSH Key**: Upload or paste your SSH public key during creation
   - Most providers handle this automatically
   - No need to manually configure `.pem` files or move keys
4. **Firewall/Security**: Configure to allow:
   - **SSH** (port 22, or your custom port)
   - **HTTP** (port 80)
   - **HTTPS** (port 443)
5. **Create Server**: Complete creation and note your **server IP address**

### Update Placeholders

Open these documentation files in a text editor and replace all instances:
- `_ip_of_the_server_` → Your actual server IP address
- `_user_` → Your chosen username (e.g., `robot`, `admin`, etc.)
- `_server_alias_` → A short name for SSH config (e.g., `prod-server`)

### SSH Login

First, connect to your server:
```
ssh ubuntu@_ip_of_the_server_
```

If using a custom SSH port, specify it with `-p`:
```
ssh -p _port_number_ ubuntu@_ip_of_the_server_
```

The first time you connect, you'll see a fingerprint warning:
```
The authenticity of host '[_ip_of_the_server_]:_port_number_ ([_ip_of_the_server_]:_port_number_)' can't be established.
ECDSA key fingerprint is SHA256:CsYXAxsTdjpbTwc21AlfXId/h0FSyNct3NOdDtlmJf1.
Are you sure you want to continue connecting (yes/no)?
```

Go ahead and type `yes` to continue to connect. Here, your computer is telling you that the remote server is not recognized. Since this is your first time connecting, this is expected.

### Remote SSH Config

Skip this step if you're not using a custom SSH Port

Edit server SSH Config file, change the port and save
```
sudo nano /etc/ssh/sshd_config
```

Restart SSH service
```
sudo service sshd restart
```

### Create a New User

**Instead of using the default user, create a new user for increased security**

First, connect to your server as ubuntu user and create the new user:
```
sudo adduser _user_  --disabled-password
```

In order to remove the password requirement from the new user, open visudo
```
sudo visudo
```

At the end of the file add this:
```
# Remove password requirement for _user_
_user_ ALL=(ALL:ALL) NOPASSWD: ALL
```

Switch to the new account so that the directory and file that you create will have the proper ownership.
```
sudo su - _user_
```

Create the necessary files and open the authorized_keys file
```
mkdir .ssh
chmod 700 .ssh
touch .ssh/authorized_keys
chmod 600 .ssh/authorized_keys
nano .ssh/authorized_keys
```

Paste your SSH public key (the same one you used when creating the server), save and close the file

Login to the server with your new user:
```
ssh _user_@_ip_of_the_server_
```

Or with custom port:
```
ssh -p _port_number_ _user_@_ip_of_the_server_
```

Remove the ubuntu user
```
sudo userdel -r ubuntu
```

### Local SSH Config

Configure local ssh config file for easier connection
```
nano ~/.ssh/config
```

Create an alias using this template
```
Host _server_alias_
Hostname _ip_of_the_server_
User _user_
Port _port_number_ (remove this line if using port 22)
```

**If you're using a custom SSH port, configure your firewall to allow that port and block port 22**

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
sh -c "$(wget https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh -O -)"
```

### Customize oh-my-zsh

First get ownership of the user folder
```
sudo chown -R _user_ ~/
```

Install `Powerlevel10k Theme`
```
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k
```

Install `zsh-syntax-highlighting Plugin`
```
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting
```

Move the configuration file to server
```
scp .zshrc _server_alias_:/home/_user_/
```

Activate the configuration
```
source ~/.zshrc
```

Install `bc` to display `load`
```
sudo apt-get install bc
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
sudo ufw allow _port_number_
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

We can increase security by rate limiting using Fail2ban
```
sudo apt install fail2ban
sudo service fail2ban start
```

## Add Swap Space

[source](https://www.digitalocean.com/community/tutorials/how-to-add-swap-space-on-ubuntu-20-04)

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
/swapfile file 1024M   0B   -2
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

## Create Folder Structure

- Websites will be created under `/home/_user_/www` folder
- Logs will be under `/home/_user_/logs`
- Backups will be under `/home/_user_/backups`
- Cache will be under `/home/_user_/cache`
- Apps and scripts used will be under `/home/_user_/apps`

So, under `/home/_user_` it should look like

```
+-- apps
+-- backups
+-- cache
+-- logs
+-- www
    +-- html
    +-- website.com
```

Create the necessary folders
```
mkdir /home/_user_/apps
mkdir /home/_user_/backups
mkdir /home/_user_/cache
mkdir /home/_user_/logs
mkdir /home/_user_/www
mkdir /home/_user_/www/html
```

Set correct permissions for Ubuntu 24.04
```
chmod 775 /home/_user_/www
```

**Note**: Ubuntu 24.04 changed default home directory permissions to 750. The `chmod 775` on the www folder is required for nginx (www-data) to access your sites. Combined with the `gpasswd -a www-data _user_` command during LEMP installation, this ensures proper permissions.

**NEXT STEP** -> [Install LEMP Stack](Install%20LEMP.md)
