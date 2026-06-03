#!/bin/bash
#
# update.sh — apply OS package updates and refresh shell tooling on the server.
#
# Run as the app user (it uses sudo internally). Updates apt packages, then pulls
# oh-my-zsh and its plugins/themes.
#
# USAGE:  ./apps/update.sh
#
set -euo pipefail

case "${1:-}" in -h|--help)
    awk 'NR==1&&/^#!/{next} /^#/{sub(/^#[[:space:]]?/,"");print;next}{exit}' "$0"; exit 0 ;;
esac

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
