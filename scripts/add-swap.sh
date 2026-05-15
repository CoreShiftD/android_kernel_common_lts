#!/usr/bin/env bash
set -euo pipefail

SIZE_GB="${1:-16}"

if ! [[ "$SIZE_GB" =~ ^[0-9]+$ ]] || [ "$SIZE_GB" -le 0 ]; then
  echo "Swap size must be a positive integer number of GiB: $SIZE_GB" >&2
  exit 1
fi

if swapon --show --noheadings | grep -q .; then
  echo "Swap already active:"
  free -h
  swapon --show
  exit 0
fi

RUNNER_TEMP_DIR="${RUNNER_TEMP:-/tmp}"

if sudo test -w /; then
  SWAPFILE="/swapfile"
else
  SWAPFILE="$RUNNER_TEMP_DIR/coreshift-swapfile"
fi

echo "Creating ${SIZE_GB}G swap at $SWAPFILE"

if ! sudo fallocate -l "${SIZE_GB}G" "$SWAPFILE"; then
  echo "fallocate failed, falling back to dd"
  sudo dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SIZE_GB * 1024)) status=progress
fi

sudo chmod 600 "$SWAPFILE"
sudo mkswap "$SWAPFILE"
sudo swapon "$SWAPFILE"

if ! swapon --show --noheadings | grep -q .; then
  echo "Failed to enable swap at $SWAPFILE" >&2
  exit 1
fi

free -h
swapon --show
