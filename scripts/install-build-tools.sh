#!/usr/bin/env bash
set -euo pipefail

LOCAL_BIN="$HOME/.local/bin"
LOCAL_REPO="$LOCAL_BIN/repo"

APT_PACKAGES=(
  git
  curl
  ca-certificates
  python3
  make
  bc
  bison
  flex
  rsync
  unzip
  zip
  tar
  zstd
  xz-utils
  file
  openssl
  libssl-dev
  libelf-dev
  dwarves
  gcc-aarch64-linux-gnu
  libc6-dev-arm64-cross
  linux-libc-dev-arm64-cross
)

if ! command -v apt-get >/dev/null 2>&1; then
  echo "apt-get is required to install host build tooling on this system" >&2
  exit 1
fi

mkdir -p "$LOCAL_BIN"

sudo apt-get update
sudo apt-get install -y --no-install-recommends "${APT_PACKAGES[@]}"

if command -v repo >/dev/null 2>&1; then
  echo "repo already available: $(command -v repo)"
else
  sudo apt-get install -y --no-install-recommends repo || true

  if ! command -v repo >/dev/null 2>&1; then
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$LOCAL_REPO"
    chmod +x "$LOCAL_REPO"
  fi
fi

export PATH="$LOCAL_BIN:$PATH"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$LOCAL_BIN" >> "$GITHUB_PATH"
fi

required_tools=(
  git
  curl
  python3
  repo
  make
  bc
  bison
  flex
  rsync
  zstd
)

for tool in "${required_tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required tool missing after installation: $tool" >&2
    exit 1
  fi
done

if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
  echo "Warning: aarch64-linux-gnu-gcc not found after installation" >&2
fi

if [ ! -f /usr/aarch64-linux-gnu/include/sys/time.h ]; then
  echo "Warning: /usr/aarch64-linux-gnu/include/sys/time.h not found after installation" >&2
fi

echo "Installed host tool versions:"
git --version
python3 --version
make --version | head -n 1
repo --version || true
aarch64-linux-gnu-gcc --version | head -n 1 || true
pahole --version || true
zstd --version || true

