#!/usr/bin/env bash
set -euo pipefail

echo "ccache setup is disabled; CoreShift builds default to clean, deterministic compiler state."

export USE_CCACHE="${USE_CCACHE:-0}"
if [ "$USE_CCACHE" != "0" ]; then
  echo "USE_CCACHE=$USE_CCACHE requested, but ccache is disabled for deterministic builds." >&2
  exit 1
fi

unset CCACHE_DIR
unset CCACHE_EXEC
unset CCACHE_WRAPPER_DIR
unset CCACHE_PATH
unset CORESHIFT_CCACHE_DEBUG
export CORESHIFT_CCACHE_WRAPPERS_ENABLED=0

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "USE_CCACHE=0"
    echo "CORESHIFT_CCACHE_WRAPPERS_ENABLED=0"
  } >> "$GITHUB_ENV"
fi
