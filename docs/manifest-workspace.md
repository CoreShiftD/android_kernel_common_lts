# Manifest workspace

## ACK manifest design

CoreShift uses the Android ACK manifest as the base workspace definition. It runs `repo init` first, then generates or installs a local overlay before `repo sync`.

`manifests/coreshift-overlay.xml` is a local overlay, not a standalone manifest.

CoreShift also supports profile-specific overlay manifests through the `overlay_manifest` field in each profile JSON.

## `kernel/common` handling

- `kernel/common` is removed from the manifest-driven checkout by the local overlay
- CoreShift then clones the requested `kernel/common` branch separately into `common/`

This keeps the manifest branch selection and the `kernel/common` branch selection under explicit CoreShift control.

## Dynamic trim modes

- Default trim mode is `CORESHIFT_MANIFEST_TRIM=aggressive`
- `aggressive` inspects the resolved manifest with `repo manifest -o ...` and generates `.repo/local_manifests/coreshift-overlay.xml` from the actual project list
- `safe` removes only `kernel/common`
- `none` disables aggressive trimming; by default CoreShift still removes `kernel/common` unless `CORESHIFT_KEEP_MANIFEST_COMMON=1` is set
- Every setup run also writes `manifest-trim-report.txt` in the workspace root with kept projects, removed projects, and the keep reason for each retained project

Aggressive trim is experimental and backend-aware. Kleaf-capable profiles intentionally keep more Bazel, Rust, JDK, and prebuilts coverage than `google_build_sh`-only profiles.

## Static overlays

- Profiles can point at a static safe overlay file with `overlay_manifest`
- If a profile omits `overlay_manifest`, CoreShift falls back to `manifests/overlays/default.xml`
- If that default overlay is missing, CoreShift falls back again to `manifests/coreshift-overlay.xml`
- The current static overlays are intentionally conservative and remove only `kernel/common`
- Safe-mode trim uses the selected static overlay as the conservative fallback input

## Why repo sync still matters

Removing `kernel/common` from the overlay does not make sync instant.

`repo sync` still pulls the other manifest projects needed by the build, including the Kleaf, build, and prebuilt/toolchain pieces used by both `google_build_sh` and Kleaf workflows.

Future optimization can remove more projects per profile after build validation. Kleaf-backed profiles should be treated carefully because they may still need build, prebuilt, Rust, and Bazel-related manifest projects.

## Default sync tuning

Current defaults in `scripts/setup-manifest-workspace.sh`:

- `CORESHIFT_REPO_JOBS=4`
- `CORESHIFT_REPO_DEPTH=1`
- `CORESHIFT_REPO_PARTIAL_CLONE=1`
- `CORESHIFT_REPO_CLONE_FILTER=blob:none`

CoreShift updates the upstream repo launcher into `$HOME/.local/bin/repo` by default and prefers that path over `/usr/bin/repo`.
Repo verification stays enabled by default. `CORESHIFT_REPO_NO_VERIFY=1` exists only as an escape hatch.

## Tuning knobs

You can tune manifest setup with:

- `CORESHIFT_REPO_JOBS`
- `CORESHIFT_REPO_DEPTH`
- `CORESHIFT_REPO_PARTIAL_CLONE`
- `CORESHIFT_REPO_CLONE_FILTER`
- `CORESHIFT_MANIFEST_TRIM`
- `CORESHIFT_REPO_NO_VERIFY`

Examples:

```bash
./scripts/build-kernel.sh android16-6.12-lts \
  --build-env CORESHIFT_MANIFEST_TRIM=safe
```

```bash
./scripts/build-kernel.sh android16-6.12-lts \
  --build-env CORESHIFT_MANIFEST_TRIM=none
```

```bash
./scripts/build-kernel.sh android16-6.12-lts \
  --build-env CORESHIFT_REPO_JOBS=2 \
  --build-env CORESHIFT_REPO_PARTIAL_CLONE=0 \
  --build-env CORESHIFT_REPO_CLONE_FILTER=blob:none
```
