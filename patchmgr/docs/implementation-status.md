# Patch manager implementation status

## Done

- [x] Minimal `casemgmt` plugin component (`ofbiz-component.xml`, `config/`)
- [x] `manifest.json` schema with bundle/version/OFBiz version/patch order/hashes
- [x] Shared tool under `tools/patchmgr/` (no plugin dependency)
- [x] `tools/patchmgr/patch-manager.ps1`
  - `List` / `Verify` / `Apply` / `Rollback`
  - OFBiz `VERSION` check
  - `sha256Before` / `sha256After` verification
  - per-patch backup under `runtime/patch-backup/<patch-id>/<timestamp>/`
  - applied registry at `runtime/patch-registry.json`
  - fail-closed on conflict, idempotent on re-apply
- [x] Shared Gradle integration `gradle/patchmgr.gradle`
  - `listCorePatches`
  - `verifyCorePatches`
  - `applyCorePatches`
  - `rollbackCorePatches`
  - `testCorePatch`
  - `testPatchManager`
  - `install` / `uninstall` hooks for `installPlugin` / `uninstallPlugin`
- [x] Fixture test (`tools/patchmgr/test-patch-manager.ps1`) covering verify/apply/list/rollback
- [x] Core diff inventory (`tools/patchmgr/docs/core-diff-inventory.md`)

## Done (continued)

- [x] First real core patch bundle: `jp-localization` in
  `plugins/translate-jp/patches/24.09.07/`
  - `0001-jp-address-widget.patch`
  - clean apply / rollback test against a HEAD snapshot
  - `translate-jp` Gradle tasks come from the shared `gradle/patchmgr.gradle`
  - `testCorePatch` validates clean apply / rollback
- [x] Reusable patch generator: `tools/patchmgr/create-core-patch.ps1`
  - takes a base ref, paths, output directory, patch ID, bundle and OFBiz version
  - computes before/after SHA-256
  - writes the patch and manifest
  - validates apply/rollback on a clean snapshot
- [x] `finance` core patch bundle in `plugins/finance/patches/24.09.07/`
  - `0001-payment-application-removal.patch`
  - clean apply / rollback test via `testFinanceCorePatch`
  - `ofbiz --test component=finance`: tests=217, errors=0, failures=0
- [x] `efinance` rest-api patch bundle in `plugins/efinance/patches/24.09.07/`
  - `EfAuthFilter.java` (new file)
  - `APIAuthFilter.java` (public `auth="false"` operations)
  - `ServiceRequestHandler.java` (remote address for `ipAddress`)
  - clean apply / rollback test via `testCorePatch`
  - upstream `rest-api` baselines under `baseline/` for testing untracked files
  - `ofbiz --test component=efinance`: tests=94, errors=0, failures=0

## Pending

- [x] Gradle selects `powershell.exe` on Windows and `pwsh` elsewhere
- [x] `translate-jp` / `finance` patch tasks work with the `casemgmt`
  component disabled (no plugin-to-plugin dependency)
- [ ] Linux CI validation of the `pwsh` path
- [x] `translate-jp` label-resource override spike
  - Result: not viable. A plugin `config/CommonUiLabels.xml` with the same
    name as a core resource makes `:processResources` fail with
    `Entry CommonUiLabels.xml is a duplicate but no duplicate handling strategy has been set.`
  - Conclusion: use key-level merge into a full label file, then apply it as a
    `diff` or `replace` patch.
- [ ] Key-level label merge tool
- [ ] CI job that applies patches to a clean OFBiz tag and builds a Docker image
- [ ] `patchmgr` aggregate tool for multiple plugin manifests
