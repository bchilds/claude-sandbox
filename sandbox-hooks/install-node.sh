#!/usr/bin/env bash
# Installs nvm + Node.js LTS inside the sandbox
set -euo pipefail

unset NPM_CONFIG_PREFIX

if command -v nvm &>/dev/null || [ -d "$HOME/.nvm" ]; then
  echo "nvm already installed, skipping"
else
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

if [ -f .nvmrc ]; then
  nvm install
  nvm alias default "$(cat .nvmrc)"
else
  nvm install --lts
  nvm alias default lts/*
fi

# Persist for interactive sessions
grep -q 'unset NPM_CONFIG_PREFIX' ~/.bashrc 2>/dev/null || \
  echo 'unset NPM_CONFIG_PREFIX' >> ~/.bashrc
