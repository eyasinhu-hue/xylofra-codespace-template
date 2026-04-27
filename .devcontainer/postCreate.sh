#!/usr/bin/env bash
set -e
echo "[xylofra] postCreate: installing runner deps"
cd /workspaces/$(basename "$PWD")/runner 2>/dev/null || cd "$(dirname "$0")/../runner"
npm install --no-audit --no-fund
mkdir -p /workspaces/workspace
echo "[xylofra] postCreate done"
