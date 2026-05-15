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


def fail(message: str) -> None:
    raise SystemExit(message)


def validate_profile(path: Path) -> str:
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

    seen = {validate_profile(path) for path in files}
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
