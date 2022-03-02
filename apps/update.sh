#!/bin/sh
sudo apt-get update && sudo apt-get upgrade && sudo apt-get dist-upgrade
sudo apt-get autoclean && sudo apt-get autoremove
cd /home/_user_/.oh-my-zsh/
git pull
cd /home/_user_/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/
git pull
cd /home/_user_/.oh-my-zsh/custom/themes/powerlevel10k/
git pull
