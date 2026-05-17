#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/apply-susfs.sh <workspace-dir> <profile-name>
EOF
}

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 1
fi

WORKSPACE_DIR="$1"
PROFILE_NAME="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_DIR="$WORKSPACE_DIR/common"
FEATURES_FRAGMENT="$COMMON_DIR/features.fragment"
SUSFS_DIR="$COMMON_DIR/SUSFS"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_REFS_CONFIG="$REPO_ROOT/configs/susfs-refs.json"
if [ -n "${CORESHIFT_LOG_DIR:-}" ]; then
  SUSFS_LOG_DIR="$CORESHIFT_LOG_DIR/patches/susfs"
  mkdir -p "$SUSFS_LOG_DIR"
else
  SUSFS_LOG_DIR=""
fi

derive_profile_parts() {
  python3 - "$PROFILE_NAME" <<'PY'
import re
import sys

profile = sys.argv[1]
match = re.fullmatch(r"(android\d+)-(\d+\.\d+)-lts", profile)
if not match:
    raise SystemExit(f"Could not derive Android release/kernel version from profile: {profile}")
print(match.group(1))
print(match.group(2))
PY
}

resolve_configured_ref() {
  [ -f "$SUSFS_REFS_CONFIG" ] || return 1
  python3 - "$SUSFS_REFS_CONFIG" "$PROFILE_NAME" "$ANDROID_RELEASE" "$KERNEL_VERSION" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
profile = sys.argv[2]
android_release = sys.argv[3]
kernel_version = sys.argv[4]
android_kernel = f"{android_release}-{kernel_version}"

data = json.loads(path.read_text(encoding="utf-8"))

def lookup(container, key):
    if isinstance(container, dict):
        value = container.get(key)
        if isinstance(value, str) and value:
            return value
    return None

for container, key in (
    (data.get("profiles"), profile),
    (data.get("android_kernels"), android_kernel),
    (data.get("kernels"), kernel_version),
    (data, profile),
    (data, android_kernel),
    (data, kernel_version),
):
    value = lookup(container, key)
    if value:
        print(value)
        break
PY
}

remote_head_exists() {
  local candidate="$1"
  git ls-remote --heads "$SUSFS_REPO" "$candidate" | grep -q .
}

resolve_susfs_ref() {
  if [ -n "${SUSFS_REF:-}" ]; then
    printf '%s\n' "$SUSFS_REF"
    return 0
  fi

  local configured_ref
  configured_ref="$(resolve_configured_ref || true)"
  if [ -n "$configured_ref" ]; then
    printf '%s\n' "$configured_ref"
    return 0
  fi

  local candidate
  local candidates=(
    "gki-$ANDROID_RELEASE-$KERNEL_VERSION"
    "gki-$ANDROID_RELEASE-$KERNEL_VERSION-dev"
    "$ANDROID_RELEASE-$KERNEL_VERSION"
    "$ANDROID_RELEASE-$KERNEL_VERSION-dev"
    "kernel-$KERNEL_VERSION"
    "kernel-$KERNEL_VERSION-dev"
    "$KERNEL_VERSION"
    "$KERNEL_VERSION-dev"
    "main"
    "master"
  )

  for candidate in "${candidates[@]}"; do
    if remote_head_exists "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "Could not resolve SUSFS ref for $PROFILE_NAME. Set SUSFS_REF or add configs/susfs-refs.json entry." >&2
  return 1
}

clone_susfs_source() {
  local ref="$1"
  rm -rf "$SUSFS_DIR"
  if git clone --depth 1 --branch "$ref" "$SUSFS_REPO" "$SUSFS_DIR"; then
    return 0
  fi

  rm -rf "$SUSFS_DIR"
  git clone --depth 1 "$SUSFS_REPO" "$SUSFS_DIR"
  git -C "$SUSFS_DIR" fetch --depth 1 origin "$ref"
  git -C "$SUSFS_DIR" checkout --detach FETCH_HEAD
}

collect_patch_files() {
  local patch_root
  local candidate_dirs=(
    "$SUSFS_DIR/kernel_patches/$PROFILE_NAME"
    "$SUSFS_DIR/kernel_patches/$ANDROID_RELEASE-$KERNEL_VERSION"
    "$SUSFS_DIR/kernel_patches/$KERNEL_VERSION"
    "$SUSFS_DIR/patches/$PROFILE_NAME"
    "$SUSFS_DIR/patches/$ANDROID_RELEASE-$KERNEL_VERSION"
    "$SUSFS_DIR/patches/$KERNEL_VERSION"
  )

  for patch_root in "${candidate_dirs[@]}"; do
    if [ -d "$patch_root" ] && find "$patch_root" -type f -name '*.patch' -print -quit | grep -q .; then
      find "$patch_root" -type f -name '*.patch' | sort
      return 0
    fi
  done

  for patch_root in "$SUSFS_DIR/kernel_patches" "$SUSFS_DIR/patches"; do
    [ -d "$patch_root" ] || continue
    if find "$patch_root" -maxdepth 1 -type f -name '*.patch' -print -quit | grep -q .; then
      find "$patch_root" -maxdepth 1 -type f -name '*.patch' | sort
      return 0
    fi
  done

  return 1
}

scan_patch_config_symbols() {
  if [ "$#" -eq 0 ]; then
    return 0
  fi

  grep -hE '^\+[[:space:]]*config[[:space:]]+KSU_SUSFS[A-Z0-9_]*' "$@" |
    sed -E 's/^\+[[:space:]]*config[[:space:]]+//' |
    sort -u || true
}

