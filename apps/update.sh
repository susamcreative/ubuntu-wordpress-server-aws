#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: Run this script as the app user, not root. It uses sudo internally where needed." >&2
  exit 1
fi

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
