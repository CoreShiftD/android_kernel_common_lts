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

## Related workflows

`sync-kernel-source.yml` stays separate from manifest workspace setup. It mirrors `https://android.googlesource.com/kernel/common` source branches directly and does not use repo manifests.

The old clang release workflow was removed because the repo no longer carries dedicated clang metadata in the current profile schema.
