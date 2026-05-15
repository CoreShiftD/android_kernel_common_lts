#!/usr/bin/env bash
set -euo pipefail

LOCAL_BIN="$HOME/.local/bin"
LOCAL_REPO="$LOCAL_BIN/repo"

if command -v repo >/dev/null 2>&1; then
  echo "repo already available: $(command -v repo)"
  exit 0
fi

mkdir -p "$LOCAL_BIN"

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y repo || true
fi

if ! command -v repo >/dev/null 2>&1 && [ ! -x "$LOCAL_REPO" ]; then
  curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$LOCAL_REPO"
  chmod +x "$LOCAL_REPO"
fi

export PATH="$LOCAL_BIN:$PATH"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$LOCAL_BIN" >> "$GITHUB_PATH"
fi

if ! command -v repo >/dev/null 2>&1; then
  echo "Failed to install repo tool" >&2
  exit 1
fi

echo "repo installed at: $(command -v repo)"
repo --version || true
