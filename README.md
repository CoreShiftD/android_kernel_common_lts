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

To customize the kernel config privately:

```bash
cp configs/fragments/private.fragment.example private.fragment
nano private.fragment
./scripts/build-kernel.sh android12-5.4-lts
```

This entrypoint will:

1. Resolve `profiles/<profile>.json`.
2. Validate the profile set.
3. Create or reuse `.work/<profile>`.
4. Initialize or refresh the ACK manifest workspace unless `--skip-setup` is used.
5. Select `google_build_sh` automatically when available, with `kleaf` as an explicit mode or auto fallback when `build/build.sh` is unavailable and the profile defines `bazel_target`.
6. Generate `common/private.fragment` from the fixed CoreShift layering model.
7. Collect common build artifacts into `dist/<profile>/`.

Usage:

```bash
scripts/build-kernel.sh <profile-name> [--workspace DIR] [--mode auto|google_build_sh|kleaf] [--skip-setup] [--clean] [--disable-defconfig-check on|off] [--disable-kmi-check on|off] [--build-env KEY=VALUE] [-- EXTRA_BUILD_ARGS...]
```

Local build environment passthrough:

```bash
./scripts/build-kernel.sh android13-5.15-lts \
  --build-env LTO=full \
  --build-env SKIP_MRPROPER=1 \
  --build-env SKIP_EXT_MODULES=1
```

Required host tools:

- `git`
- `python3`
- `repo`
- Standard Android kernel build dependencies supplied by the ACK manifest/tooling

For local builds, you can install the required host tooling with:

```bash
./scripts/install-build-tools.sh
```

This installs host tooling, the `repo` launcher, Arm64 cross libc headers, and common kernel build dependencies from the current Ubuntu package sources. It does not override the ACK/AOSP Clang selected by the synced Google kernel manifest.

For `android*-5.4-lts` profiles, `scripts/build-kernel.sh` patches `common/usr/include/Makefile` in the prepared workspace so exported UAPI header tests append `UAPI_SYSROOT_CFLAGS`. By default, that points at `/usr/aarch64-linux-gnu/include`, which helps old 5.4 header tests find libc headers such as `sys/time.h`. GitHub Actions workflows get the needed cross libc packages through `./scripts/install-build-tools.sh`.

You can still override that explicitly:

```bash
./scripts/build-kernel.sh android12-5.4-lts \
  --build-env 'UAPI_SYSROOT_CFLAGS=--target=aarch64-linux-gnu -isystem /custom/sysroot/include'
```

This does not use environment `UAPI_CFLAGS` directly, because the kernel `common/usr/include/Makefile` defines `UAPI_CFLAGS` internally and an env override is not reliable.

This is separate from skipping header install/tests. If you intentionally want the fast/private path, you can still pass:

```bash
./scripts/build-kernel.sh android12-5.4-lts --build-env SKIP_HEADERS_INSTALL=1
```

For large local builds, especially full-LTO runs, you can also add swap before compiling:

```bash
./scripts/add-swap.sh 16
```

Scope:

This produces ACK/GKI kernel build artifacts. Device-specific `boot`, `vendor_boot`, or AnyKernel-style packaging is separate and requires device-specific configuration.

### Private fragment model

CoreShift uses a fixed fragment layer order:

1. base ACK defconfig
2. CoreShift default fragment
3. user `private.fragment` last

`private.fragment` lives at the repo root and is intentionally local and user-editable. Use Kconfig fragment syntax, not a full `.config`. User `private.fragment` content is always layered last, so duplicate `CONFIG_` values there win over earlier layers.

CoreShift ships:

- `configs/fragments/coreshift.fragment`
- `configs/fragments/private.fragment.example`

`scripts/prepare-private-fragment.sh` combines them into:

- `common/private.fragment`
- `common/private.required`

If you do not create a repo-root `private.fragment`, builds continue normally using only the CoreShift default fragment.

### Private build escape hatches

For local experimentation, `build-kernel.sh` exposes:

- `--disable-defconfig-check on|off`
- `--disable-kmi-check on|off`

These are explicit private-build escape hatches. They do not guarantee device safety, ABI stability, or KMI compatibility.

### GitHub Actions template

The repo includes a beginner-friendly template workflow at `.github/workflows/Build.yml`. It intentionally exposes only:

- `profile`
- `private_fragment`
- `build_env`
- `disable_defconfig_check`
- `disable_kmi_check`

It checks out the current repository, optionally writes a repo-root `private.fragment`, calls `./scripts/build-kernel.sh`, and uploads only `dist/<profile>/`.

The GitHub Actions workflows install required host/build tools automatically before invoking `scripts/build-kernel.sh`.

They install the latest versions available from the configured Ubuntu runner apt repositories after `apt-get update`. This prepares host tooling, the Android `repo` launcher, Arm64 cross libc headers, and common kernel build dependencies, but it does not override the ACK/AOSP Clang selected by the Google manifest.

They also add a 16GB swap file before kernel compilation.

The default workflow intentionally does not expose `repository`, `ref`, `mode`, or `extra_args`. Advanced users can edit `Build.yml` directly or run `scripts/build-kernel.sh` manually.

`build_env` accepts one `KEY=VALUE` entry per line:

```text
LTO=full
SKIP_MRPROPER=1
SKIP_EXT_MODULES=1
```

Rules:

- No `export`
- No shell syntax
- No semicolons
- Empty values are allowed
- Values are passed to the selected backend
- For `google_build_sh`, they reach Google `build/build.sh`
- For complex backend arguments, edit the workflow directly or run the script locally

Local repo-root `private.fragment` is ignored by git and is not automatically available to GitHub Actions. For Actions builds, paste the fragment into the `private_fragment` workflow input or customize your fork.

GitHub Actions workflows disable the defconfig normalization check by default. This avoids common private-fragment or non-normalized defconfig failures in workflow builds.

`disable_defconfig_check` is a boolean input that defaults to `true`, and `disable_kmi_check` is a boolean input that defaults to `false`. In the workflow, `true` maps to the script value `on`, and `false` maps to `off`.

KMI check bypass still defaults to `false`/`off` and must be explicitly enabled in `Build.yml`. These options do not guarantee device safety, ABI stability, or KMI compatibility.

Advanced users can still run locally with the full script surface:

```bash
./scripts/build-kernel.sh android13-5.15-lts \
  --mode google_build_sh \
  --disable-defconfig-check on \
  --disable-kmi-check on \
  --build-env LTO=full \
  -- EXTRA_BACKEND_ARGS
```

Local CLI behavior remains unchanged unless you explicitly pass:

```bash
./scripts/build-kernel.sh android13-5.15-lts --disable-defconfig-check on
```

### Build-All workflow

The repo also includes `.github/workflows/Build-All.yml`, a no-option matrix workflow that builds every profile in `profiles/*.json` and uploads one artifact per profile.

It is intended for batch validation, not customization, and can be expensive because it runs many kernel builds. It also disables the defconfig normalization check by default for every matrix build. Per-profile customization belongs in `Build.yml` or direct local use of `scripts/build-kernel.sh`.

Device-specific packaging dependencies remain separate from this host-tool installer.

## Related workflows

`sync-kernel-source.yml` stays separate from manifest workspace setup. It mirrors `https://android.googlesource.com/kernel/common` source branches directly and does not use repo manifests.

The old clang release workflow was removed because the repo no longer carries dedicated clang metadata in the current profile schema.
