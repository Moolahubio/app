#!/usr/bin/env bash
# Restores GitHub SSH key and git config from the GITHUB_DEPLOY_KEY secret.
# Run manually after a pod restart, or add as a predev hook.
set -euo pipefail

if [[ -z "${GITHUB_DEPLOY_KEY:-}" ]]; then
  echo "GITHUB_DEPLOY_KEY secret is not set. Skipping SSH setup." >&2
  exit 0
fi

mkdir -p ~/.ssh
chmod 700 ~/.ssh

printf '%s\n' "${GITHUB_DEPLOY_KEY}" > ~/.ssh/github_deploy
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

echo "SSH key and git config restored. Testing connection..."
ssh -T git@github.com 2>&1 || true
