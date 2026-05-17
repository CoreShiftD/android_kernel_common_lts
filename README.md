# CoreShift ACK workspace

This repo uses a manifest-based ACK workspace design driven by `profiles/*.json`.

`manifests/coreshift-overlay.xml` is not a standalone repo manifest. It is a local manifest overlay copied into `.repo/local_manifests/` after `repo init` against `https://android.googlesource.com/kernel/manifest`. Its only current job is to remove the manifest-provided `kernel/common` checkout so the requested `kernel/common` branch can be cloned into `common/`.

CoreShift still syncs the rest of the ACK manifest workspace through `repo`, including the Kleaf, build, and prebuilt projects that `google_build_sh` and Kleaf need. Removing `kernel/common` from the overlay does not make manifest sync instant because those other manifest projects still come from `repo sync`.

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
2. Run `repo init -u https://android.googlesource.com/kernel/manifest -b "$MANIFEST_BRANCH"` with shallow sync defaults and partial clone enabled by default.
3. Copy `manifests/coreshift-overlay.xml` into `.repo/local_manifests/`.
4. Run `repo sync` with 4 jobs by default.
5. Clone `https://android.googlesource.com/kernel/common -b "$KERNEL_SOURCE_BRANCH"` into `common/`.

Manifest sync tuning knobs:

- CoreShift uses repo partial clone by default.
- Default repo sync jobs: 4.
- `kernel/common` is still cloned separately after `repo sync`.
- Users can tune sync behavior with:

```bash
./scripts/build-kernel.sh android13-5.15-lts \
  --build-env CORESHIFT_REPO_JOBS=2 \
  --build-env CORESHIFT_REPO_PARTIAL_CLONE=0 \
  --build-env CORESHIFT_REPO_CLONE_FILTER=blob:none
```

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
6. Generate `common/private.fragment`, `common/lto.fragment`, and `common/features.fragment` from the fixed CoreShift layering model.
7. Commit generated source/workspace changes inside `.work/<profile>/common` before the build so the kernel tree is not left dirty from CoreShift preparation.
8. Collect common build artifacts into `dist/<profile>/`.
9. Package a flashable AnyKernel3 zip into `dist/<profile>/` unless `--skip-ak3` is used.

Usage:

