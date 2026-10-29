#!/bin/sh
# One-time setup for a fresh checkout: switches on the repo's git hooks in
# .githooks/ (today: the pre-commit secret scan, docs/privy-account-layer.md §2).
# Safe to run again.
#
# core.hooksPath goes into the repository's shared config, so it applies to the
# main checkout and every worktree. Git then looks for hooks only in .githooks/
# (relative to each checkout), never in .git/hooks, so this stops if a hook is
# active there. A checkout of a branch without .githooks/ runs no hook at all.
set -eu
cd "$(git rev-parse --show-toplevel)"

hooks_dir="$(git rev-parse --git-common-dir)/hooks"
active=""
if [ -d "$hooks_dir" ]; then
  for hook in "$hooks_dir"/*; do
    case "$hook" in *.sample) continue ;; esac
    if [ -f "$hook" ] && [ -x "$hook" ]; then active="$active ${hook##*/}"; fi
  done
fi
if [ -n "$active" ] && [ "$(git config --get core.hooksPath || true)" != ".githooks" ]; then
  echo "git hooks: not switched on. These hooks in $hooks_dir would stop running:$active" >&2
  echo "Move them into .githooks/ (or remove them), then run this again." >&2
  exit 1
fi

git config core.hooksPath .githooks
echo "git hooks: core.hooksPath is now .githooks for this repository, every worktree included"
echo "(a checkout of a branch without .githooks/ runs no hook)"
echo "hooks run from the checked-out branch, so review .githooks/ changes in pull requests before committing on them"
if command -v gitleaks >/dev/null 2>&1; then
  echo "secret scan: gitleaks $(gitleaks version) will run before each commit if it is 8.25 or newer, otherwise scripts/secret-scan.mjs"
else
  echo "secret scan: gitleaks is not installed, so scripts/secret-scan.mjs runs instead (gitleaks is recommended: https://github.com/gitleaks/gitleaks)"
fi
