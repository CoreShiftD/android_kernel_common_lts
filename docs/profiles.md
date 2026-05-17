# Profiles

## Supported profiles

- `android11-5.4-lts`
- `android12-5.4-lts`
- `android12-5.10-lts`
- `android13-5.10-lts`
- `android13-5.15-lts`
- `android14-5.15-lts`
- `android14-6.1-lts`
- `android15-6.6-lts`
- `android16-6.12-lts`

## Profile JSON schema

Each profile JSON under `profiles/` defines:

- `name`
- `manifest_branch`
- `overlay_manifest`
- `manifest_trim`
- `manifest_keep_patterns`
- `manifest_drop_projects`
- `kernel_source_branch`
- `build_config`
- `bazel_target`
- `lto`

Current profiles use `name == kernel_source_branch` and `manifest_branch == common-<name>`.

## Manifest trim values

- `manifest_trim`: `safe`, `aggressive`, or `none`
- `manifest_keep_patterns`: optional list of extra path/name patterns to keep during aggressive trim
- `manifest_drop_projects`: optional list of explicit project names to remove after keep matching

Missing `manifest_trim` is accepted for future compatibility and defaults to `safe`.

## LTO values

Allowed `lto` values are:

- `full`
- `thin`
- `none`
- `default`

## Current policy

- Every current profile declares `lto` explicitly.
- All current profiles use `full` LTO except `android16-6.12-lts`, which uses `thin`.
- `android16-6.12-lts` rejects full-LTO override paths because full LTO broke the Kleaf `rust_binder.ko` output.

Missing `lto` is still accepted by validation for future compatibility, but the current profile set is intentionally explicit so effective LTO policy is visible in the profile JSON itself.
