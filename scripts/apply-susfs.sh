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
PATCH_LOG_HELPER="$SCRIPT_DIR/patch-log-helper.sh"
COMMON_DIR="$WORKSPACE_DIR/common"
FEATURES_FRAGMENT="$COMMON_DIR/features.fragment"
SUSFS_DIR="$COMMON_DIR/SUSFS"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_PATCH_DIR="${SUSFS_PATCH_DIR:-}"
SUSFS_REFS_CONFIG="$REPO_ROOT/configs/susfs-refs.json"
SUSFS_PATCHES_CONFIG="$REPO_ROOT/configs/susfs-patches.json"
VARIANT_NAME="${CORESHIFT_VARIANT:-unknown}"
if [ -n "${CORESHIFT_LOG_DIR:-}" ]; then
  SUSFS_LOG_DIR="$CORESHIFT_LOG_DIR/patches/susfs"
  mkdir -p "$SUSFS_LOG_DIR"
else
  SUSFS_LOG_DIR=""
fi

if [ ! -f "$PATCH_LOG_HELPER" ]; then
  echo "Missing patch log helper: $PATCH_LOG_HELPER" >&2
  exit 1
fi

. "$PATCH_LOG_HELPER"

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

resolve_patch_entry_list() {
  local entry_kind="$1"
  [ -f "$SUSFS_PATCHES_CONFIG" ] || return 0
  python3 - "$SUSFS_PATCHES_CONFIG" "$PROFILE_NAME" "$entry_kind" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
profile = sys.argv[2]
entry_kind = sys.argv[3]
data = json.loads(path.read_text(encoding="utf-8"))
entry = data.get("profiles", {}).get(profile)
if entry is None:
    raise SystemExit(0)
if isinstance(entry, list):
    values = entry if entry_kind == "patches" else []
elif isinstance(entry, dict):
    values = entry.get(entry_kind, [])
else:
    raise SystemExit(f"{path}: profile {profile!r} must map to a list or object")
if not isinstance(values, list):
    raise SystemExit(f"{path}: profile {profile!r} field {entry_kind!r} must be a list")
for value in values:
    if not isinstance(value, str) or not value:
        raise SystemExit(f"{path}: profile {profile!r} field {entry_kind!r} contains an invalid entry")
    print(value)
PY
}

parse_patch_urls_override() {
  printf '%s\n' "${SUSFS_PATCH_URLS:-}" |
    tr ',' '\n' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d'
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

download_sources() {
  local group_name="$1"
  shift
  local source_path
  local output_path
  local filename
  local index=0
  mkdir -p "$SUSFS_DIR/$group_name"
  for source_path in "$@"; do
    index=$((index + 1))
    filename="$(basename "$source_path")"
    [ -n "$filename" ] || filename="$group_name-$index"
    case "$filename" in
      *.patch|*.diff|*.c|*.h) ;;
      *) filename="$filename.patch" ;;
    esac
    output_path="$SUSFS_DIR/$group_name/$(printf '%02d-%s' "$index" "$filename")"
    case "$source_path" in
      http://*|https://*)
        if command -v curl >/dev/null 2>&1; then
          curl -fsSL "$source_path" -o "$output_path"
        else
          python3 - "$source_path" "$output_path" <<'PY'
from pathlib import Path
import sys
from urllib.request import urlopen

url = sys.argv[1]
target = Path(sys.argv[2])
with urlopen(url) as response:
    target.write_bytes(response.read())
PY
        fi
        ;;
      *)
        if [ ! -f "$source_path" ]; then
          echo "SUSFS source not found: $source_path" >&2
          exit 1
        fi
        cp "$source_path" "$output_path"
        ;;
    esac
    printf '%s\n' "$output_path"
  done
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

patch_log_path() {
  local kind="$1"
  local patch_file="$2"
  local base_name
  local suffix="$kind"
  base_name="$(basename "$patch_file")"
  if [ "$kind" = "checks" ]; then
    suffix="check"
  fi
  if [ -n "$SUSFS_LOG_DIR" ]; then
    printf '%s/%s/%s.%s.log\n' "$SUSFS_LOG_DIR" "$kind" "$base_name" "$suffix"
  else
    mktemp
  fi
}

