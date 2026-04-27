[CmdletBinding()]
param(
    [string] $Root,

    [string] $BackupPath,

    [string] $PackageName = "OpenAI.Codex",

    [string] $WindowsAppsRoot,

    [switch] $List,

    [switch] $StopRunningRebuild,

    [switch] $NoShortcut,

    [switch] $NoSmokeTest,

    [switch] $DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-RootPath {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    }

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolved.Path -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw "Root is not a directory: $Path"
    }

    return $item.FullName.TrimEnd("\")
}

function Test-PathUnderRoot {
    param(
        [Parameter(Mandatory = $true)][string] $RootPath,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
    $rootFullPath = [System.IO.Path]::GetFullPath($RootPath).TrimEnd("\")
    $expectedPrefix = $rootFullPath + "\"
    return $fullPath.Equals($rootFullPath, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Remove-EmptyDirectoryIfPresent {
    param([Parameter(Mandatory = $true)][string] $Path)

    if ((Test-Path -LiteralPath $Path -PathType Container) -and
        -not @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Count) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function New-UniqueTimestampPath {
    param(
        [Parameter(Mandatory = $true)][string] $Parent,
        [Parameter(Mandatory = $true)][string] $Prefix
    )

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $candidate = Join-Path $Parent "$Prefix-$stamp"
    $suffix = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $Parent "$Prefix-$stamp-$suffix"
        $suffix++
    }
    return $candidate
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Find-CoreSourceFile {
    param(
        [Parameter(Mandatory = $true)][string] $Directory,
        [Parameter(Mandatory = $true)][string[]] $Candidates
    )

    foreach ($name in $Candidates) {
        $path = Join-Path $Directory $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return (Get-Item -LiteralPath $path -ErrorAction Stop).FullName
        }
    }

    return $null
}

function Get-CoreFileMappings {
    return @(
        [pscustomobject]@{
            Target = "codex-x86_64-pc-windows-msvc.exe"
            Role = "codex cli"
            MinLength = 1000000
            Sources = @("codex-x86_64-pc-windows-msvc.exe", "codex.exe")
        },
        [pscustomobject]@{
            Target = "codex-command-runner.exe"
            Role = "command runner"
            MinLength = 100000
            Sources = @("codex-command-runner.exe", "codex-command-runner-x86_64-pc-windows-msvc.exe")
        },
        [pscustomobject]@{
            Target = "codex-windows-sandbox-setup.exe"
            Role = "windows sandbox setup"
            MinLength = 100000
            Sources = @("codex-windows-sandbox-setup.exe", "codex-windows-sandbox-setup-x86_64-pc-windows-msvc.exe")
        }
    )
}

function Test-CoreDirectory {
    param([Parameter(Mandatory = $true)][string] $Directory)

    foreach ($mapping in Get-CoreFileMappings) {
        $path = Find-CoreSourceFile -Directory $Directory -Candidates $mapping.Sources
        if (-not $path) {
            return $false
        }
    }

    return $true
}

function Get-CoreFiles {
    param([Parameter(Mandatory = $true)][string] $Directory)

    foreach ($mapping in Get-CoreFileMappings) {
        $sourcePath = Find-CoreSourceFile -Directory $Directory -Candidates $mapping.Sources
        if (-not $sourcePath) {
            throw "Missing $($mapping.Role). Looked for: $($mapping.Sources -join ', ') in $Directory"
        }

        $item = Get-Item -LiteralPath $sourcePath -ErrorAction Stop
        if ($item.Length -lt $mapping.MinLength) {
            throw "$($mapping.Role) is too small to be a valid binary: $sourcePath ($($item.Length) bytes)"
        }

        [pscustomobject]@{
            Role = $mapping.Role
            Target = $mapping.Target
            SourcePath = $item.FullName
            Length = $item.Length
            ProductVersion = $item.VersionInfo.ProductVersion
            Sha256 = Get-Sha256 -Path $item.FullName
        }
    }
}

function Get-CoreBackups {
    param([Parameter(Mandatory = $true)][string] $ArchiveRoot)

    if (-not (Test-Path -LiteralPath $ArchiveRoot -PathType Container)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $ArchiveRoot -Directory -ErrorAction Stop |
        Where-Object { Test-CoreDirectory -Directory $_.FullName } |
        Sort-Object LastWriteTime -Descending)
}

function Resolve-CoreBackup {
    param(
        [Parameter(Mandatory = $true)][string] $RootPath,
        [Parameter(Mandatory = $true)][string] $ArchiveRoot,
        [string] $Path
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            throw "BackupPath is not a directory: $Path"
        }
        if (-not (Test-PathUnderRoot -RootPath $ArchiveRoot -Path $item.FullName)) {
            throw "Refusing to restore a Core backup outside core-archive. BackupPath=$($item.FullName)"
        }
        if (-not (Test-CoreDirectory -Directory $item.FullName)) {
            throw "BackupPath does not contain the required Codex core files: $($item.FullName)"
        }
        return $item
    }

    $backups = @(Get-CoreBackups -ArchiveRoot $ArchiveRoot)
    if ($backups.Count -eq 0) {
        throw "No valid Core backups found in $ArchiveRoot. A backup is created automatically when UpdateCore replaces an existing .\Core."
    }

    return $backups[0]
}

function Copy-CoreDirectory {
    param(
        [Parameter(Mandatory = $true)][string] $SourceDir,
        [Parameter(Mandatory = $true)][string] $DestinationDir
    )

    New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    foreach ($file in Get-ChildItem -LiteralPath $SourceDir -Force -ErrorAction Stop) {
        Copy-Item -LiteralPath $file.FullName -Destination $DestinationDir -Recurse -Force -ErrorAction Stop
    }
}

$rootPath = Resolve-RootPath -Path $Root
if ([string]::IsNullOrWhiteSpace($WindowsAppsRoot) -and -not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
    $WindowsAppsRoot = Join-Path $env:ProgramFiles "WindowsApps"
}

$archiveRoot = Join-Path $rootPath "core-archive"
$coreDir = Join-Path $rootPath "Core"
$installStageRoot = Join-Path $rootPath ".core-install-staging"

$backups = @(Get-CoreBackups -ArchiveRoot $archiveRoot)
if ($List) {
    if ($backups.Count -eq 0) {
        Write-Host "No valid Core backups found in: $archiveRoot"
    } else {
        $backups | Select-Object LastWriteTime, FullName | Format-Table -AutoSize | Out-String | Write-Host
    }
    exit 0
}

$backup = Resolve-CoreBackup -RootPath $rootPath -ArchiveRoot $archiveRoot -Path $BackupPath
$backupFiles = @(Get-CoreFiles -Directory $backup.FullName)

Write-Host "Root:        $rootPath"
Write-Host "Backup:      $($backup.FullName)"
Write-Host "Destination: $coreDir"
Write-Host "Mode:        $(if ($DryRun) { 'DRY-RUN RESTORE CORE' } else { 'RESTORE CORE' })"
Write-Host ""
$backupFiles | Select-Object Role, Length, ProductVersion, Sha256, SourcePath | Format-Table -AutoSize | Out-String | Write-Host

$rebuildScript = Join-Path $rootPath "CodexRebuild-Rebuild.ps1"
if (-not (Test-Path -LiteralPath $rebuildScript -PathType Leaf)) {
    throw "Missing rebuild script: $rebuildScript"
}

if ($DryRun) {
    $rebuildArgs = @("-Root", $rootPath, "-CoreDir", $backup.FullName, "-PackageName", $PackageName, "-DryRun")
    if (-not [string]::IsNullOrWhiteSpace($WindowsAppsRoot)) {
        $rebuildArgs += @("-WindowsAppsRoot", $WindowsAppsRoot)
    }
    if ($NoShortcut) {
        $rebuildArgs += "-NoShortcut"
    }

    & powershell -NoProfile -ExecutionPolicy Bypass -File $rebuildScript @rebuildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Rebuild dry-run failed with exit code $LASTEXITCODE"
    }
    exit 0
}

New-Item -ItemType Directory -Path $archiveRoot, $installStageRoot -Force | Out-Null

$currentCoreBackup = $null
if (Test-Path -LiteralPath $coreDir -PathType Container) {
    $currentCoreBackup = New-UniqueTimestampPath -Parent $archiveRoot -Prefix "Core-before-restore"
    Move-Item -LiteralPath $coreDir -Destination $currentCoreBackup -Force
    Write-Host "Backed up current Core before restore: $currentCoreBackup"
}

$restoreStage = New-UniqueTimestampPath -Parent $installStageRoot -Prefix "Core-restore"
if (Test-Path -LiteralPath $restoreStage) {
    throw "Core restore staging directory already exists: $restoreStage"
}

Copy-CoreDirectory -SourceDir $backup.FullName -DestinationDir $restoreStage

$manifest = [ordered]@{
    restoredAt = (Get-Date).ToString("o")
    restoredFrom = $backup.FullName
    currentCoreBackup = $currentCoreBackup
    files = @($backupFiles | ForEach-Object {
        [ordered]@{
            Role = $_.Role
            Target = $_.Target
            SourcePath = $_.SourcePath
            ProductVersion = $_.ProductVersion
            Length = $_.Length
            Sha256 = $_.Sha256
        }
    })
}
$manifest | ConvertTo-Json -Depth 6 | Out-File -LiteralPath (Join-Path $restoreStage "codex-core-restore-manifest.json") -Encoding UTF8

Move-Item -LiteralPath $restoreStage -Destination $coreDir -Force

$rebuildArgs = @("-Root", $rootPath, "-CoreDir", $coreDir, "-PackageName", $PackageName)
if (-not [string]::IsNullOrWhiteSpace($WindowsAppsRoot)) {
    $rebuildArgs += @("-WindowsAppsRoot", $WindowsAppsRoot)
}
if ($StopRunningRebuild) {
    $rebuildArgs += "-StopRunningRebuild"
}
if ($NoShortcut) {
    $rebuildArgs += "-NoShortcut"
}

& powershell -NoProfile -ExecutionPolicy Bypass -File $rebuildScript @rebuildArgs
if ($LASTEXITCODE -ne 0) {
    throw "Rebuild script failed with exit code $LASTEXITCODE"
}

if (-not $NoSmokeTest) {
    $testScript = Join-Path $rootPath "CodexRebuild-Test.ps1"
    if (-not (Test-Path -LiteralPath $testScript -PathType Leaf)) {
        throw "Missing smoke test script: $testScript"
    }

    & powershell -NoProfile -ExecutionPolicy Bypass -File $testScript -Root $rootPath -StopExisting
    if ($LASTEXITCODE -ne 0) {
        throw "Smoke test script failed with exit code $LASTEXITCODE"
    }
}

Remove-EmptyDirectoryIfPresent -Path $installStageRoot

Write-Host "Core restored from backup: $($backup.FullName)"
