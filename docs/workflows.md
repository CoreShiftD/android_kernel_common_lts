# GitHub Actions workflows

## Main build workflows

### `Build.yml`

Single selected profile and variant build.

Current `workflow_dispatch` inputs:

- `profile`
- `variant`
- `private_fragment`
- `disable_defconfig_check`
- `disable_kmi_check`
- `build_env`

`private_fragment` writes a repo-root `private.fragment` inside the workflow checkout before the build. `build_env` accepts one `KEY=VALUE` entry per line for advanced overrides.

### `Build-All.yml`

- No user inputs
- Runs a profile matrix across supported branches
- Always builds `vanilla`
- Intended for broad baseline coverage, not variant coverage

### `Build-Variants.yml`

- Inputs:
  - `profile` filter
  - `variant` filter
- Uses `python3 scripts/resolve-build-matrix.py` to build a JSON-driven allowed matrix
- Builds only allowed profile/variant combinations from repo config

## Artifact behavior

The build workflows upload only generated AnyKernel3 zip artifacts from `dist/<profile>/`.

## CI build environment

The main build workflows currently:

- Install tools with `./scripts/install-build-tools.sh`
- Set up `ccache` with `./scripts/setup-ccache.sh`
- Add aggressive 24 GB swap with `./scripts/add-swap.sh 24 --aggressive`
- Restore and save `~/.cache/ccache`
- Opt into Node.js 24 for JavaScript actions with `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true`

## Utility workflows

The repo also contains utility workflows outside the main build trio, including:

- `sync-kernel-source.yml`
- `validate-manifest-workspace.yml`

They support branch sync and repo validation, not end-user kernel packaging.

All current workflows that use JavaScript actions opt into Node.js 24 through `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true`. This avoids Node.js 20 deprecation annotations while keeping the current action pins unchanged.
