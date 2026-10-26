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
param()

$ErrorActionPreference = 'Stop'

$patchScript = Join-Path $PSScriptRoot 'patch-manager.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('casemgmt-patch-test-' + [guid]::NewGuid().ToString('N'))
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Get-Hash {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

try {
    Write-Host "==> Fixture: $tempRoot"
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Write-Utf8NoBom (Join-Path $tempRoot 'VERSION') "24.09.07`n"
    Write-Utf8NoBom (Join-Path $tempRoot 'sample.txt') "alpha`nbeta`n"

    & git -C $tempRoot init -q
    if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
    & git -C $tempRoot config user.email 'patch-test@example.com'
    & git -C $tempRoot config user.name 'Patch Test'
    & git -C $tempRoot config core.autocrlf false
    & git -C $tempRoot add VERSION sample.txt
    & git -C $tempRoot commit -q -m 'fixture'
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }

    $before = Get-Hash (Join-Path $tempRoot 'sample.txt')
    Write-Utf8NoBom (Join-Path $tempRoot 'sample.txt') "alpha`nbeta`ngamma`n"
    $after = Get-Hash (Join-Path $tempRoot 'sample.txt')

    $patchFile = Join-Path $tempRoot '0001-sample.patch'
    $diff = & git -C $tempRoot -c core.autocrlf=false diff -- sample.txt
    if ($LASTEXITCODE -ne 0) { throw 'git diff failed' }
    Write-Utf8NoBom $patchFile (($diff -join "`n") + "`n")
    & git -C $tempRoot checkout -- sample.txt
    if ($LASTEXITCODE -ne 0) { throw 'git checkout failed' }

    $manifestPath = Join-Path $tempRoot 'manifest.json'
    $manifest = @{
        bundle  = 'patch-test'
        version = '0.1.0'
        ofbiz   = '24.09.07'
        patches = @(
            @{
                id          = '0001-sample'
                order       = 10
                mode        = 'diff'
                description = 'Add gamma to sample.txt'
                patch       = '0001-sample.patch'
                reversible  = $true
                files       = @(
                    @{
                        path         = 'sample.txt'
                        sha256Before = $before
                        sha256After  = $after
                    }
                )
            }
        )
    }
    Write-Utf8NoBom $manifestPath ($manifest | ConvertTo-Json -Depth 12)

    $registryPath = Join-Path $tempRoot 'runtime/patch-registry.json'
    $backupPath = Join-Path $tempRoot 'runtime/patch-backup'

    Write-Host '==> Verify'
    & $patchScript -Action Verify -Root $tempRoot -Manifest $manifestPath -Registry $registryPath -BackupRoot $backupPath

    Write-Host '==> Apply'
    & $patchScript -Action Apply -Root $tempRoot -Manifest $manifestPath -Registry $registryPath -BackupRoot $backupPath
    $applied = Get-Content -LiteralPath (Join-Path $tempRoot 'sample.txt') -Raw
    if ($applied -notmatch 'gamma') { throw 'apply did not modify sample.txt' }

    Write-Host '==> List'
    $listOutput = & $patchScript -Action List -Root $tempRoot -Manifest $manifestPath -Registry $registryPath -BackupRoot $backupPath
    $listOutput | Out-Host
    if (($listOutput | Out-String) -notmatch 'applied') { throw 'list did not report applied state' }

    Write-Host '==> Rollback'
    & $patchScript -Action Rollback -Root $tempRoot -Manifest $manifestPath -Registry $registryPath -BackupRoot $backupPath
    $rolledBack = Get-Content -LiteralPath (Join-Path $tempRoot 'sample.txt') -Raw
    if ($rolledBack -match 'gamma') { throw 'rollback did not restore sample.txt' }

    Write-Host 'PATCH MANAGER TEST PASSED'
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
