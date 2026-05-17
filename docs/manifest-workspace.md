# Manifest workspace

## ACK manifest design

CoreShift uses the Android ACK manifest as the base workspace definition and applies a local overlay before syncing the tree.

`manifests/coreshift-overlay.xml` is a local overlay, not a standalone manifest.

## `kernel/common` handling

- `kernel/common` is removed from the manifest-driven checkout by the local overlay
- CoreShift then clones the requested `kernel/common` branch separately into `common/`

This keeps the manifest branch selection and the `kernel/common` branch selection under explicit CoreShift control.

## Why repo sync still matters

Removing `kernel/common` from the overlay does not make sync instant.

`repo sync` still pulls the other manifest projects needed by the build, including the Kleaf, build, and prebuilt/toolchain pieces used by both `google_build_sh` and Kleaf workflows.

## Default sync tuning

Current defaults in `scripts/setup-manifest-workspace.sh`:

- `CORESHIFT_REPO_JOBS=4`
- `CORESHIFT_REPO_DEPTH=1`
- `CORESHIFT_REPO_PARTIAL_CLONE=1`
- `CORESHIFT_REPO_CLONE_FILTER=blob:none`

Repo setup prefers the upstream launcher installed at `$HOME/.local/bin/repo`.

## Tuning knobs

You can tune manifest setup with:

- `CORESHIFT_REPO_JOBS`
- `CORESHIFT_REPO_DEPTH`
- `CORESHIFT_REPO_PARTIAL_CLONE`
- `CORESHIFT_REPO_CLONE_FILTER`

Example:

```bash
./scripts/build-kernel.sh android13-5.15-lts \
  --build-env CORESHIFT_REPO_JOBS=2 \
  --build-env CORESHIFT_REPO_PARTIAL_CLONE=0 \
  --build-env CORESHIFT_REPO_CLONE_FILTER=blob:none
```

