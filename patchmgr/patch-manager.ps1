# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

[CmdletBinding()]
param(
    [ValidateSet('List', 'Verify', 'Apply', 'Rollback')]
    [string]$Action = 'List',

    [string]$Root = '',

    [string]$Manifest = '',

    [string]$Registry = '',

    [string]$BackupRoot = '',

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not $Root) {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
if (-not $Manifest) {
    throw 'Manifest is required. Use -Manifest <path>.'
}
$Manifest = (Resolve-Path -LiteralPath $Manifest).Path
if (-not $Registry) {
    $Registry = Join-Path $PSScriptRoot '..\..\runtime\patch-registry.json'
}
if (-not $BackupRoot) {
    $BackupRoot = Join-Path $PSScriptRoot '..\..\runtime\patch-backup'
}

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message"
}

function Get-Sha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RepoPath {
    param([string]$RelativePath)
    $normalized = $RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath((Join-Path $Root $normalized))
    $rootFull = [IO.Path]::GetFullPath($Root)
    $prefix = $rootFull.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($full -ne $rootFull -and -not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes OFBiz root: $RelativePath"
    }
    return $full
}

function Read-Manifest {
    if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
        throw "Manifest not found: $Manifest"
    }
    return (Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Read-Registry {
    $reg = @{ patches = @{} }
    if (Test-Path -LiteralPath $Registry -PathType Leaf) {
        $json = Get-Content -LiteralPath $Registry -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($json.PSObject.Properties.Name -contains 'patches') {
            foreach ($entry in $json.patches.PSObject.Properties) {
                $reg.patches[$entry.Name] = $entry.Value
            }
        }
    }
    return $reg
}

function Save-Registry {
    param($Reg)
    $dir = Split-Path -Parent $Registry
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Reg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Registry -Encoding UTF8
}

function Get-OrderedPatches {
    param($ManifestData)
    return @($ManifestData.patches) | Sort-Object { [int]$_.order }
}

function Assert-Version {
    param($ManifestData)
    $versionFile = Join-Path $Root 'VERSION'
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
        throw "VERSION not found under $Root"
    }
    $actual = (Get-Content -LiteralPath $versionFile -Raw).Trim()
    $expected = [string]$ManifestData.ofbiz
    if ($expected -and $expected -ne '*' -and $actual -notlike $expected) {
        throw "OFBiz version mismatch: expected '$expected', actual '$actual'"
    }
    Write-Host "OFBiz version: $actual"
}

function Get-PatchPath {
    param($Patch)
    $name = [string]$Patch.patch
    if (-not $name) {
        return $null
    }
    if ([IO.Path]::IsPathRooted($name)) {
        return $name
    }
    return (Join-Path (Split-Path -Parent $Manifest) $name)
}

function Invoke-GitApply {
    param(
        [string]$PatchPath,
        [switch]$Reverse,
        [switch]$Check
    )
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git is required for diff patches. Install git or use mode "replace".'
    }
    $gitArgs = @('-c', 'core.autocrlf=false', '-C', $Root, 'apply')
    if ($Check) { $gitArgs += '--check' }
    if ($Reverse) { $gitArgs += '-R' }
    $gitArgs += $PatchPath
    & git @gitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git apply failed (exit $LASTEXITCODE): $PatchPath"
    }
}

function Get-BackupPath {
    param($Patch, [string]$Timestamp, [string]$RelativePath)
    $backupDir = Join-Path (Join-Path $BackupRoot ([string]$Patch.id)) $Timestamp
    $backupDirFull = [IO.Path]::GetFullPath($backupDir)
    $normalized = $RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath((Join-Path $backupDirFull $normalized))
    $prefix = $backupDirFull.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Backup path escapes backup directory: $RelativePath"
    }
    return $full
}

function Backup-Files {
    param($Patch, [string]$Timestamp)
    foreach ($file in @($Patch.files)) {
        $source = Get-RepoPath ([string]$file.path)
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            # New files have no original to back up.
            continue
        }
        $destination = Get-BackupPath $Patch $Timestamp ([string]$file.path)
        $dir = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
    $backupDir = Join-Path (Join-Path $BackupRoot ([string]$Patch.id)) $Timestamp
    if (-not (Test-Path -LiteralPath $backupDir)) {
        return $null
    }
    return $backupDir
}

function Restore-Backup {
    param($Patch, [string]$BackupDir)
    foreach ($file in @($Patch.files)) {
        $source = Get-BackupPath $Patch (Split-Path -Leaf $BackupDir) ([string]$file.path)
        $destination = Get-RepoPath ([string]$file.path)
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            if ([string]::IsNullOrEmpty([string]$file.sha256Before)) {
                # New file: restore means delete it.
                if (Test-Path -LiteralPath $destination -PathType Leaf) {
                    Remove-Item -LiteralPath $destination -Force
                }
                continue
            }
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
                continue
            }
            throw "Backup file missing: $source"
        }
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}

function Get-PatchState {
    param($Patch)
    $isBefore = $true
    $isAfter = $true
    foreach ($file in @($Patch.files)) {
        $path = Get-RepoPath ([string]$file.path)
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        $hash = if ($exists) { Get-Sha256 $path } else { $null }
        $before = [string]$file.sha256Before
        $after = [string]$file.sha256After

        if ([string]::IsNullOrEmpty($before)) {
            # An empty before-hash means the file must not exist yet.
            if ($exists) { $isBefore = $false }
        } elseif (-not $exists -or $hash -ne $before.ToLowerInvariant()) {
            $isBefore = $false
        }

        if ([string]::IsNullOrEmpty($after)) {
            # An empty after-hash means the file must be absent after apply.
            if ($exists) { $isAfter = $false }
        } elseif (-not $exists -or $hash -ne $after.ToLowerInvariant()) {
            $isAfter = $false
        }
    }
    return [pscustomobject]@{ IsBefore = $isBefore; IsAfter = $isAfter }
}

