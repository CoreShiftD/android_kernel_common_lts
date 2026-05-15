# CoreShift ACK workspace

This repo uses a manifest-based ACK workspace design driven by `profiles/*.json`.

`manifests/coreshift-overlay.xml` is not a standalone repo manifest. It is a local manifest overlay copied into `.repo/local_manifests/` after `repo init` against `https://android.googlesource.com/kernel/manifest`. Its only current job is to remove the manifest-provided `kernel/common` checkout so the requested `kernel/common` branch can be cloned into `common/`.

## Profile schema

Each profile in `profiles/*.json` must define:

- `name`
- `manifest_branch` set to `common-<name>`
- `kernel_source_branch`
- `build_config`
- `bazel_target` as a string or `null`

`name` and `kernel_source_branch` must match one of the supported ACK LTS branches:

- `android11-5.4-lts`
- `android12-5.4-lts`
- `android12-5.10-lts`
- `android13-5.10-lts`
- `android13-5.15-lts`
- `android14-5.15-lts`
- `android14-6.1-lts`
- `android15-6.6-lts`
- `android16-6.12-lts`

For example:

- `android11-5.4-lts` uses `manifest_branch: "common-android11-5.4-lts"`
- `android12-5.4-lts` uses `manifest_branch: "common-android12-5.4-lts"`
- `android12-5.10-lts` uses `manifest_branch: "common-android12-5.10-lts"`
- `android13-5.15-lts` uses `manifest_branch: "common-android13-5.15-lts"`
- `android16-6.12-lts` uses `manifest_branch: "common-android16-6.12-lts"`

## Workspace setup

Initialize a workspace with a profile:

```bash
scripts/setup-manifest-workspace.sh profiles/<branch>.json <workspace>
```

This script will:

1. Read `manifest_branch` and `kernel_source_branch` from the profile.
2. Run `repo init -u https://android.googlesource.com/kernel/manifest -b "$MANIFEST_BRANCH"`.
3. Copy `manifests/coreshift-overlay.xml` into `.repo/local_manifests/`.
4. Run `repo sync`.
5. Clone `https://android.googlesource.com/kernel/common -b "$KERNEL_SOURCE_BRANCH"` into `common/`.

Run a manifest workspace build with:

```bash
scripts/run-manifest-build.sh profiles/<branch>.json <workspace> google_build_sh
```

Use `kleaf` instead of `google_build_sh` when the profile defines a non-null `bazel_target`.

## One-command build

Clone the repo and run a profile build directly:

```bash
git clone https://github.com/CoreShiftD/android_kernel_common_lts
cd android_kernel_common_lts
./scripts/build-kernel.sh android12-5.4-lts
```

This entrypoint will:

1. Resolve `profiles/<profile>.json`.
2. Validate the profile set.
3. Create or reuse `.work/<profile>`.
4. Initialize or refresh the ACK manifest workspace unless `--skip-setup` is used.
5. Select `google_build_sh` automatically when available, with `kleaf` as an explicit mode or auto fallback when `build/build.sh` is unavailable and the profile defines `bazel_target`.
6. Collect common build artifacts into `dist/<profile>/`.

Usage:

```bash
scripts/build-kernel.sh <profile-name> [--workspace DIR] [--mode auto|google_build_sh|kleaf] [--skip-setup] [--clean] [-- EXTRA_BUILD_ARGS...]
```

Required host tools:

- `git`
- `python3`
- `repo`
- Standard Android kernel build dependencies supplied by the ACK manifest/tooling

Scope:

This produces ACK/GKI kernel build artifacts. Device-specific `boot`, `vendor_boot`, or AnyKernel-style packaging is separate and requires device-specific configuration.

## Related workflows

`sync-kernel-source.yml` stays separate from manifest workspace setup. It mirrors `https://android.googlesource.com/kernel/common` source branches directly and does not use repo manifests.

The old clang release workflow was removed because the repo no longer carries dedicated clang metadata in the current profile schema.
