#!/usr/bin/env bash
set -euo pipefail

echo "ccache wrappers are disabled; CoreShift builds use the repo toolchain directly."

unset CCACHE_WRAPPER_DIR
unset CCACHE_PATH
export CORESHIFT_CCACHE_WRAPPERS_ENABLED=0

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "CORESHIFT_CCACHE_WRAPPERS_ENABLED=0" >> "$GITHUB_ENV"
fi