print_log_excerpt() {
  local log_file="$1"
  sed -n '1,120p' "$log_file" >&2
}

cleanup_patch_log() {
  local log_file="$1"
  [ -n "$SUSFS_LOG_DIR" ] || rm -f "$log_file"
}

read_touched_files() {
  local patch_file="$1"
  local touched_file
  touched_file="$SUSFS_LOG_DIR/touched-files/$(basename "$patch_file").txt"
  if [ -n "$SUSFS_LOG_DIR" ] && [ -f "$touched_file" ]; then
    sed '/^$/d' "$touched_file"
  fi
}

format_joined_list() {
  local first=1
  local entry
  for entry in "$@"; do
    [ -n "$entry" ] || continue
    if [ "$first" -eq 1 ]; then
      printf '%s' "$entry"
      first=0
    else
      printf ', %s' "$entry"
    fi
  done
  if [ "$first" -eq 1 ]; then
    printf '%s' "(none)"
  fi
}

read_array_from_file() {
  local file_path="$1"
  if [ -f "$file_path" ]; then
    sed '/^$/d;/^(none)$/d' "$file_path"
  fi
}

write_susfs_triage() {
  local reason="$1"
  local failed_phase="$2"
  local patch_file="${3:-}"
  local guidance="$4"
  local touched_file=""
  local all_touched_file=""
  local rejects_file=""
  local patch_symbols_text="(none)"
  local tree_symbols_text="(none)"
  local found_symbols_text="(none)"
  local missing_symbols_text="unknown"
  local touched_text="(none)"
  local rejects_text="(none)"
  local -a touched_entries=()
  local -a reject_entries=()

  if [ -n "$patch_file" ] && [ -n "$SUSFS_LOG_DIR" ]; then
    touched_file="$SUSFS_LOG_DIR/touched-files/$(basename "$patch_file").txt"
  fi
  if [ -n "$SUSFS_LOG_DIR" ]; then
    all_touched_file="$SUSFS_LOG_DIR/all-touched-files.txt"
    rejects_file="$SUSFS_LOG_DIR/rejects/index.txt"
  fi

  if [ -n "$touched_file" ] && [ -f "$touched_file" ]; then
    mapfile -t touched_entries < <(read_array_from_file "$touched_file")
    touched_text="$(format_joined_list "${touched_entries[@]}")"
  elif [ -n "$all_touched_file" ] && [ -f "$all_touched_file" ]; then
    mapfile -t touched_entries < <(read_array_from_file "$all_touched_file")
    touched_text="$(format_joined_list "${touched_entries[@]}")"
  fi
  if [ -n "$rejects_file" ] && [ -f "$rejects_file" ]; then
    mapfile -t reject_entries < <(read_array_from_file "$rejects_file")
    rejects_text="$(format_joined_list "${reject_entries[@]}")"
  fi
  if [ "${#patch_config_symbols[@]}" -gt 0 ]; then
    patch_symbols_text="$(format_joined_list "${patch_config_symbols[@]}")"
  fi
  if [ "${#tree_config_symbols[@]}" -gt 0 ]; then
    tree_symbols_text="$(format_joined_list "${tree_config_symbols[@]}")"
  fi
  if [ "${#susfs_config_symbols[@]}" -gt 0 ]; then
    found_symbols_text="$(format_joined_list "${susfs_config_symbols[@]}")"
    missing_symbols_text="none"
  elif [ "$reason" = "missing-susfs-kconfig" ]; then
    missing_symbols_text="all KSU_SUSFS* symbols missing"
  else
    missing_symbols_text="not determined before failure"
  fi

  coreshift_patch_log_triage "susfs" "$reason" \
    "- failed phase: $failed_phase" \
    "- patch file: ${patch_file:-n/a}" \
    "- touched files: $touched_text" \
    "- rejects found: $rejects_text" \
    "- config symbols found: $found_symbols_text" \
    "- config symbols missing: $missing_symbols_text" \
    "- patch symbols scanned: $patch_symbols_text" \
    "- tree symbols scanned: $tree_symbols_text" \
    "- assessment: $guidance"
}

