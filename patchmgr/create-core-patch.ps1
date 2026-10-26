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
    [Parameter(Mandatory = $true)]
    [string]$BaseRef,

    [Parameter(Mandatory = $true)]
    [string[]]$Paths,

    [Parameter(Mandatory = $true)]
    [string]$OutDir,

    [string]$PatchId = '0001-core-patch',

    [string]$Bundle = 'core',

    [string]$OfbizVersion = '',

    [string]$WorkRef = '',

    [string]$Description = '',

    [string]$PatchFile = '',

    [switch]$NoValidate
)

$ErrorActionPreference = 'Stop'

$Paths = @($Paths | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Get-Hash {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Export-GitBlob {
    param([string]$Ref, [string]$RelativePath, [string]$Destination)
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $process = Start-Process -FilePath git `
        -ArgumentList @('-C', $root, 'show', "${Ref}:$RelativePath") `
        -NoNewWindow -RedirectStandardOutput $Destination -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "git show failed: ${Ref}:$RelativePath"
    }
}

function Export-GitDiff {
    param([string]$Destination)
    $diffArgs = @('-c', 'core.autocrlf=false', '-C', $root, 'diff')
    if ($WorkRef) {
        $diffArgs += "$BaseRef..$WorkRef"
    } else {
        $diffArgs += $BaseRef
    }
    $diffArgs += '--'
    $diffArgs += $Paths

    $process = Start-Process -FilePath git `
        -ArgumentList $diffArgs `
        -NoNewWindow -RedirectStandardOutput $Destination -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw 'git diff failed'
    }
    if ((Get-Item -LiteralPath $Destination).Length -eq 0) {
        throw "No diff between $BaseRef and the selected paths"
    }
}

function Get-AfterHash {
    param([string]$RelativePath)
    if ($WorkRef) {
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('after-' + [guid]::NewGuid().ToString('N'))
        try {
            Export-GitBlob -Ref $WorkRef -RelativePath $RelativePath -Destination $temp
            return Get-Hash $temp
        } finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
        }
    }
    $target = Join-Path $root ($RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $target)) {
        throw "Working tree file not found: $RelativePath"
    }
    return Get-Hash $target
}

function Test-GeneratedPatch {
    param([string]$ManifestPath)
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('create-core-patch-test-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        Write-Utf8NoBom (Join-Path $tempRoot 'VERSION') ($OfbizVersion + "`n")
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $patch = @($manifest.patches)[0]
        foreach ($file in @($patch.files)) {
            $relative = [string]$file.path
            $target = Join-Path $tempRoot ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
            Export-GitBlob -Ref $BaseRef -RelativePath $relative -Destination $target
        }
        $patcher = Join-Path $PSScriptRoot 'patch-manager.ps1'
        $registry = Join-Path $tempRoot 'runtime/patch-registry.json'
        $backup = Join-Path $tempRoot 'runtime/patch-backup'
        & $patcher -Action Verify -Root $tempRoot -Manifest $ManifestPath -Registry $registry -BackupRoot $backup
        & $patcher -Action Apply -Root $tempRoot -Manifest $ManifestPath -Registry $registry -BackupRoot $backup
        foreach ($file in @($patch.files)) {
            $relative = [string]$file.path
            $target = Join-Path $tempRoot ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
            if ((Get-Hash $target) -ne ([string]$file.sha256After).ToLowerInvariant()) {
                throw "post-apply hash mismatch: $relative"
            }
        }
        & $patcher -Action Rollback -Root $tempRoot -Manifest $ManifestPath -Registry $registry -BackupRoot $backup
        foreach ($file in @($patch.files)) {
            $relative = [string]$file.path
            $target = Join-Path $tempRoot ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
            if ((Get-Hash $target) -ne ([string]$file.sha256Before).ToLowerInvariant()) {
                throw "rollback hash mismatch: $relative"
            }
        }
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not $OfbizVersion) {
    $OfbizVersion = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
}
if (-not $PatchFile) {
    $PatchFile = "$PatchId.patch"
}
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

$patchPath = Join-Path $OutDir $PatchFile
$manifestPath = Join-Path $OutDir 'manifest.json'

Write-Host "==> Generating $PatchId from $BaseRef"
Export-GitDiff -Destination $patchPath

$files = @()
foreach ($relative in $Paths) {
    $beforeTemp = Join-Path ([IO.Path]::GetTempPath()) ('before-' + [guid]::NewGuid().ToString('N'))
    try {
        Export-GitBlob -Ref $BaseRef -RelativePath $relative -Destination $beforeTemp
        $before = Get-Hash $beforeTemp
    } finally {
        if (Test-Path -LiteralPath $beforeTemp) { Remove-Item -LiteralPath $beforeTemp -Force }
    }
    $files += [pscustomobject]@{
        path         = $relative
        sha256Before = $before
        sha256After  = (Get-AfterHash -RelativePath $relative)
    }
}

$manifest = [pscustomobject]@{
    bundle      = $Bundle
    version     = '0.1.0'
    ofbiz       = $OfbizVersion
    description = $Description
    patches     = @(
        [pscustomobject]@{
            id          = $PatchId
            order       = 10
            mode        = 'diff'
            description = $Description
            patch       = $PatchFile
            reversible  = $true
            files       = $files
        }
    )
}

Write-Utf8NoBom $manifestPath (($manifest | ConvertTo-Json -Depth 12) + "`n")
Write-Host "==> Wrote $patchPath"
Write-Host "==> Wrote $manifestPath"

if (-not $NoValidate) {
    Write-Host '==> Validating on a clean snapshot'
    Test-GeneratedPatch -ManifestPath $manifestPath
    Write-Host '==> Clean apply / rollback succeeded'
}

Write-Host ($manifest | ConvertTo-Json -Depth 12)
