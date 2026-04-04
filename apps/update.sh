#!/bin/bash
set -euo pipefail

# System updates
sudo apt update && sudo apt upgrade -y && sudo apt dist-upgrade -y
sudo apt autoclean && sudo apt autoremove -y

# Oh-my-zsh and plugins
USER_HOME="/home/$(whoami)"

omz update --unattended 2>/dev/null || true

[ -d "$USER_HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting" ] && \
  git -C "$USER_HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting" pull

[ -d "$USER_HOME/.oh-my-zsh/custom/themes/powerlevel10k" ] && \
  git -C "$USER_HOME/.oh-my-zsh/custom/themes/powerlevel10k" pull
