#!/usr/bin/env bash
# Installs nvm + Node.js LTS inside the sandbox
set -euo pipefail

if command -v nvm &>/dev/null || [ -d "$HOME/.nvm" ]; then
  echo "nvm already installed, skipping"
else
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

nvm install --lts
nvm alias default lts/*