function Show-PatchList {
    param($ManifestData, $Reg)
    $rows = foreach ($patch in Get-OrderedPatches $ManifestData) {
        $id = [string]$patch.id
        $state = 'pending'
        if ($Reg.patches.ContainsKey($id)) {
            $state = [string]$Reg.patches[$id].status
        } else {
            $patchState = Get-PatchState $patch
            if ($patchState.IsAfter) {
                $state = 'applied (unregistered)'
            } elseif (-not $patchState.IsBefore) {
                $state = 'conflict'
            }
        }
        [pscustomobject]@{
            Id          = $id
            Order       = $patch.order
            Mode        = $patch.mode
            State       = $state
            Description = $patch.description
        }
    }
    $rows | Format-Table -AutoSize
}

function Apply-Patch {
    param($Patch, $Reg)
    $id = [string]$Patch.id
    if ($Reg.patches.ContainsKey($id) -and $Reg.patches[$id].status -eq 'applied') {
        Write-Host "SKIP $id (already applied)"
        return
    }

    $state = Get-PatchState $Patch
    if ($state.IsAfter) {
        Write-Host "SKIP $id (already applied on disk; registering)"
        if (-not $DryRun) {
            $Reg.patches[$id] = [pscustomobject]@{
                status    = 'applied'
                appliedAt = (Get-Date).ToString('o')
                backup    = $null
                files     = @($Patch.files)
            }
            Save-Registry $Reg
        }
        return
    }
    if (-not $state.IsBefore) {
        throw "Conflict: target files do not match sha256Before for patch $id"
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupDir = $null
    if (-not $DryRun) {
        $backupDir = Backup-Files $Patch $timestamp
    }

    try {
        if ([string]$Patch.mode -eq 'replace') {
            foreach ($file in @($Patch.files)) {
                $source = Join-Path (Split-Path -Parent $Manifest) ([string]$file.source)
                $target = Get-RepoPath ([string]$file.path)
                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                    throw "Replacement source not found: $source"
                }
                if (-not $DryRun) {
                    Copy-Item -LiteralPath $source -Destination $target -Force
                }
            }
        } else {
            $patchPath = Get-PatchPath $Patch
            if (-not $patchPath -or -not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
                throw "Patch file not found: $patchPath"
            }
            Invoke-GitApply $patchPath -Check
            if (-not $DryRun) {
                Invoke-GitApply $patchPath
            }
        }

        if (-not $DryRun) {
            $after = Get-PatchState $Patch
            if (-not $after.IsAfter) {
                throw "Post-apply hash verification failed for $id"
            }
            $Reg.patches[$id] = [pscustomobject]@{
                status    = 'applied'
                appliedAt = (Get-Date).ToString('o')
                backup    = $backupDir
                files     = @($Patch.files)
            }
            Save-Registry $Reg
        }
        Write-Host "APPLIED $id"
    } catch {
        if (-not $DryRun -and $backupDir) {
            Write-Warning "Rolling back $id after failure"
            Restore-Backup $Patch $backupDir
        }
        throw
    }
}

function Rollback-Patch {
    param($Patch, $Reg)
    $id = [string]$Patch.id
    if (-not $Reg.patches.ContainsKey($id)) {
        Write-Host "SKIP $id (not registered)"
        return
    }

    $entry = $Reg.patches[$id]
    $state = Get-PatchState $Patch
    if (-not $state.IsAfter) {
        throw "Cannot rollback ${id}: current files do not match sha256After"
    }

    if (-not $DryRun) {
        if ([string]$Patch.mode -eq 'diff' -and [bool]$Patch.reversible) {
            $patchPath = Get-PatchPath $Patch
            Invoke-GitApply $patchPath -Reverse -Check
            Invoke-GitApply $patchPath -Reverse
        } else {
            if (-not $entry.backup) {
                throw "No backup recorded for $id"
            }
            Restore-Backup $Patch ([string]$entry.backup)
        }

        $before = Get-PatchState $Patch
        if (-not $before.IsBefore) {
            throw "Post-rollback hash verification failed for $id"
        }
        $Reg.patches.Remove($id)
        Save-Registry $Reg
    }
    Write-Host "ROLLED BACK $id"
}

$manifestData = Read-Manifest
$registryData = Read-Registry
Assert-Version $manifestData

switch ($Action) {
    'List' {
        Show-PatchList $manifestData $registryData
    }
    'Verify' {
        foreach ($patch in Get-OrderedPatches $manifestData) {
            $state = Get-PatchState $patch
            $registered = $registryData.patches.ContainsKey([string]$patch.id)
            $status = if ($state.IsAfter) { 'applied' } elseif ($state.IsBefore) { 'pending' } else { 'conflict' }
            Write-Host ("{0}: {1} (registered={2})" -f $patch.id, $status, $registered)
            if ($state.IsBefore -and [string]$patch.mode -ne 'replace') {
                $patchPath = Get-PatchPath $patch
                Invoke-GitApply $patchPath -Check
            }
        }
    }
    'Apply' {
        foreach ($patch in Get-OrderedPatches $manifestData) {
            Apply-Patch $patch $registryData
        }
    }
    'Rollback' {
        $patches = @(Get-OrderedPatches $manifestData)
        [array]::Reverse($patches)
        foreach ($patch in $patches) {
            Rollback-Patch $patch $registryData
        }
    }
}