fail_with_triage() {
  local reason="$1"
  local failed_phase="$2"
  local message="$3"
  local guidance="$4"
  local patch_file="${5:-}"
  local excerpt_log="${6:-}"

  if [ -n "$SUSFS_LOG_DIR" ]; then
    coreshift_patch_log_copy_rejects "susfs" "$COMMON_DIR"
    if [ -n "$patch_file" ] && [ -f "$patch_file" ]; then
      coreshift_patch_log_source_context "susfs" "$COMMON_DIR" "$patch_file"
    else
      local planned_patch
      for planned_patch in "${selected_patch_files[@]}"; do
        [ -f "$planned_patch" ] || continue
        coreshift_patch_log_source_context "susfs" "$COMMON_DIR" "$planned_patch"
      done
    fi
    coreshift_patch_log_git_diff "susfs" "$COMMON_DIR" "diff-before-failure"
    write_susfs_triage "$reason" "$failed_phase" "$patch_file" "$guidance"
  fi

  echo "$message" >&2
  if [ -n "$excerpt_log" ] && [ -f "$excerpt_log" ]; then
    print_log_excerpt "$excerpt_log"
  fi
  exit 1
}

check_rejects_and_conflicts() {
  local reject_found=0
  local conflict_log
  conflict_log="$(mktemp)"
  trap 'rm -f "$conflict_log"' RETURN
  if find "$COMMON_DIR" -type f \( -name '*.rej' -o -name '*.orig' \) -print -quit | grep -q .; then
    reject_found=1
  fi
  if grep -RInE '^(<<<<<<<|=======|>>>>>>>)' "$COMMON_DIR" >"$conflict_log" 2>/dev/null; then
    reject_found=1
    sed -n '1,40p' "$conflict_log" >&2
  fi
  trap - RETURN
  rm -f "$conflict_log"
  if [ "$reject_found" -ne 0 ]; then
    fail_with_triage \
      "patch-context-mismatch" \
      "post-apply validation" \
      "SUSFS patch application produced reject/orig files or conflict markers." \
      "This is likely fixable by refreshing the selected profile-specific patch against the target source."
  fi
}

apply_git_patch() {
  local phase="$1"
  local work_dir="$2"
  local patch_file="$3"
  local check_log
  local apply_log

  check_log="$(patch_log_path "checks" "$patch_file")"
  apply_log="$(patch_log_path "apply" "$patch_file")"
  {
    echo "Phase: $phase"
    echo "Directory: $work_dir"
    echo "Patch: $patch_file"
  } > "$check_log"
  if ! git -C "$work_dir" apply --check "$patch_file" >>"$check_log" 2>&1; then
    fail_with_triage \
      "patch-context-mismatch" \
      "$phase check" \
      "Failed git apply --check for SUSFS patch: $patch_file" \
      "This is likely fixable by refreshing the selected profile-specific patch against the target source." \
      "$patch_file" \
      "$check_log"
  fi

  {
    echo "Phase: $phase"
    echo "Directory: $work_dir"
    echo "Patch: $patch_file"
  } > "$apply_log"
  if ! git -C "$work_dir" apply "$patch_file" >>"$apply_log" 2>&1; then
    fail_with_triage \
      "patch-context-mismatch" \
      "$phase apply" \
      "Failed git apply for SUSFS patch: $patch_file" \
      "This is likely fixable by refreshing the selected profile-specific patch against the target source." \
      "$patch_file" \
      "$apply_log"
  fi

  cleanup_patch_log "$check_log"
  cleanup_patch_log "$apply_log"
}

