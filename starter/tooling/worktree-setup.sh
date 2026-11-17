#!/usr/bin/env bash
# Prepares a new git worktree of this repo: copies the gitignored local config a dev build needs
# from the main checkout, then installs dependencies. Your agent harness runs it when it creates a
# worktree (point its "on worktree create" hook here), and the agent starts after it ends.
#
# Usage: tooling/worktree-setup.sh   (from anywhere inside the new worktree)
#
# Why: a fresh worktree has the tracked files only. Env files, local credentials, and generated
# assets are gitignored, so without this the agent's first build fails or, worse, the agent invents
# its own values.
#
# What it never copies: release material (signing keys, keystores, store API keys, deploy secrets,
# SSH keys, service-account JSON). A worktree holds short-lived agent work, and that material can
# sign a build or deploy to a real environment. Release builds stay in the main checkout. When a
# directory mixes dev config with a release key, list the dev file alone, never the directory.
#
# The copied env files still name the main checkout's ports and database. That's deliberate: app
# code refuses to run in a worktree until `node tooling/task-env.mjs up <name>` gives it its own
# (see assertTaskEnvironment in task-env.mjs).
#
# A file the worktree already has stays as it is, so a rerun keeps local edits.
set -euo pipefail

# FILL: gitignored files the app can't start without, relative to the repo root. The script fails
# when the main checkout lacks one.
required=(
  .env
)

# FILL: gitignored files that only some features need (a push config, a social-login token, a
# generated wasm). The script warns and continues when the main checkout lacks one. Say why each
# is here in a comment beside it.
optional=(
)

# FILL: the dependency install (and any codegen a first build needs). The default installs Node
# dependencies for whichever lockfile is present, and nothing otherwise.
install() {
  if [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile
  elif [ -f package-lock.json ]; then npm ci --no-audit --no-fund
  elif [ -f yarn.lock ]; then yarn install --frozen-lockfile
  fi
}

root="$(git rev-parse --show-toplevel)"
main="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"

if [ "$(cd "$root" && pwd -P)" = "$(cd "$main" && pwd -P)" ]; then
  echo "worktree-setup: this is the main checkout, not a worktree; nothing to do." >&2
  exit 1
fi

copy() {
  local file="$1" required="$2"
  if [ -e "$root/$file" ]; then
    echo "Keeping the existing $file"
  elif [ -e "$main/$file" ]; then
    mkdir -p "$(dirname "$root/$file")"
    # -L: a symlink in main becomes a real file here, so editing it can't change main's copy.
    cp -pL "$main/$file" "$root/$file"
    echo "Copied $file from $main"
  elif [ "$required" = yes ]; then
    echo "worktree-setup: $main/$file does not exist. Create it in the main checkout first (see the setup docs), then run this again." >&2
    exit 1
  else
    echo "worktree-setup: warning: $main/$file does not exist; skipping it." >&2
  fi
}

for file in ${required[@]+"${required[@]}"}; do copy "$file" yes; done
for file in ${optional[@]+"${optional[@]}"}; do copy "$file" no; done

cd "$root"
install
