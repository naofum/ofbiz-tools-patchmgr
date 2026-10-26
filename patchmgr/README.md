# patchmgr

Shared core-patch manager for OFBiz plugins.

- Usage and policy: `docs/README.md`
- Core diff inventory: `docs/core-diff-inventory.md`
- Implementation status: `docs/implementation-status.md`
- Gradle integration: `../../gradle/patchmgr.gradle`

This tool is not an OFBiz component and has no dependency on any plugin.
Each plugin owns its `patches/<ofbiz-version>/manifest.json`.

## Requirements

- **Windows**: Windows PowerShell (`powershell.exe`)
- **Linux/macOS CI**: PowerShell 7+ (`pwsh`) must be installed in the CI image.
  `gradle/patchmgr.gradle` selects `powershell.exe` on Windows and `pwsh` on
  other platforms.
- **Git**: required for applying `diff` patches (`git apply`).