apply_patch_p1() {
  local phase="$1"
  local work_dir="$2"
  local patch_file="$3"
  local check_log
  local apply_log

  check_log="$(patch_log_path "checks" "$patch_file")"
  apply_log="$(patch_log_path "apply" "$patch_file")"
  {
    echo "Phase: $phase"
    echo "Directory: $work_dir"
    echo "Patch: $patch_file"
  } > "$check_log"
  if ! (cd "$work_dir" && patch -p1 --dry-run < "$patch_file") >>"$check_log" 2>&1; then
    fail_with_triage \
      "patch-context-mismatch" \
      "$phase dry-run" \
      "Failed patch -p1 --dry-run for SUSFS patch: $patch_file" \
      "This is likely fixable by refreshing the selected profile-specific patch against the target source." \
      "$patch_file" \
      "$check_log"
  fi

  {
    echo "Phase: $phase"
    echo "Directory: $work_dir"
    echo "Patch: $patch_file"
  } > "$apply_log"
  if ! (cd "$work_dir" && patch -p1 < "$patch_file") >>"$apply_log" 2>&1; then
    fail_with_triage \
      "patch-context-mismatch" \
      "$phase apply" \
      "Failed patch -p1 for SUSFS patch: $patch_file" \
      "This is likely fixable by refreshing the selected profile-specific patch against the target source." \
      "$patch_file" \
      "$apply_log"
  fi

  cleanup_patch_log "$check_log"
  cleanup_patch_log "$apply_log"
}

copy_external_support_file() {
  local source_file="$1"
  local base_name
  base_name="$(basename "$source_file")"
  case "$base_name" in
    susfs.c)
      mkdir -p "$COMMON_DIR/fs"
      cp "$source_file" "$COMMON_DIR/fs/susfs.c"
      copied_files+=("fs/susfs.c")
      ;;
    susfs*.h)
      mkdir -p "$COMMON_DIR/include/linux"
      cp "$source_file" "$COMMON_DIR/include/linux/$base_name"
      copied_files+=("include/linux/$base_name")
      ;;
    *)
      echo "Unsupported SUSFS copy file: $source_file" >&2
      exit 1
      ;;
  esac
}

copy_bundle_files() {
  local bundle_root="$1"
  local header
  mkdir -p "$COMMON_DIR/fs" "$COMMON_DIR/include/linux"
  cp "$bundle_root/fs/susfs.c" "$COMMON_DIR/fs/susfs.c"
  copied_files+=("fs/susfs.c")
  while IFS= read -r -d '' header; do
    cp "$header" "$COMMON_DIR/include/linux/$(basename "$header")"
    copied_files+=("include/linux/$(basename "$header")")
  done < <(find "$bundle_root/include/linux" -maxdepth 1 -type f -name '*.h' -print0 | sort -z)
}

select_core_patch() {
  local bundle_root="$1"
  local exact_patch="$bundle_root/50_add_susfs_in_gki-$ANDROID_RELEASE-$KERNEL_VERSION.patch"
  if [ -f "$exact_patch" ]; then
    printf '%s\n' "$exact_patch"
    return 0
  fi

  local candidate
  local candidates=()
  while IFS= read -r candidate; do
    candidates+=("$candidate")
  done < <(find "$bundle_root" -maxdepth 1 -type f -name '50_add_susfs_in_*.patch' | sort)

  if [ "${#candidates[@]}" -eq 1 ]; then
    printf '%s\n' "${candidates[0]}"
    return 0
  fi

  return 1
}

locate_ksu_root() {
  local marker
  marker="$(find "$COMMON_DIR" -type f -path '*/kernel/include/ksu.h' -print | sort | head -n 1 || true)"
  if [ -z "$marker" ]; then
    if [ -n "$SUSFS_LOG_DIR" ]; then
      {
        echo "Unable to locate integrated KSU root under $COMMON_DIR."
        echo "Nearby KSU directories:"
        find "$COMMON_DIR" -type d \( -iname '*kernelsu*' -o -iname '*ksu*' \) | sort || true
      } > "$SUSFS_LOG_DIR/ksu-root-error.txt"
    fi
    return 1
  fi
  printf '%s\n' "${marker%/kernel/include/ksu.h}"
}