scan_tree_config_symbols() {
  find "$COMMON_DIR" -type f \( -name 'Kconfig' -o -name 'Kconfig.*' \) -print0 |
    xargs -0 -r grep -hE '^[[:space:]]*config[[:space:]]+KSU_SUSFS[A-Z0-9_]*' |
    sed -E 's/^[[:space:]]*config[[:space:]]+//' |
    sort -u || true
}

ensure_line_once() {
  local wanted_line="$1"
  local target_file="$2"
  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"' RETURN
  grep -Fvx "$wanted_line" "$target_file" > "$tmp_file" || true
  printf '%s\n' "$wanted_line" >> "$tmp_file"
  mv "$tmp_file" "$target_file"
  trap - RETURN
}

apply_patch_file() {
  local patch_file="$1"
  local patch_log
  if [ -n "$SUSFS_LOG_DIR" ]; then
    patch_log="$SUSFS_LOG_DIR/$(basename "$patch_file").log"
    : > "$patch_log"
  else
    patch_log="$(mktemp)"
  fi
  if (cd "$COMMON_DIR" && patch -p1 < "$patch_file") >"$patch_log" 2>&1; then
    if [ -z "$SUSFS_LOG_DIR" ]; then
      rm -f "$patch_log"
    fi
    return 0
  fi

  echo "Failed to apply SUSFS patch: $patch_file" >&2
  sed -n '1,80p' "$patch_log" >&2
  if [ -z "$SUSFS_LOG_DIR" ]; then
    rm -f "$patch_log"
  fi
  return 1
}

if [ ! -d "$COMMON_DIR" ]; then
  echo "Workspace common directory not found: $COMMON_DIR" >&2
  exit 1
fi

if ! git -C "$COMMON_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Workspace common directory is not a git repo: $COMMON_DIR" >&2
  exit 1
fi

if [ ! -f "$FEATURES_FRAGMENT" ]; then
  echo "Workspace features fragment not found: $FEATURES_FRAGMENT" >&2
  exit 1
fi

if ! grep -Fxq 'CONFIG_KSU=y' "$FEATURES_FRAGMENT"; then
  echo "SUSFS requires KernelSU. Use ksu-susfs or ksu-susfs-bbg." >&2
  exit 1
fi

mapfile -t profile_parts < <(derive_profile_parts)
ANDROID_RELEASE="${profile_parts[0]}"
KERNEL_VERSION="${profile_parts[1]}"
RESOLVED_SUSFS_REF="$(resolve_susfs_ref)"

clone_susfs_source "$RESOLVED_SUSFS_REF"
rm -rf "$SUSFS_DIR/.github"

mapfile -t susfs_patch_files < <(collect_patch_files || true)
if [ "${#susfs_patch_files[@]}" -eq 0 ]; then
  echo "No SUSFS patch files found for $PROFILE_NAME in selected ref $RESOLVED_SUSFS_REF" >&2
  exit 1
fi

mapfile -t patch_config_symbols < <(scan_patch_config_symbols "${susfs_patch_files[@]}")

for patch_file in "${susfs_patch_files[@]}"; do
  apply_patch_file "$patch_file"
done

mapfile -t reject_files < <(find "$COMMON_DIR" -name '*.rej' -print)
if [ "${#reject_files[@]}" -gt 0 ]; then
  echo "SUSFS patch rejects created:" >&2
  printf '%s\n' "${reject_files[@]}" >&2
  exit 1
fi

mapfile -t tree_config_symbols < <(scan_tree_config_symbols)
mapfile -t susfs_config_symbols < <(
  {
    printf '%s\n' "${patch_config_symbols[@]}"
    printf '%s\n' "${tree_config_symbols[@]}"
  } | sed '/^$/d' | sort -u
)

if [ "${#susfs_config_symbols[@]}" -eq 0 ]; then
  echo "SUSFS config scan found no KSU_SUSFS* symbols; falling back to CONFIG_KSU_SUSFS=y" >&2
  susfs_config_symbols=("KSU_SUSFS")
fi

ensure_line_once 'CONFIG_KSU=y' "$FEATURES_FRAGMENT"
for config_symbol in "${susfs_config_symbols[@]}"; do
  ensure_line_once "CONFIG_${config_symbol}=y" "$FEATURES_FRAGMENT"
done

susfs_commit="$(git -C "$SUSFS_DIR" rev-parse HEAD)"
if [ -n "$SUSFS_LOG_DIR" ]; then
  {
    echo "SUSFS repo: $SUSFS_REPO"
    echo "SUSFS ref: $RESOLVED_SUSFS_REF"
    echo "SUSFS commit: $susfs_commit"
    echo "SUSFS source path: $SUSFS_DIR"
  } > "$SUSFS_LOG_DIR/susfs-source.txt"
  for config_symbol in "${susfs_config_symbols[@]}"; do
    echo "CONFIG_${config_symbol}=y"
  done > "$SUSFS_LOG_DIR/susfs-config-symbols.txt"
fi
echo "SUSFS repo: $SUSFS_REPO"
echo "SUSFS ref: $RESOLVED_SUSFS_REF"
echo "SUSFS commit: $susfs_commit"
echo "SUSFS source path: $SUSFS_DIR"
echo "SUSFS config symbols enabled:"
for config_symbol in "${susfs_config_symbols[@]}"; do
  echo "  CONFIG_${config_symbol}=y"
done
