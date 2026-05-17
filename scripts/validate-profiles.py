#!/usr/bin/env python3
"""Validate CoreShift ACK profile definitions."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_BRANCHES = (
    "android11-5.4-lts",
    "android12-5.4-lts",
    "android12-5.10-lts",
    "android13-5.10-lts",
    "android13-5.15-lts",
    "android14-5.15-lts",
    "android14-6.1-lts",
    "android15-6.6-lts",
    "android16-6.12-lts",
)

REQUIRED_FIELDS = (
    "name",
    "manifest_branch",
    "kernel_source_branch",
    "build_config",
    "bazel_target",
)

VALID_LTO_VALUES = ("full", "thin", "none", "default")
VALID_MANIFEST_TRIM_VALUES = ("safe", "aggressive", "none")


def fail(message: str) -> None:
    raise SystemExit(message)


def validate_string_list(path: Path, data: dict[str, object], field: str) -> None:
    value = data.get(field)
    if value is None:
        return
    if not isinstance(value, list):
        fail(f"{path}: field {field!r} must be a list of non-empty strings when present")
    for entry in value:
        if not isinstance(entry, str) or not entry:
            fail(f"{path}: field {field!r} must contain only non-empty strings")


def validate_profile(path: Path, repo_root: Path) -> str:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"{path}: invalid JSON: {exc}")

    if not isinstance(data, dict):
        fail(f"{path}: top-level JSON value must be an object")

    missing = [field for field in REQUIRED_FIELDS if field not in data]
    if missing:
        fail(f"{path}: missing required fields: {', '.join(missing)}")

    for field in ("name", "manifest_branch", "kernel_source_branch", "build_config"):
        value = data[field]
        if not isinstance(value, str) or not value:
            fail(f"{path}: field {field!r} must be a non-empty string")

    bazel_target = data["bazel_target"]
    if bazel_target is not None and (not isinstance(bazel_target, str) or not bazel_target):
        fail(f"{path}: field 'bazel_target' must be a non-empty string or null")

    lto = data.get("lto")
    if lto is not None and lto not in VALID_LTO_VALUES:
        allowed = ", ".join(VALID_LTO_VALUES)
        fail(f"{path}: field 'lto' must be one of: {allowed}")

    manifest_trim = data.get("manifest_trim")
    if manifest_trim is not None and manifest_trim not in VALID_MANIFEST_TRIM_VALUES:
        allowed = ", ".join(VALID_MANIFEST_TRIM_VALUES)
        fail(f"{path}: field 'manifest_trim' must be one of: {allowed}")

    validate_string_list(path, data, "manifest_keep_patterns")
    validate_string_list(path, data, "manifest_drop_projects")

    overlay_manifest = data.get("overlay_manifest")
    if overlay_manifest is not None:
        if not isinstance(overlay_manifest, str) or not overlay_manifest:
            fail(f"{path}: field 'overlay_manifest' must be a non-empty string when present")
        if not overlay_manifest.endswith(".xml"):
            fail(f"{path}: field 'overlay_manifest' must end with .xml")
        overlay_path = Path(overlay_manifest)
        if overlay_path.is_absolute():
            fail(f"{path}: field 'overlay_manifest' must be a repo-relative path under manifests/")
        overlay_parts = overlay_path.parts
        if not overlay_parts or overlay_parts[0] != "manifests":
            fail(f"{path}: field 'overlay_manifest' must stay under manifests/")
        resolved_overlay = (repo_root / overlay_path).resolve()
        manifests_root = (repo_root / "manifests").resolve()
        try:
            resolved_overlay.relative_to(manifests_root)
        except ValueError:
            fail(f"{path}: field 'overlay_manifest' must stay under manifests/")
        if not resolved_overlay.is_file():
            fail(f"{path}: overlay_manifest file not found: {overlay_manifest}")

    name = data["name"]
    manifest_branch = data["manifest_branch"]
    kernel_source_branch = data["kernel_source_branch"]

    if path.stem != name:
        fail(f"{path}: file name must match profile name {name!r}")

    if name not in EXPECTED_BRANCHES:
        fail(f"{path}: unexpected profile name {name!r}")

    expected_manifest_branch = f"common-{name}"
    if manifest_branch != expected_manifest_branch:
        fail(
            f"{path}: manifest_branch {manifest_branch!r} must equal "
            f"{expected_manifest_branch!r}"
        )

    if kernel_source_branch not in EXPECTED_BRANCHES:
        fail(f"{path}: unexpected kernel_source_branch {kernel_source_branch!r}")

    if name != kernel_source_branch:
        fail(
            f"{path}: name {name!r} must match kernel_source_branch "
            f"{kernel_source_branch!r}"
        )

    return name


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    profiles_dir = repo_root / "profiles"

    if not profiles_dir.is_dir():
        fail(f"profiles directory not found: {profiles_dir}")

    files = sorted(profiles_dir.glob("*.json"))
    if not files:
        fail(f"no profile JSON files found in {profiles_dir}")

    seen = {validate_profile(path, repo_root) for path in files}
    expected = set(EXPECTED_BRANCHES)

    missing = sorted(expected - seen)
    extra = sorted(seen - expected)

    if missing:
        fail(f"missing expected profiles: {', '.join(missing)}")
    if extra:
        fail(f"unexpected profiles present: {', '.join(extra)}")

    print(f"Validated {len(files)} profiles in {profiles_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