write_log_file() {
  local path="$1"
  shift
  [ -n "$SUSFS_LOG_DIR" ] || return 0
  printf '%s\n' "$@" > "$SUSFS_LOG_DIR/$path"
}

fail_missing_symbols() {
  [ -n "$SUSFS_LOG_DIR" ] && cat > "$SUSFS_LOG_DIR/susfs-config-error.txt" <<'EOF'
SUSFS integration did not declare any KSU_SUSFS* Kconfig symbols.
The selected SUSFS ref/patch set is incomplete or the KSU-side integration patch did not apply.
Check susfs-config-symbols.txt, ksu-root.txt, selected patches, and patch logs.
EOF
  fail_with_triage \
    "missing-susfs-kconfig" \
    "config scan" \
    "SUSFS integration did not declare any KSU_SUSFS* Kconfig symbols." \
    "This needs a patch-bundle or KSU integration fix; the selected patch set is incomplete or the KSU-side patch did not apply."
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
coreshift_patch_log_init "susfs" "$PROFILE_NAME" "$VARIANT_NAME"

mapfile -t configured_patch_sources < <(resolve_patch_entry_list patches || true)
mapfile -t configured_ksu_patch_sources < <(resolve_patch_entry_list ksu_patches || true)
mapfile -t configured_copy_sources < <(resolve_patch_entry_list copy || true)
mapfile -t override_patch_sources < <(parse_patch_urls_override || true)

external_patch_sources=("${configured_patch_sources[@]}")
if [ "${#override_patch_sources[@]}" -gt 0 ]; then
  external_patch_sources=("${override_patch_sources[@]}")
fi

copied_files=()
selected_patch_files=()
ksu_patch_files=()
core_patch_files=()
patch_config_symbols=()
tree_config_symbols=()
susfs_config_symbols=()
mode_label=""
patch_root=""
core_patch_file=""
ksu_patch_file=""
RESOLVED_SUSFS_REF=""
susfs_commit=""

if [ -n "$SUSFS_PATCH_DIR" ]; then
  patch_root="$SUSFS_PATCH_DIR"
  mode_label="local-bundle"
  RESOLVED_SUSFS_REF="local-bundle"
  susfs_commit="local-bundle"
elif [ "${#external_patch_sources[@]}" -gt 0 ] || [ "${#configured_ksu_patch_sources[@]}" -gt 0 ] || [ "${#configured_copy_sources[@]}" -gt 0 ]; then
  mode_label="external"
  RESOLVED_SUSFS_REF="external-patches"
  susfs_commit="external-patches"
  rm -rf "$SUSFS_DIR"
  mkdir -p "$SUSFS_DIR"
else
  mode_label="simonpunk"
  RESOLVED_SUSFS_REF="$(resolve_susfs_ref)"
  clone_susfs_source "$RESOLVED_SUSFS_REF"
  rm -rf "$SUSFS_DIR/.github"
  patch_root="$SUSFS_DIR/kernel_patches"
  susfs_commit="$(git -C "$SUSFS_DIR" rev-parse HEAD)"
fi

if [ "$mode_label" = "local-bundle" ] || [ "$mode_label" = "simonpunk" ]; then
  if [ ! -f "$patch_root/fs/susfs.c" ]; then
    fail_with_triage \
      "missing-source-file" \
      "bundle validation" \
      "Missing SUSFS source file: $patch_root/fs/susfs.c" \
      "This needs a patch-bundle or copy-source fix; the selected SUSFS bundle does not contain fs/susfs.c."
  fi
  if ! find "$patch_root/include/linux" -maxdepth 1 -type f -name '*.h' -print -quit | grep -q .; then
    fail_with_triage \
      "missing-source-file" \
      "bundle validation" \
      "Missing SUSFS headers under: $patch_root/include/linux" \
      "This needs a patch-bundle or copy-source fix; the selected SUSFS bundle does not contain the required headers."
  fi
  if [ ! -f "$patch_root/KernelSU/10_enable_susfs_for_ksu.patch" ]; then
    fail_with_triage \
      "unsupported-patch-bundle" \
      "bundle validation" \
      "Missing KernelSU SUSFS patch: $patch_root/KernelSU/10_enable_susfs_for_ksu.patch" \
      "This needs a patch-bundle fix; the selected SUSFS bundle does not provide the required KernelSU integration patch."
  fi
  core_patch_file="$(select_core_patch "$patch_root" || true)"
  if [ -z "$core_patch_file" ]; then
    fail_with_triage \
      "unsupported-patch-bundle" \
      "bundle validation" \
      "No Simonpunk core SUSFS patch found for $PROFILE_NAME under $patch_root." \
      "This needs a patch-bundle fix; select a compatible SUSFS ref or bundle for the target profile source."
  fi
  ksu_patch_file="$patch_root/KernelSU/10_enable_susfs_for_ksu.patch"
  copy_bundle_files "$patch_root"
  core_patch_files=("$core_patch_file")
  ksu_patch_files=("$ksu_patch_file")
else
  if [ "${#configured_copy_sources[@]}" -gt 0 ]; then
    mapfile -t external_copy_files < <(download_sources "external-copy" "${configured_copy_sources[@]}")
    for external_copy_file in "${external_copy_files[@]}"; do
      copy_external_support_file "$external_copy_file"
    done
  fi
  if [ "${#external_patch_sources[@]}" -gt 0 ]; then
    mapfile -t core_patch_files < <(download_sources "external-patches" "${external_patch_sources[@]}")
  fi
  if [ "${#configured_ksu_patch_sources[@]}" -gt 0 ]; then
    mapfile -t ksu_patch_files < <(download_sources "external-ksu-patches" "${configured_ksu_patch_sources[@]}")
  fi
  if [ "${#core_patch_files[@]}" -eq 0 ]; then
    fail_with_triage \
      "unsupported-patch-bundle" \
      "bundle validation" \
      "No local SUSFS patch bundle configured for $PROFILE_NAME. Set SUSFS_PATCH_DIR or configs/susfs-patches.json." \
      "This needs a patch-bundle fix; configure a compatible SUSFS patch set before running the SUSFS phase."
  fi
fi

selected_patch_files=("${core_patch_files[@]}" "${ksu_patch_files[@]}")

coreshift_patch_log_patch_plan "susfs" "${selected_patch_files[@]}"

mapfile -t patch_config_symbols < <(scan_patch_config_symbols "${selected_patch_files[@]}")

for patch_file in "${core_patch_files[@]}"; do
  if [ "$mode_label" = "external" ]; then
    apply_patch_p1 "core SUSFS" "$COMMON_DIR" "$patch_file"
  else
    apply_git_patch "core SUSFS" "$COMMON_DIR" "$patch_file"
  fi
done

if ! KSU_ROOT="$(locate_ksu_root)"; then
  fail_with_triage \
    "missing-kernel-su-root" \
    "KernelSU root discovery" \
    "Unable to locate integrated KSU root under $COMMON_DIR." \
    "This needs a KernelSU or MultiSU provider integration fix before SUSFS can be applied."
fi
write_log_file "ksu-root.txt" "$KSU_ROOT"

for patch_file in "${ksu_patch_files[@]}"; do
  if [ "$mode_label" = "external" ]; then
    apply_patch_p1 "KernelSU SUSFS" "$KSU_ROOT" "$patch_file"
  else
    apply_git_patch "KernelSU SUSFS" "$KSU_ROOT" "$patch_file"
  fi
done

check_rejects_and_conflicts

if [ ! -f "$COMMON_DIR/fs/susfs.c" ]; then
  fail_with_triage \
    "missing-source-file" \
    "post-apply validation" \
    "SUSFS source file missing after integration: $COMMON_DIR/fs/susfs.c" \
    "This needs a patch-bundle or copy-source fix; fs/susfs.c was not staged into the target source tree."
fi
if ! find "$COMMON_DIR/include/linux" -maxdepth 1 -type f -name 'susfs*.h' -print -quit | grep -q .; then
  fail_with_triage \
    "missing-source-file" \
    "post-apply validation" \
    "SUSFS headers missing after integration under $COMMON_DIR/include/linux" \
    "This needs a patch-bundle or copy-source fix; required SUSFS headers were not staged into the target source tree."
fi

mapfile -t tree_config_symbols < <(scan_tree_config_symbols)
mapfile -t susfs_config_symbols < <(
  {
    printf '%s\n' "${patch_config_symbols[@]}"
    printf '%s\n' "${tree_config_symbols[@]}"
  } | sed '/^$/d' | sort -u
)

if [ -n "$SUSFS_LOG_DIR" ]; then
  {
    echo "SUSFS mode: $mode_label"
    echo "SUSFS repo: $SUSFS_REPO"
    echo "SUSFS ref: $RESOLVED_SUSFS_REF"
    echo "SUSFS commit: $susfs_commit"
    echo "SUSFS source path: $SUSFS_DIR"
    if [ -n "$SUSFS_PATCH_DIR" ]; then
      echo "SUSFS patch dir override: $SUSFS_PATCH_DIR"
    fi
    if [ "${#external_patch_sources[@]}" -gt 0 ]; then
      echo "SUSFS external patches:"
      printf '  %s\n' "${external_patch_sources[@]}"
    fi
    if [ "${#configured_ksu_patch_sources[@]}" -gt 0 ]; then
      echo "SUSFS external KSU patches:"
      printf '  %s\n' "${configured_ksu_patch_sources[@]}"
    fi
  } > "$SUSFS_LOG_DIR/susfs-source.txt"

  if [ "${#copied_files[@]}" -gt 0 ]; then
    write_log_file "susfs-files.txt" "${copied_files[@]}"
  else
    write_log_file "susfs-files.txt" "(no copied files)"
  fi

  {
    echo "Core SUSFS patches:"
    printf '%s\n' "${core_patch_files[@]}"
    echo
    echo "KernelSU SUSFS patches:"
    if [ "${#ksu_patch_files[@]}" -gt 0 ]; then
      printf '%s\n' "${ksu_patch_files[@]}"
    else
      echo "(none)"
    fi
  } > "$SUSFS_LOG_DIR/susfs-patches.txt"

  if [ "${#susfs_config_symbols[@]}" -gt 0 ]; then
    for config_symbol in "${susfs_config_symbols[@]}"; do
      echo "CONFIG_${config_symbol}=y"
    done > "$SUSFS_LOG_DIR/susfs-config-symbols.txt"
  else
    : > "$SUSFS_LOG_DIR/susfs-config-symbols.txt"
  fi
fi

if [ "${#susfs_config_symbols[@]}" -eq 0 ]; then
  fail_missing_symbols
fi

ensure_line_once 'CONFIG_KSU=y' "$FEATURES_FRAGMENT"
for config_symbol in "${susfs_config_symbols[@]}"; do
  ensure_line_once "CONFIG_${config_symbol}=y" "$FEATURES_FRAGMENT"
done

echo "SUSFS repo: $SUSFS_REPO"
echo "SUSFS ref: $RESOLVED_SUSFS_REF"
echo "SUSFS commit: $susfs_commit"
echo "SUSFS source path: $SUSFS_DIR"
echo "SUSFS files copied:"
printf '  %s\n' "${copied_files[@]}"
echo "SUSFS core patches applied:"
printf '  %s\n' "${core_patch_files[@]}"
echo "KernelSU SUSFS patches applied:"
if [ "${#ksu_patch_files[@]}" -gt 0 ]; then
  printf '  %s\n' "${ksu_patch_files[@]}"
else
  echo "  (none)"
fi
echo "KernelSU root: $KSU_ROOT"
echo "SUSFS config symbols enabled:"
for config_symbol in "${susfs_config_symbols[@]}"; do
  echo "  CONFIG_${config_symbol}=y"
done
