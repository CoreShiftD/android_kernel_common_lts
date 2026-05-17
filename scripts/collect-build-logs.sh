#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/collect-build-logs.sh <profile> <variant> <workspace-dir> <dist-dir>
EOF
}

if [ "$#" -ne 4 ]; then
  usage >&2
  exit 1
fi

PROFILE="$1"
VARIANT="$2"
WORKSPACE_DIR="$3"
DIST_DIR="$4"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_SOURCE_DIR="$REPO_ROOT/.logs/$PROFILE/$VARIANT"
LOG_DIST_DIR="$DIST_DIR/logs"
ZIP_PATH="$LOG_DIST_DIR/CoreShift-logs-$PROFILE-$VARIANT.zip"
STAGING_DIR="$(mktemp -d)"
SUMMARY_PATH="$STAGING_DIR/SUMMARY.md"
BUILD_EXIT_CODE="unknown"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

mkdir -p "$LOG_DIST_DIR" "$STAGING_DIR"
LOG_DIST_DIR="$(cd "$LOG_DIST_DIR" && pwd)"
ZIP_PATH="$LOG_DIST_DIR/CoreShift-logs-$PROFILE-$VARIANT.zip"

copy_if_exists() {
  local source_path="$1"
  local relative_path="$2"
  if [ -f "$source_path" ]; then
    mkdir -p "$STAGING_DIR/$(dirname "$relative_path")"
    cp "$source_path" "$STAGING_DIR/$relative_path"
  fi
}

copy_tree_contents_if_exists() {
  local source_path="$1"
  if [ -d "$source_path" ]; then
    cp -a "$source_path"/. "$STAGING_DIR/"
  fi
}

copy_common_artifact() {
  local source_path="$1"
  local relative_path
  relative_path="${source_path#"$WORKSPACE_DIR/"}"
  copy_if_exists "$source_path" "$relative_path"
}

copy_reject_like_files() {
  local common_root="$1"
  local found_file
  local relative_path

  [ -d "$common_root" ] || return 0
  while IFS= read -r -d '' found_file; do
    relative_path="${found_file#"$WORKSPACE_DIR/"}"
    copy_if_exists "$found_file" "$relative_path"
  done < <(find "$common_root" -type f \( -name '*.rej' -o -name '*.orig' \) -print0)
}

write_summary() {
  {
    echo "# CoreShift log bundle summary"
    echo
    echo "- profile: $PROFILE"
    echo "- variant: $VARIANT"
    echo "- build exit code: $BUILD_EXIT_CODE"
    echo
    echo "Important triage files:"
    for important_path in \
      "patches/susfs/triage.md" \
      "patches/susfs/rejects/index.txt" \
      "patches/susfs/susfs-config-error.txt" \
      "patches/susfs/ksu-root-error.txt"; do
      if [ -f "$STAGING_DIR/$important_path" ]; then
        echo "- $important_path"
      else
        echo "- $important_path (not present)"
      fi
    done
  } > "$SUMMARY_PATH"
}

{
  echo "profile=$PROFILE"
  echo "variant=$VARIANT"
  echo "workspace_dir=$WORKSPACE_DIR"
  echo "dist_dir=$DIST_DIR"
  echo "log_source_dir=$LOG_SOURCE_DIR"
  date -u '+collected_at_utc=%Y-%m-%dT%H:%M:%SZ'
  if [ -d "$WORKSPACE_DIR" ]; then
    echo
    echo "workspace diagnostics:"
    du -sh "$WORKSPACE_DIR" 2>/dev/null || true
    find "$WORKSPACE_DIR" -maxdepth 2 -type d \( -name out -o -name output_user_root -o -name dist \) -print 2>/dev/null || true
  fi
} > "$STAGING_DIR/workspace-diagnostics.txt"

copy_tree_contents_if_exists "$LOG_SOURCE_DIR"

if [ -f "$LOG_SOURCE_DIR/build-exit-code.txt" ]; then
  BUILD_EXIT_CODE="$(tr -d '\n' < "$LOG_SOURCE_DIR/build-exit-code.txt")"
fi

copy_if_exists "$WORKSPACE_DIR/manifest-trim-report.txt" "manifest-trim-report.txt"
copy_if_exists "$WORKSPACE_DIR/.repo/local_manifests/coreshift-overlay.xml" ".repo/local_manifests/coreshift-overlay.xml"
copy_common_artifact "$WORKSPACE_DIR/common/features.fragment"
copy_common_artifact "$WORKSPACE_DIR/common/lto.fragment"
copy_common_artifact "$WORKSPACE_DIR/common/private.required"
copy_common_artifact "$WORKSPACE_DIR/common/coreshift.kleaf.fragment"
copy_common_artifact "$WORKSPACE_DIR/common/.config"
copy_common_artifact "$WORKSPACE_DIR/dist/.config"
copy_common_artifact "$WORKSPACE_DIR/dist/System.map"
copy_common_artifact "$WORKSPACE_DIR/dist/build.log"

copy_reject_like_files "$WORKSPACE_DIR/common"

find "$STAGING_DIR" \
  \( -name .git -o -path '*/out/*' -o -path '*/output_user_root/*' -o -name '*.zip' \) \
  -prune -exec rm -rf {} + 2>/dev/null || true

write_summary

if command -v zip >/dev/null 2>&1; then
  (
    cd "$STAGING_DIR"
    zip -qr "$ZIP_PATH" .
  )
else
  python3 - "$STAGING_DIR" "$ZIP_PATH" <<'PY'
from pathlib import Path
import sys
import zipfile

root = Path(sys.argv[1])
zip_path = Path(sys.argv[2])
with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for path in sorted(root.rglob("*")):
        if path.is_file():
            zf.write(path, path.relative_to(root))
PY
fi

echo "Created log bundle: $ZIP_PATH"
