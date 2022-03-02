- **Intial Setup**
- [Install LEMP Stack](Install%20LEMP.md)
- [Wordpress](Wordpress.md)
- [SSL Let's Encrypt](SSL%20Let's%20Encrypt.md)
- [Automation](Automation.md)

# Initial Setup

[source](https://www.digitalocean.com/community/tutorials/how-to-connect-to-your-droplet-with-ssh)

## Choose a Username & a Server Alias

1. Open these documents on a file editor and replace every instance of `_user_` with the username you'd like to use on your server.
2. Open these documents on a file editor and replace every instance of `_server_alias_` with the server alias you'd like to use for your server.

**PS:Anything you see in this repo that's in between underscores are placeholders to be replaced, make sure you do that for every instance.**

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

8. Create an [Elastic IP](https://console.aws.amazon.com/ec2/v2/home?#Addresses:sort=PublicIp)
9. Open these documents on a file editor and change every instance of `_ip_of_the_server_` to the ip of your server.

### SSH Login

First, initiate the connection to your server after replacing ever instance of `_ssh_key_` with the key name you use and the `_port_number_` with your custom port number, if not replace it with `22`
```
ssh -i _ssh_key_ ubuntu@_ip_of_the_server_
```

The first time you attempt to connect to your server, you will likely see a warning that looks like this:
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

[source](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/managing-users.html)

**Instead of using the default user, we are going to create a new user in order to increase security**

Retrieve the public key from the key pair that you created
```
ssh-keygen -y -f .ssh/_ssh_key_
```

The command will return the public key, **copy it**, we will use this for our new user

Then login to the ubuntu user using ssh
```
ssh -i _ssh_key_ -p _port_number_ ubuntu@_ip_of_the_server_
```

Create the new user
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

Paste the public key you retrieved, save and close the file

Login to the server with your new user
```
ssh -i _ssh_key_ -p _port_number_ _user_@_ip_of_the_server_
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
Port _port_number_ (remove the line if 22)
IdentityFile ~/.ssh/key_pair.pem
```

**If you're using a custom ssh port, remove default SSH port from security group**

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

**NEXT STEP** -> [Install LEMP Stack](Install%20LEMP.md)
