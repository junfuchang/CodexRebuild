[CmdletBinding()]
param(
    [string] $Root,

    [string] $AppRoot,

    [switch] $StopRunningRebuild,

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

function Invoke-Script {
    param(
        [Parameter(Mandatory = $true)][string] $ScriptPath,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$ScriptPath failed with exit code $LASTEXITCODE"
    }
}

function Find-FastModeTarget {
    param([Parameter(Mandatory = $true)][string] $ExtractedAppDir)

    $assetRoot = Join-Path $ExtractedAppDir "webview\assets"
    if (-not (Test-Path -LiteralPath $assetRoot -PathType Container)) {
        throw "Missing webview assets directory: $assetRoot"
    }

    $matches = @(Get-ChildItem -LiteralPath $assetRoot -Filter "general-settings-*.js" -File -ErrorAction Stop |
        Sort-Object Length -Descending)
    if ($matches.Count -eq 0) {
        throw "No general-settings-*.js file was found under: $assetRoot"
    }

    return $matches[0].FullName
}

function Set-FastModePatch {
    param([Parameter(Mandatory = $true)][string] $TargetPath)

    $content = Get-Content -LiteralPath $TargetPath -Raw -Encoding UTF8
    if ($content.Contains("if(false)return null;")) {
        return "already patched"
    }

    if (-not $content.Contains("if(!n)return null;")) {
        throw "Fast mode marker was not found in $TargetPath"
    }

    $content = $content.Replace("if(!n)return null;", "if(false)return null;")
    [System.IO.File]::WriteAllText($TargetPath, $content, [System.Text.UTF8Encoding]::new($false))
    return "patched"
}

function Test-FastModePatch {
    param([Parameter(Mandatory = $true)][string] $TargetPath)

    $content = Get-Content -LiteralPath $TargetPath -Raw -Encoding UTF8
    if (-not $content.Contains("if(false)return null;")) {
        throw "Fast mode patch verification failed: $TargetPath"
    }
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
    throw "Refusing to patch app outside root. Root=$rootPath AppRoot=$appRootPath"
}

$prepareScript = Join-Path $rootPath "CodexRebuild-PrepareWebviewPatch.ps1"
if (-not (Test-Path -LiteralPath $prepareScript -PathType Leaf)) {
    throw "Missing webview prepare script: $prepareScript"
}

$prepareArgs = @("-Root", $rootPath, "-AppRoot", $appRootPath)
if ($StopRunningRebuild) {
    $prepareArgs += "-StopRunningRebuild"
}
if ($DryRun) {
    $prepareArgs += "-DryRun"
}
Invoke-Script -ScriptPath $prepareScript -Arguments $prepareArgs

$resourcesRoot = Join-Path $appRootPath "resources"
$unpackedAppDir = Join-Path $resourcesRoot "app"
$backupRoot = Join-Path $rootPath "fast-mode-backup"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $backupRoot $stamp

Write-Host ""
Write-Host "Fast mode patch:"
Write-Host "Root:      $rootPath"
Write-Host "App root:  $appRootPath"
Write-Host "Mode:      $(if ($DryRun) { 'DRY-RUN FAST MODE' } else { 'ENABLE FAST MODE' })"
Write-Host ""

if ($DryRun) {
    if (Test-Path -LiteralPath $unpackedAppDir -PathType Container) {
        $targetPath = Find-FastModeTarget -ExtractedAppDir $unpackedAppDir
        $content = Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8
        if ($content.Contains("if(false)return null;")) {
            Write-Host "Already patched: $targetPath"
        } else {
            Write-Host "Would patch: $targetPath"
        }
    } else {
        Write-Host "Would resolve and patch general-settings after webview preparation."
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $unpackedAppDir -PathType Container)) {
    throw "Missing extracted webview app after preparation: $unpackedAppDir"
}

$targetPath = Find-FastModeTarget -ExtractedAppDir $unpackedAppDir
$targetContentBefore = Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8
$backupPathForManifest = $null
if (-not $targetContentBefore.Contains("if(false)return null;")) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Copy-Item -LiteralPath $targetPath -Destination (Join-Path $backupDir (Split-Path -Leaf $targetPath)) -Force
    $backupPathForManifest = $backupDir
}

$patchState = Set-FastModePatch -TargetPath $targetPath
Test-FastModePatch -TargetPath $targetPath

$manifest = [ordered]@{
    enabledAt = (Get-Date).ToString("o")
    root = $rootPath
    appRoot = $appRootPath
    backupDir = $backupPathForManifest
    fastModeTarget = $targetPath
    patchState = $patchState
    prepareManifest = (Join-Path $resourcesRoot "webview-patch-manifest.json")
}
$manifest | ConvertTo-Json -Depth 5 | Out-File -LiteralPath (Join-Path $resourcesRoot "fast-mode-manifest.json") -Encoding UTF8

Write-Host "Fast mode patch applied."
Write-Host "Patch state: $patchState"
Write-Host "Target:      $targetPath"
if ($backupPathForManifest) {
    Write-Host "Backup:      $backupPathForManifest"
} else {
    Write-Host "Backup:      <not needed>"
}

if (-not $NoSmokeTest) {
    $testScript = Join-Path $rootPath "CodexRebuild-Test.ps1"
    if (-not (Test-Path -LiteralPath $testScript -PathType Leaf)) {
        throw "Missing smoke test script: $testScript"
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $testScript -Root $rootPath -StopExisting
    if ($LASTEXITCODE -ne 0) {
        throw "Smoke test failed with exit code $LASTEXITCODE"
    }
}
