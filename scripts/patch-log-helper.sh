#!/usr/bin/env bash

coreshift_patch_log_enabled() {
  [ -n "${CORESHIFT_LOG_DIR:-}" ]
}

coreshift_patch_log_feature_dir() {
  printf '%s/patches/%s\n' "$CORESHIFT_LOG_DIR" "$1"
}

coreshift_patch_log_init() {
  local feature="$1"
  local profile="${2:-unknown}"
  local variant="${3:-unknown}"
  local feature_dir

  coreshift_patch_log_enabled || return 0
  feature_dir="$(coreshift_patch_log_feature_dir "$feature")"
  mkdir -p \
    "$feature_dir/selected-patches" \
    "$feature_dir/touched-files" \
    "$feature_dir/checks" \
    "$feature_dir/apply" \
    "$feature_dir/rejects" \
    "$feature_dir/source-context"
  {
    echo "profile: $profile"
    echo "variant: $variant"
    date -u '+generated_at_utc: %Y-%m-%dT%H:%M:%SZ'
  } > "$feature_dir/metadata.txt"
}

coreshift_patch_log_touched_files() {
  local patch_file="$1"

  coreshift_patch_log_enabled || return 0
  [ -f "$patch_file" ] || return 0

  awk '
    /^diff --git / {
      path_a = $3
      path_b = $4
      sub(/^a\//, "", path_a)
      sub(/^b\//, "", path_b)
      if (path_a != "/dev/null" && path_a != "") {
        print path_a
      }
      if (path_b != "/dev/null" && path_b != "") {
        print path_b
      }
      next
    }
    /^(---|\+\+\+) / {
      path = $2
      sub(/^[ab]\//, "", path)
      if (path != "/dev/null" && path != "") {
        print path
      }
    }
  ' "$patch_file" | sed '/^$/d' | sort -u
}

coreshift_patch_log_copy_patch() {
  local feature="$1"
  local patch_file="$2"
  local feature_dir

  coreshift_patch_log_enabled || return 0
  [ -f "$patch_file" ] || return 0

  feature_dir="$(coreshift_patch_log_feature_dir "$feature")"
  mkdir -p "$feature_dir/selected-patches"
  cp "$patch_file" "$feature_dir/selected-patches/$(basename "$patch_file")"
}

coreshift_patch_log_patch_plan() {
  local feature="$1"
  shift
  local feature_dir
  local patch_file
  local touched_output

  coreshift_patch_log_enabled || return 0
  feature_dir="$(coreshift_patch_log_feature_dir "$feature")"
  mkdir -p "$feature_dir/selected-patches" "$feature_dir/touched-files"
  : > "$feature_dir/selected-patches/index.txt"
  : > "$feature_dir/all-touched-files.txt"

  for patch_file in "$@"; do
    [ -f "$patch_file" ] || continue
    printf '%s\n' "$patch_file" >> "$feature_dir/selected-patches/index.txt"
    coreshift_patch_log_copy_patch "$feature" "$patch_file"
    touched_output="$feature_dir/touched-files/$(basename "$patch_file").txt"
    coreshift_patch_log_touched_files "$patch_file" > "$touched_output"
    if [ -s "$touched_output" ]; then
      cat "$touched_output" >> "$feature_dir/all-touched-files.txt"
    fi
  done

  if [ -s "$feature_dir/all-touched-files.txt" ]; then
    sort -u "$feature_dir/all-touched-files.txt" -o "$feature_dir/all-touched-files.txt"
  fi
}

coreshift_patch_log_copy_rejects() {
  local feature="$1"
  local common_dir="$2"
  local feature_dir
  local rejects_dir
  local file_path
  local relative_path
  local found=0

  coreshift_patch_log_enabled || return 0
  [ -d "$common_dir" ] || return 0

  feature_dir="$(coreshift_patch_log_feature_dir "$feature")"
  rejects_dir="$feature_dir/rejects"
  rm -rf "$rejects_dir"
  mkdir -p "$rejects_dir"
  : > "$rejects_dir/index.txt"

  while IFS= read -r -d '' file_path; do
    relative_path="${file_path#"$common_dir/"}"
    mkdir -p "$rejects_dir/$(dirname "$relative_path")"
    cp "$file_path" "$rejects_dir/$relative_path"
    printf '%s\n' "$relative_path" >> "$rejects_dir/index.txt"
    found=1
  done < <(find "$common_dir" -type f \( -name '*.rej' -o -name '*.orig' \) -print0)

  if [ "$found" -eq 0 ]; then
    printf '%s\n' "(none)" > "$rejects_dir/index.txt"
  fi
}

coreshift_patch_log_source_context() {
  local feature="$1"
  local common_dir="$2"
  local patch_file="$3"
  local feature_dir
  local patch_name
  local context_root
  local relative_path
  local source_file
  local output_file
  local start_line
  local snippet_from
  local snippet_to
  local hunk_count

  coreshift_patch_log_enabled || return 0
  [ -d "$common_dir" ] || return 0
  [ -f "$patch_file" ] || return 0

  feature_dir="$(coreshift_patch_log_feature_dir "$feature")"
  patch_name="$(basename "$patch_file")"
  context_root="$feature_dir/source-context/$patch_name"
  mkdir -p "$context_root"

  while IFS= read -r relative_path; do
    [ -n "$relative_path" ] || continue
    source_file="$common_dir/$relative_path"
    [ -f "$source_file" ] || continue

    output_file="$context_root/$relative_path.context.txt"
    mkdir -p "$(dirname "$output_file")"
    {
      echo "file: $relative_path"
      echo
      hunk_count=0
      while IFS= read -r start_line; do
        [ -n "$start_line" ] || continue
        hunk_count=$((hunk_count + 1))
        if [ "$hunk_count" -gt 5 ]; then
          break
        fi
        snippet_from=$((start_line - 12))
        if [ "$snippet_from" -lt 1 ]; then
          snippet_from=1
        fi
        snippet_to=$((start_line + 20))
        echo "hunk-target-lines: $snippet_from-$snippet_to"
        nl -ba "$source_file" | sed -n "${snippet_from},${snippet_to}p"
        echo
      done < <(
        awk -v wanted="$relative_path" '
          /^\+\+\+ / {
            file = $2
            sub(/^b\//, "", file)
            if (file == "/dev/null") {
              file = ""
            }
            next
          }
          /^@@ / && file == wanted {
            for (index = 1; index <= NF; index++) {
              if ($index ~ /^\+[0-9]/) {
                value = $index
                sub(/^\+/, "", value)
                sub(/,.*/, "", value)
                print value
                break
              }
            }
          }
        ' "$patch_file"
      )

      if [ "$hunk_count" -eq 0 ]; then
        echo "first-120-lines:"
        nl -ba "$source_file" | sed -n '1,120p'
      fi
    } > "$output_file"
  done < <(coreshift_patch_log_touched_files "$patch_file")
}

coreshift_patch_log_git_diff() {
  local feature="$1"
  local repo_dir="$2"
  local label="$3"
  local feature_dir
  local touched_index
  local stat_path
  local patch_path
  local -a touched_files=()

  coreshift_patch_log_enabled || return 0
  git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  feature_dir="$(coreshift_patch_log_feature_dir "$feature")"
  touched_index="$feature_dir/all-touched-files.txt"
  stat_path="$feature_dir/$label.stat"
  patch_path="$feature_dir/$label.patch"

  if [ -s "$touched_index" ]; then
    mapfile -t touched_files < "$touched_index"
    git -C "$repo_dir" diff --stat -- "${touched_files[@]}" > "$stat_path" 2>/dev/null || : > "$stat_path"
    git -C "$repo_dir" diff -- "${touched_files[@]}" > "$patch_path" 2>/dev/null || : > "$patch_path"
  else
    git -C "$repo_dir" diff --stat > "$stat_path" 2>/dev/null || : > "$stat_path"
    git -C "$repo_dir" diff > "$patch_path" 2>/dev/null || : > "$patch_path"
  fi
}

coreshift_patch_log_triage() {
  local feature="$1"
  local reason="$2"
  shift 2
  local feature_dir
  local profile="unknown"
  local variant="unknown"
  local metadata_path
  local detail

  coreshift_patch_log_enabled || return 0
  feature_dir="$(coreshift_patch_log_feature_dir "$feature")"
  metadata_path="$feature_dir/metadata.txt"
  if [ -f "$metadata_path" ]; then
    profile="$(sed -n 's/^profile: //p' "$metadata_path" | head -n 1)"
    variant="$(sed -n 's/^variant: //p' "$metadata_path" | head -n 1)"
  fi

  {
    echo "# CoreShift patch triage"
    echo
    echo "- feature: $feature"
    echo "- profile: ${profile:-unknown}"
    echo "- variant: ${variant:-unknown}"
    echo "- likely category: $reason"
    for detail in "$@"; do
      printf '%s\n' "$detail"
    done
  } > "$feature_dir/triage.md"
}
