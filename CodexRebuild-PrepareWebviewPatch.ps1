[CmdletBinding()]
param(
    [string] $Root,

    [string] $AppRoot,

    [switch] $StopRunningRebuild,

    [switch] $DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$electronFusesPackage = "@electron/fuses@2.1.1"
$electronAsarPackage = "@electron/asar@4.2.0"

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

function Get-RebuildProcesses {
    param([Parameter(Mandatory = $true)][string] $AppRoot)

    Get-CimInstance Win32_Process |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -like "$AppRoot\*" } |
        Select-Object ProcessId, Name, ExecutablePath
}

function Stop-RebuildProcesses {
    param([Parameter(Mandatory = $true)][object[]] $Processes)

    foreach ($process in $Processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    & $FilePath @Arguments
    $exit = $LASTEXITCODE
    if ($exit -ne 0) {
        throw "$FilePath failed with exit code $exit"
    }
}

function Get-NpxPath {
    $npxCommand = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if (-not $npxCommand) {
        $npxCommand = Get-Command npx -ErrorAction SilentlyContinue
    }
    if (-not $npxCommand) {
        throw "npx was not found. Install Node.js/npm or make npx available on PATH, then rerun this script."
    }
    return $npxCommand.Source
}

function Read-Fuses {
    param(
        [Parameter(Mandatory = $true)][string] $NpxPath,
        [Parameter(Mandatory = $true)][string] $ExePath,
        [Parameter(Mandatory = $true)][string] $PackageSpec
    )

    $output = & $NpxPath --yes $PackageSpec read --app $ExePath 2>&1
    $exit = $LASTEXITCODE
    $text = ($output | Out-String)
    if ($exit -ne 0) {
        throw "Failed to read Electron fuses. Exit=$exit Output=$text"
    }

    return $text
}

function Assert-FusesDisabled {
    param([Parameter(Mandatory = $true)][string] $FuseText)

    if ($FuseText -notmatch "EnableEmbeddedAsarIntegrityValidation is Disabled") {
        throw "EnableEmbeddedAsarIntegrityValidation is not disabled."
    }

    if ($FuseText -notmatch "OnlyLoadAppFromAsar is Disabled") {
        throw "OnlyLoadAppFromAsar is not disabled."
    }
}

function New-PrepareBackup {
    param(
        [Parameter(Mandatory = $true)][string] $BackupDir,
        [Parameter(Mandatory = $true)][string] $ExePath,
        [string] $AsarPath
    )

    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

    $exeBackupPath = Join-Path $BackupDir "Codex.exe.bak"
    if (-not (Test-Path -LiteralPath $exeBackupPath -PathType Leaf)) {
        Copy-Item -LiteralPath $ExePath -Destination $exeBackupPath -Force
    }

    if (-not [string]::IsNullOrWhiteSpace($AsarPath) -and (Test-Path -LiteralPath $AsarPath -PathType Leaf)) {
        Copy-Item -LiteralPath $AsarPath -Destination (Join-Path $BackupDir "app.asar.bak") -Force
    }

    return $BackupDir
}

$rootPath = Resolve-RootPath -Path $Root
if ([string]::IsNullOrWhiteSpace($AppRoot)) {
    $AppRoot = Join-Path $rootPath "Codex\app"
}

if (-not (Test-Path -LiteralPath $AppRoot -PathType Container)) {
    throw "CodexRebuild app was not found: $AppRoot. Run CodexRebuild-OneClick.cmd first to build the writable Store copy, then rerun this script."
}

$appRootPath = (Resolve-Path -LiteralPath $AppRoot -ErrorAction Stop).Path.TrimEnd("\")
$expectedPrefix = $rootPath + "\"
if (-not ($appRootPath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase) -or $appRootPath.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase))) {
    throw "Refusing to prepare app outside root. Root=$rootPath AppRoot=$appRootPath"
}

$exePath = Join-Path $appRootPath "Codex.exe"
$resourcesRoot = Join-Path $appRootPath "resources"
$asarPath = Join-Path $resourcesRoot "app.asar"
$unpackedAppDir = Join-Path $resourcesRoot "app"
$webviewAsarPath = Join-Path $resourcesRoot "app.asar.bak.webview"
$backupRoot = Join-Path $rootPath "webview-patch-backup"
$stagingRoot = Join-Path $rootPath ".webview-patch-staging"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $backupRoot $stamp
$stageAppDir = Join-Path $stagingRoot "app-$stamp"
$manifestPath = Join-Path $resourcesRoot "webview-patch-manifest.json"

if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "CodexRebuild app is incomplete. Missing Codex.exe: $exePath. Run CodexRebuild-OneClick.cmd to rebuild the writable copy."
}
if (-not (Test-Path -LiteralPath $resourcesRoot -PathType Container)) {
    throw "CodexRebuild app is incomplete. Missing resources directory: $resourcesRoot. Run CodexRebuild-OneClick.cmd to rebuild the writable copy."
}

