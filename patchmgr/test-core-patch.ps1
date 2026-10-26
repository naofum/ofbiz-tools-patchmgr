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
    [string]$Manifest,

    [string]$BaseRef = 'HEAD',

    [string]$Root = '',

    [string]$Patcher = '',

    [string]$BaselineDir = ''
)

$ErrorActionPreference = 'Stop'

if (-not $Root) {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
if (-not $Patcher) {
    $Patcher = Join-Path $PSScriptRoot 'patch-manager.ps1'
}
$Manifest = (Resolve-Path -LiteralPath $Manifest).Path
if (-not $BaselineDir) {
    $BaselineDir = Join-Path (Split-Path -Parent $Manifest) 'baseline'
}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('core-patch-test-' + [guid]::NewGuid().ToString('N'))
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
    param([string]$RelativePath, [string]$Destination)
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $errFile = Join-Path ([IO.Path]::GetTempPath()) ('git-show-err-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $process = Start-Process -FilePath git `
            -ArgumentList @('-C', $Root, 'show', "${BaseRef}:$RelativePath") `
            -NoNewWindow -RedirectStandardOutput $Destination -RedirectStandardError $errFile -Wait -PassThru
    } finally {
        if (Test-Path -LiteralPath $errFile) { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
    }
    if ($process.ExitCode -ne 0) {
        $baseline = Join-Path $BaselineDir ($RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $baseline -PathType Leaf) {
            Copy-Item -LiteralPath $baseline -Destination $Destination -Force
            return
        }
        throw "git show failed and no baseline found: ${BaseRef}:$RelativePath"
    }
}

try {
    Write-Host "==> Fixture: $tempRoot"
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $manifestData = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Utf8NoBom (Join-Path $tempRoot 'VERSION') ([string]$manifestData.ofbiz + "`n")

    foreach ($patch in @($manifestData.patches)) {
        foreach ($file in @($patch.files)) {
            $relative = [string]$file.path
            $before = [string]$file.sha256Before
            if ([string]::IsNullOrEmpty($before)) {
                # New file: it must not exist before apply.
                continue
            }
            $target = Join-Path $tempRoot ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
            Export-GitBlob $relative $target
            if ((Get-Hash $target) -ne $before.ToLowerInvariant()) {
                throw "sha256Before mismatch: $relative"
            }
        }
    }

    $registry = Join-Path $tempRoot 'runtime/patch-registry.json'
    $backup = Join-Path $tempRoot 'runtime/patch-backup'

    Write-Host '==> Verify'
    & $Patcher -Action Verify -Root $tempRoot -Manifest $Manifest -Registry $registry -BackupRoot $backup

    Write-Host '==> Apply'
    & $Patcher -Action Apply -Root $tempRoot -Manifest $Manifest -Registry $registry -BackupRoot $backup
    foreach ($patch in @($manifestData.patches)) {
        foreach ($file in @($patch.files)) {
            $relative = [string]$file.path
            $target = Join-Path $tempRoot ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
            $after = [string]$file.sha256After
            if ([string]::IsNullOrEmpty($after)) {
                if (Test-Path -LiteralPath $target -PathType Leaf) {
                    throw "expected absent after apply: $relative"
                }
            } elseif ((Get-Hash $target) -ne $after.ToLowerInvariant()) {
                throw "sha256After mismatch: $relative"
            }
        }
    }

    Write-Host '==> Rollback'
    & $Patcher -Action Rollback -Root $tempRoot -Manifest $Manifest -Registry $registry -BackupRoot $backup
    foreach ($patch in @($manifestData.patches)) {
        foreach ($file in @($patch.files)) {
            $relative = [string]$file.path
            $target = Join-Path $tempRoot ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
            $before = [string]$file.sha256Before
            if ([string]::IsNullOrEmpty($before)) {
                if (Test-Path -LiteralPath $target -PathType Leaf) {
                    throw "expected absent after rollback: $relative"
                }
            } elseif ((Get-Hash $target) -ne $before.ToLowerInvariant()) {
                throw "rollback hash mismatch: $relative"
            }
        }
    }

    Write-Host "CORE PATCH TEST PASSED: $($manifestData.bundle)"
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
