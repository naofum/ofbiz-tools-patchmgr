# OFBiz core patch manager

This directory contains the shared, manifest-driven core patch workflow. It is
a build/deploy tool, not an OFBiz component. It has no dependency on the
`casemgmt`, `finance`, or `translate-jp` plugins.

## Policy

- Core changes are the last resort. Prefer Entity ECA, plugin screens, and
  View Entities first.
- Core patches are declarative inputs, not startup hooks. They are applied by
  `installPlugin` / the build pipeline, never automatically at runtime.
- Production deployments should use an immutable artifact (Docker image or
  distribution) with the patches already applied.
- Each plugin owns its manifest and patch files. The tool only reads them.

## Requirements

- **Windows**: Windows PowerShell (`powershell.exe`)
- **Linux/macOS CI**: PowerShell 7+ (`pwsh`) must be installed in the CI image.
  `gradle/patchmgr.gradle` selects `powershell.exe` on Windows and `pwsh` on
  other platforms.
- **Git**: required for applying `diff` patches (`git apply`).

## Layout

```
tools/patchmgr/
├── patch-manager.ps1
├── create-core-patch.ps1
├── test-core-patch.ps1
├── test-patch-manager.ps1
└── docs/

gradle/
└── patchmgr.gradle

plugins/<plugin>/
├── patches/<ofbiz-version>/
│   ├── manifest.json
│   └── 0001-....patch
└── build.gradle
```

Each plugin's `build.gradle` applies the shared integration:

```groovy
ext.patchManifest = file("${projectDir}/patches/24.09.07/manifest.json")
apply from: "${rootDir}/gradle/patchmgr.gradle"
```

This registers `listCorePatches`, `verifyCorePatches`, `applyCorePatches`,
`rollbackCorePatches`, `testCorePatch`, `testPatchManager`, and the
`install` / `uninstall` hooks for that plugin.

## Commands

```powershell
# List declared patches and their state
.\gradlew.bat :plugins:translate-jp:listCorePatches

# Verify the target OFBiz version and patch preconditions
.\gradlew.bat :plugins:translate-jp:verifyCorePatches

# Apply patches and record them in runtime/patch-registry.json
.\gradlew.bat :plugins:translate-jp:applyCorePatches

# Roll back applied patches
.\gradlew.bat :plugins:translate-jp:rollbackCorePatches

# Clean-snapshot apply/rollback test
.\gradlew.bat :plugins:translate-jp:testCorePatch

# Install / uninstall hooks
.\gradlew.bat installPlugin -PpluginId=translate-jp
.\gradlew.bat uninstallPlugin -PpluginId=translate-jp

# Fixture test for the patch manager itself
.\gradlew.bat :plugins:casemgmt:testPatchManager
```

## Creating a patch for a new OFBiz version

1. Check out the new OFBiz tag and create a temporary worktree or branch with
   the core changes applied:

   ```powershell
   git fetch --tags
   git switch -c core/jp-localization-24.09.08 release24.09.08
   # apply or cherry-pick the existing core changes
   ```

2. Generate the patch and manifest from the clean tag:

   ```powershell
   .\tools\patchmgr\create-core-patch.ps1 `
     -BaseRef release24.09.08 `
     -Paths "applications/party/template/party/EditContactMech.ftl,applications/party/template/party/contactmechtemplates/PostalAddress_JPN.ftl,applications/party/template/party/contactmechtemplates/PostalAddress_JPN.fo.ftl,applications/party/widget/partymgr/PartyForms.xml" `
     -OutDir "plugins/translate-jp/patches/24.09.08" `
     -PatchId "0001-jp-address-widget" `
     -Bundle "jp-localization" `
     -OfbizVersion "24.09.08" `
     -Description "Japanese postal address widget and JPN address order"
   ```

   `-WorkRef` can be used to take the patched content from a branch instead of
   the working tree. The generator computes `sha256Before` from `BaseRef` and
   `sha256After` from the branch or working tree, writes the patch and manifest,
   and validates apply/rollback on a clean snapshot.

3. Run the plugin's test task and the OFBiz compile/tests:

   ```powershell
   .\gradlew.bat :plugins:translate-jp:testCorePatch
   .\gradlew.bat compileJava compileGroovy
   ```

4. Keep one patch directory per supported OFBiz version. Do not reuse a
   `24.09.07` manifest for `24.09.08` without regenerating the hashes and
   verifying the patch.

## Manifest

Each patch entry declares:

- `id`: stable patch identifier
- `order`: application order
- `mode`: `diff` or `replace`
- `patch`: patch file name (for `diff`)
- `reversible`: whether reverse application is supported
- `files`: target paths and `sha256Before` / `sha256After`

`diff` patches are applied with `git apply --check` followed by `git apply`.
`replace` patches copy a payload file and are intended for generated or binary
files. A `replace` entry must provide `source` on each file.

## Safety

- The manager fails closed when the OFBiz version or a file hash does not match.
- Files are backed up under `runtime/patch-backup/<patch-id>/<timestamp>/`.
- Applied patches are recorded in `runtime/patch-registry.json`.
- `rollback` reverses a diff patch or restores the backup, then verifies the
  original hashes.
- Do not edit patched core files by hand. Regenerate the patch from a Git branch
  or from a clean baseline, and update the hashes in the manifest.
- The current implementation uses PowerShell. Windows uses `powershell.exe`;
  Linux CI must install PowerShell 7+ (`pwsh`). A native Groovy runner is a
  future improvement.
