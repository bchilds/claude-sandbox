#!/usr/bin/env bash
# Enables corepack + Yarn (version managed by packageManager field)
set -euo pipefail

# Source nvm so node/corepack are on PATH
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

corepack enable
npm install --global yarn
echo "Yarn $(yarn --version) ready"