```bash
scripts/build-kernel.sh <profile-name> [--workspace DIR] [--mode auto|google_build_sh|kleaf] [--variant VARIANT] [--skip-setup] [--clean] [--skip-ak3] [--no-commit-workspace] [--disable-defconfig-check on|off] [--disable-kmi-check on|off] [--build-env KEY=VALUE] [-- EXTRA_BUILD_ARGS...]
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

This installs host tooling, downloads the upstream `repo` launcher into `$HOME/.local/bin/repo` so it is preferred over `/usr/bin/repo`, and installs Arm64 cross libc headers, `ccache`, and common kernel build dependencies from the current Ubuntu package sources. It does not override the ACK/AOSP Clang selected by the synced Google kernel manifest.

By default, it only runs `apt-get update` plus `apt-get install`, which is faster and more reproducible for CI. If you explicitly want a broader host package refresh, you can opt in to:

```bash
CORESHIFT_APT_UPGRADE=1 ./scripts/install-build-tools.sh
```

That is slower and less reproducible than the default update-and-install path.

For `android*-5.4-lts` profiles, `scripts/build-kernel.sh` always patches `common/usr/include/Makefile` in the prepared workspace so exported UAPI header tests append `UAPI_SYSROOT_CFLAGS`. This is required because 5.4 can still run `usr/include/*.hdrtest` even when header-install skip variables are set. The default sysroot points at `/usr/aarch64-linux-gnu/include`, which helps old 5.4 header tests find libc headers such as `sys/time.h`. GitHub Actions workflows get the needed cross libc packages through `./scripts/install-build-tools.sh`.

You can still override that explicitly:

```bash
./scripts/build-kernel.sh android12-5.4-lts \
  --build-env 'UAPI_SYSROOT_CFLAGS=--target=aarch64-linux-gnu -isystem /custom/sysroot/include'
```

This does not use environment `UAPI_CFLAGS` directly, because the kernel `common/usr/include/Makefile` defines `UAPI_CFLAGS` internally and an env override is not reliable.

For `google_build_sh` private builds, the old CoreShift-safe defaults are now applied unless you override them with `--build-env`:

- `SKIP_MRPROPER=1`
- `SKIP_CP_KERNEL_HDRS=1`
- `SKIP_UNSTRIPPED_MODULES=1`
- `SKIP_DEBUG_INFO=1`
- `SKIP_EXT_MODULES=1`
- `SKIP_HEADERS_INSTALL=1`

This matches the old working CoreShift-GKI behavior where applicable. Header install/tests are skipped by default on the `google_build_sh` path, but the 5.4 UAPI Makefile patch is still applied because those hdrtests may still run anyway. To run strict header tests explicitly, pass:

```bash
./scripts/build-kernel.sh android12-5.4-lts --build-env SKIP_HEADERS_INSTALL=0
```

On 5.4 profiles, `UAPI_SYSROOT_CFLAGS` is still available by default unless you override it yourself. This does not patch kernel UAPI header source files.

This is separate from skipping header install/tests. If you intentionally want the fast/private path, you can still pass:

```bash
./scripts/build-kernel.sh android12-5.4-lts --build-env SKIP_HEADERS_INSTALL=1
```

For large local builds, especially full-LTO runs, you can also add swap before compiling:

```bash
./scripts/add-swap.sh 24
```

You can also prepare `ccache` locally before building:

```bash
./scripts/setup-ccache.sh
./scripts/build-kernel.sh android12-5.4-lts
```

`ccache` effectiveness depends on whether the selected backend invokes compilers through ccache-compatible paths. Check cache results after a build with:

```bash
ccache -s
```

LTO is profile-aware:

- All current profile JSON files declare `lto` explicitly.
- Current policy is `"lto": "full"` for every profile except `android16-6.12-lts`.
- `android16-6.12-lts` sets `"lto": "thin"` because full LTO caused `rust_binder.ko` to disappear from Kleaf outputs.
- Full LTO overrides are intentionally rejected for `android16-6.12-lts` when passed through `--build-env LTO=full`, `private.fragment`, or `-- --lto=full`.
- On other profiles, users can still override LTO with `private.fragment` or `--build-env LTO=...`.
- Missing profile `lto` is still accepted for forward compatibility, but all current profiles set it explicitly so effective LTO comes from the profile field rather than an implied default.

For `google_build_sh`, default jobs are always kept at 4:

- `CORESHIFT_JOBS=4`
- `MAKEFLAGS=-j4`

If the effective LTO is `full`, compile jobs still stay at 4. Only LLVM/LLD link parallelism is throttled by default:

- `LLVM_PARALLEL_LINK_JOBS=1`
- `LLD_PARALLEL_LINK_JOBS=1`

You can override any of these with `--build-env KEY=VALUE`.

Examples:

```bash
./scripts/build-kernel.sh android13-5.15-lts

./scripts/build-kernel.sh android13-5.15-lts \
  --build-env LTO=full

./scripts/build-kernel.sh android12-5.4-lts \
  --build-env SKIP_HEADERS_INSTALL=0
```

### Ccache notes

CoreShift uses stock Ubuntu `ccache` by default. It does not download WildKernels or any other custom ccache binary.

`ccache` hits depend on:

- The same profile
- The same source revision
- The same compiler or toolchain content
- The same relevant compiler flags
- Stable paths, helped by `CCACHE_BASEDIR` and `CCACHE_NOHASHDIR`
- The build backend actually invoking compilers through `ccache`

The first run will mostly miss. A second run on the same profile and source should hit more often.

For `google_build_sh`, CoreShift now uses wrapper symlinks so `clang`, `clang++`, `gcc`, `g++`, `cc`, and `c++` resolve through `ccache` before the repo-synced toolchains in `PATH`. Those wrappers are only enabled when a repo/AOSP clang is found inside the prepared workspace.

Multiple AOSP clang prebuilts can exist in the same workspace. CoreShift therefore tries to wrap the clang selected by the effective `google_build_sh` build config first, instead of just taking the first `clang` found in the tree.

The wrapper must resolve to repo/AOSP clang, not Ubuntu clang. If no repo clang is found, CoreShift disables wrappers and continues without ccache interception.

If the build-config-selected repo clang cannot run because old compatibility libraries are missing, such as `libncurses.so.5`, CoreShift also disables wrappers and continues without ccache interception. `./scripts/install-build-tools.sh` attempts to install those compatibility libraries when the runner packages still provide them.

CoreShift also enables broader but still reasonable kernel-build cache settings by default. In particular, `CCACHE_IGNOREOPTIONS=--sysroot*` helps avoid sysroot path churn causing misses, but you can override it with `--build-env`.

Per-run stats are zeroed before the build by default so the post-build stats are easier to read.

If `ccache -s` shows only cache size information and no cacheable calls, the compiler is still not going through `ccache`. In that case, inspect:

```bash
command -v clang
clang --version
printf '%s\n' "${CCACHE_PATH:-}"
readlink -f "$(command -v clang)"
ccache -s
```

If those still show zero cacheable calls across repeated runs, Google `build.sh` may be forcing the real Clang path ahead of the wrapper path.

You can enable ccache debug logging with:

```bash
CORESHIFT_CCACHE_DEBUG=1 ./scripts/setup-ccache.sh
./scripts/build-kernel.sh android13-5.15-lts --build-env CORESHIFT_CCACHE_DEBUG=1
```

In GitHub Actions, set `CORESHIFT_CCACHE_DEBUG=1` in the workflow environment if you want `setup-ccache.sh` to persist a log path before the build.

Scope:

This produces ACK/GKI kernel build artifacts and a local AnyKernel3 flashable zip by default. Device-specific `vendor_boot` or other packaging beyond the included AnyKernel3 template is still separate and may require device-specific configuration.

### AnyKernel3 packaging

Builds now produce a flashable AnyKernel3 zip by default using `DikyVinus/AnyKernel3`.

- AK3 source: `https://github.com/DikyVinus/AnyKernel3`
- Output format: `dist/<profile>/<kernel_version>-CoreShift.zip`
- Zip contents include `Image`, `ikconfig.txt`, and the AnyKernel3 scripts/tools
- `ikconfig.txt` is copied from the final full build `.config`
- Raw collected files may still exist locally under `dist/<profile>/` after a local build
- GitHub Actions uploads only the AK3 zip artifact, not the full `dist/<profile>/` directory
- Future suffixes can append `KSU`, `SUSFS`, or `BBG` later via `CORESHIFT_AK3_SUFFIXES`, but nothing is added automatically yet

Local users can skip packaging if they only want the raw collected outputs:

```bash
./scripts/build-kernel.sh android12-5.4-lts --skip-ak3
```

### Build variants

CoreShift uses a JSON-driven variant model:

- `profiles/*.json` defines kernel branches and build backends
- `configs/variants.json` defines what a variant means
- `configs/profile-variants.json` defines which variants are allowed for each profile

Implemented optional features:

- `bbg` via upstream `Baseband-guard/setup.sh`
- `ksu` via upstream `KernelSU/kernel/setup.sh`

Not implemented yet:

- `susfs`

Enabled variants by profile generation:

- `bbg` is enabled for all current profiles
- `ksu` and `ksu-bbg` are enabled for 5.10+ profiles only

5.4 `ksu` is disabled by default because current KernelSU `main` includes `linux/pgtable.h`, which is missing on the tested 5.4 ACK common trees.

Feature application uses the resolved variant feature list in stable order:

- `ksu` first
- `bbg` second

This matters for `ksu-bbg`.

Defaults:

- `BBG_REF=main`
- `KSU_REF=main`

Users who want pinned or reproducible builds can override refs explicitly:

```bash
./scripts/build-kernel.sh android12-5.10-lts --variant ksu-bbg \
  --build-env KSU_REF=<commit-or-tag> \
  --build-env BBG_REF=<commit-or-tag>
```

Users who want to experiment with 5.4 KernelSU can edit `configs/profile-variants.json` locally and pin `KSU_REF` to a known-good 5.4-compatible commit.

Current workflow split:

- `Build.yml`: one profile plus one explicitly chosen variant
- `Build-All.yml`: all profiles, vanilla baseline only
- `Build-Variants.yml`: JSON-driven allowed profile x variant matrix for all enabled profile/variant combinations
- Feature repos are shallow-cloned for CI speed.
- `bbg` writes variant-owned config into `common/features.fragment`, including quoted `CONFIG_LSM` with `baseband_guard`.
- `ksu` writes variant-owned config into `common/features.fragment`.
- CoreShift defaults live in `configs/fragments/coreshift.fragment`.
- Every current profile JSON declares `lto` explicitly.
- All current profiles use full LTO except `android16-6.12-lts`, which uses thin LTO.
- `android16-6.12-lts` uses thin LTO because full LTO broke the Kleaf `rust_binder.ko` output.
- Full LTO overrides are intentionally rejected on `android16-6.12-lts`.
- Default filesystems enabled are `TMPFS`, `TMPFS_XATTR`, `OVERLAY_FS`, and `FUSE_FS`.
- KernelSU and Baseband-guard are kept as temporary git checkouts during build for version metadata.
- Users can still pin refs with `--build-env KSU_REF=<commit-or-tag>` and `--build-env BBG_REF=<commit-or-tag>`.

AK3 zip suffixes are driven by the resolved variant:

- `vanilla` -> `<kernel_version>-CoreShift.zip`
- `bbg` -> `<kernel_version>-CoreShift-BBG.zip`
- `ksu` -> `<kernel_version>-CoreShift-KSU.zip`
- `ksu-bbg` -> `<kernel_version>-CoreShift-KSU-BBG.zip`

### Workspace commit

CoreShift commits generated workspace and source changes inside the temporary `.work/<profile>/common` git repo before building. This helps avoid `-dirty` in kernel version strings after CoreShift preparation updates files such as generated fragments, generated build configs, or pre-build source patches.

- It does not push anything.
- It does not modify upstream remotes.
- It does not affect this repository or the user's main repo.
- It keeps `KernelSU/.git` and `Baseband-guard/.git` during build for version metadata.
- It excludes both `KernelSU/` and `Baseband-guard/` from the prepared workspace commit and still removes their `.github` metadata.
- It scans for unexpected nested `.git` paths under `common/` and refuses to continue if they are not part of the known feature staging dirs.
- It refuses staged gitlinks or submodule-like `160000` entries, so embedded git repositories/submodules cannot be committed accidentally.

Local users can disable the pre-build workspace commit:

```bash
./scripts/build-kernel.sh android12-5.4-lts --no-commit-workspace
```

### Private fragment model

CoreShift uses a fixed fragment layer order:

1. base ACK defconfig
2. CoreShift default fragment
3. user `private.fragment` last
4. profile `lto.fragment`
5. variant `features.fragment`

`private.fragment` lives at the repo root and is intentionally local and user-editable. Use Kconfig fragment syntax, not a full `.config`. User `private.fragment` content is always layered last, so duplicate `CONFIG_` values there win over earlier layers.

CoreShift ships:

- `configs/fragments/coreshift.fragment`
- `configs/fragments/private.fragment.example`

`scripts/prepare-private-fragment.sh` generates:

- `common/private.fragment`
- `common/private.required`
- `common/lto.fragment`
- `common/features.fragment`
- `common/coreshift.kleaf.fragment`

If you do not create a repo-root `private.fragment`, builds continue normally using only the CoreShift default fragment.

Ownership model:

- repo-root `private.fragment`: user-owned input
- `configs/fragments/coreshift.fragment`: baseline-owned input
- `common/lto.fragment`: profile-owned generated output
- `common/features.fragment`: variant-owned generated output

`configs/fragments/coreshift.fragment` carries the baseline CoreShift defaults, including the filesystem defaults. Repo-root `private.fragment` is still merged last so users can override those defaults, except that `android16-6.12-lts` intentionally rejects `CONFIG_LTO_CLANG_FULL=y`.

`google_build_sh` merges base defconfig plus `common/private.fragment` plus `common/lto.fragment` plus `common/features.fragment`.

Kleaf consumes `common/coreshift.kleaf.fragment`, which is generated as `common/private.fragment` plus `common/lto.fragment` plus `common/features.fragment`.

### Private build escape hatches

For local experimentation, `build-kernel.sh` exposes:

- `--disable-defconfig-check on|off`
- `--disable-kmi-check on|off`

These are explicit private-build escape hatches. They do not guarantee device safety, ABI stability, or KMI compatibility.

### GitHub Actions template

The repo includes a beginner-friendly template workflow at `.github/workflows/Build.yml`. It intentionally exposes only:

- `profile`
- `variant`
- `private_fragment`
- `build_env`
- `disable_defconfig_check`
- `disable_kmi_check`

It checks out the current repository, optionally writes a repo-root `private.fragment`, calls `./scripts/build-kernel.sh`, and uploads only the generated AnyKernel3 zip from `dist/<profile>/*.zip`.

The GitHub Actions workflows install required host/build tools automatically before invoking `scripts/build-kernel.sh`.

They install the latest versions available from the configured Ubuntu runner apt repositories after `apt-get update`. This prepares host tooling, the Android `repo` launcher, Arm64 cross libc headers, `ccache`, and common kernel build dependencies, but it does not override the ACK/AOSP Clang selected by the Google manifest.

The workflows also restore and save `~/.cache/ccache` with `actions/cache`, run `./scripts/setup-ccache.sh`, and print `ccache -s` plus `ccache --show-config` before and after each build.

CI uses a 24GB swap file before kernel compilation with aggressive swap tuning.

This helps memory-spiky LTO/Kleaf builds survive late link stages.

It can slow builds if the runner starts heavily swapping.

If `android14-5.15-lts` still dies with aggressive swap, the issue is likely not simple swap size and should be tested with LTO reduced or disabled.

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

The repo also includes `.github/workflows/Build-All.yml`, a no-option matrix workflow that builds every profile in `profiles/*.json` with the `vanilla` baseline variant and uploads one artifact per profile.

It is intended for batch validation, not customization, and can be expensive because it runs many kernel builds. It also disables the defconfig normalization check by default for every matrix build. Per-profile customization belongs in `Build.yml` or direct local use of `scripts/build-kernel.sh`.

Device-specific packaging dependencies remain separate from this host-tool installer.

## Related workflows

`sync-kernel-source.yml` stays separate from manifest workspace setup. It mirrors `https://android.googlesource.com/kernel/common` source branches directly and does not use repo manifests.

The old clang release workflow was removed because the repo no longer carries dedicated clang metadata in the current profile schema.

`.github/workflows/Build-Variants.yml` resolves its matrix from `configs/variants.json` plus `configs/profile-variants.json` through `scripts/resolve-build-matrix.py`. It does not hardcode profile x variant combinations in YAML and only builds combinations explicitly allowed by the JSON compatibility map.