$running = @(Get-RebuildProcesses -AppRoot $appRootPath)
if ($running.Count -gt 0) {
    Write-Warning "CodexRebuild processes are running from $appRootPath"
    $running | Format-Table -AutoSize | Out-String | Write-Host
    if ($StopRunningRebuild) {
        if (-not $DryRun) {
            Stop-RebuildProcesses -Processes $running
            Start-Sleep -Seconds 2
        }
    } else {
        throw "Close CodexRebuild first, or rerun with -StopRunningRebuild."
    }
}

Write-Host "Root:      $rootPath"
Write-Host "App root:  $appRootPath"
Write-Host "Resources: $resourcesRoot"
Write-Host "Mode:      $(if ($DryRun) { 'DRY-RUN PREPARE WEBVIEW PATCH' } else { 'PREPARE WEBVIEW PATCH' })"
Write-Host "Tools:     $electronAsarPackage, $electronFusesPackage"
Write-Host ""

$hasAsar = Test-Path -LiteralPath $asarPath -PathType Leaf
$hasExtractedApp = Test-Path -LiteralPath $unpackedAppDir -PathType Container

if (-not $hasAsar -and -not $hasExtractedApp) {
    throw "Neither app.asar nor extracted resources\app exists."
}

if ($DryRun) {
    if ($hasAsar) {
        Write-Host "Would extract: $asarPath -> $unpackedAppDir"
        Write-Host "Would move app.asar to: $webviewAsarPath"
    } else {
        Write-Host "Extracted webview app already exists: $unpackedAppDir"
    }
    Write-Host "Would ensure Electron fuses allow loading resources\app."
    exit 0
}

$npxPath = Get-NpxPath
$action = if ($hasAsar) { "extracted" } else { "already extracted" }
$backupPathForManifest = $null

if ($hasAsar) {
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    $backupPathForManifest = New-PrepareBackup -BackupDir $backupDir -ExePath $exePath -AsarPath $asarPath

    Remove-Item -LiteralPath $stageAppDir -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-External -FilePath $npxPath -Arguments @("--yes", $electronAsarPackage, "extract", $asarPath, $stageAppDir)

    if (Test-Path -LiteralPath $unpackedAppDir) {
        Move-Item -LiteralPath $unpackedAppDir -Destination (Join-Path $backupDir "app.previous") -Force
    }
    Move-Item -LiteralPath $stageAppDir -Destination $unpackedAppDir -Force

    if (Test-Path -LiteralPath $webviewAsarPath -PathType Leaf) {
        Move-Item -LiteralPath $webviewAsarPath -Destination (Join-Path $backupDir "app.asar.bak.webview.previous") -Force
    }
    Move-Item -LiteralPath $asarPath -Destination $webviewAsarPath -Force
}

$fuseOutputBefore = Read-Fuses -NpxPath $npxPath -ExePath $exePath -PackageSpec $electronFusesPackage
$fuseNeedsWrite = ($fuseOutputBefore -notmatch "EnableEmbeddedAsarIntegrityValidation is Disabled" -or
    $fuseOutputBefore -notmatch "OnlyLoadAppFromAsar is Disabled")
if ($fuseNeedsWrite) {
    if (-not $backupPathForManifest) {
        $backupPathForManifest = New-PrepareBackup -BackupDir $backupDir -ExePath $exePath
    }

    Invoke-External -FilePath $npxPath -Arguments @(
        "--yes",
        $electronFusesPackage,
        "write",
        "--app",
        $exePath,
        "EnableEmbeddedAsarIntegrityValidation=off",
        "OnlyLoadAppFromAsar=off"
    )
}

$fuseOutputAfter = Read-Fuses -NpxPath $npxPath -ExePath $exePath -PackageSpec $electronFusesPackage
Assert-FusesDisabled -FuseText $fuseOutputAfter

if (Test-Path -LiteralPath $stagingRoot -PathType Container) {
    $remainingStageEntries = @(Get-ChildItem -LiteralPath $stagingRoot -Force -ErrorAction Stop)
    if ($remainingStageEntries.Count -eq 0) {
        Remove-Item -LiteralPath $stagingRoot -Force
    }
}

$manifest = [ordered]@{
    preparedAt = (Get-Date).ToString("o")
    root = $rootPath
    appRoot = $appRootPath
    resourcesRoot = $resourcesRoot
    extractedAppDir = $unpackedAppDir
    action = $action
    backupDir = $backupPathForManifest
    asarPath = $asarPath
    webviewAsarPath = $webviewAsarPath
    toolPackages = [ordered]@{
        asar = $electronAsarPackage
        fuses = $electronFusesPackage
    }
    fuses = ($fuseOutputAfter -split "`r?`n" | Where-Object { $_.Trim() })
}
$manifest | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $manifestPath -Encoding UTF8

Write-Host "Webview patch environment ready."
Write-Host "Action:   $action"
Write-Host "App dir:  $unpackedAppDir"
Write-Host "Manifest: $manifestPath"
if ($backupPathForManifest) {
    Write-Host "Backup:   $backupPathForManifest"
} else {
    Write-Host "Backup:   <not needed>"
}
