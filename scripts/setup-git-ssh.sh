#!/usr/bin/env bash
# Restores GitHub SSH key and git config from the GITHUB_DEPLOY_KEY secret.
# The secret must be base64-encoded (single line) to survive Replit secret storage.
# Run manually after a pod restart: bash scripts/setup-git-ssh.sh
set -euo pipefail

if [[ -z "${GITHUB_DEPLOY_KEY:-}" ]]; then
  echo "GITHUB_DEPLOY_KEY secret is not set. Skipping SSH setup." >&2
  exit 0
fi

mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Decode from base64 (handles the single-line format Replit secrets require)
printf '%s' "${GITHUB_DEPLOY_KEY}" | base64 -d > ~/.ssh/github_deploy
chmod 600 ~/.ssh/github_deploy

cat > ~/.ssh/config << 'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/github_deploy
  StrictHostKeyChecking no
EOF
chmod 600 ~/.ssh/config

git config --global url."git@github.com:".insteadOf "https://github.com/"

echo "SSH key restored. Testing connection..."
ssh -T git@github.com 2>&1 || true
