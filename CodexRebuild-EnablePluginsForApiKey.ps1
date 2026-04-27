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

$patchMarker = "CodexRebuildPluginLoginBypass"

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

function Find-PluginGateFile {
    param([Parameter(Mandatory = $true)][string] $ExtractedAppDir)

    $assetRoot = Join-Path $ExtractedAppDir "webview\assets"
    if (-not (Test-Path -LiteralPath $assetRoot -PathType Container)) {
        throw "Missing webview assets directory: $assetRoot"
    }

    $patchableMatches = @()
    foreach ($file in Get-ChildItem -LiteralPath $assetRoot -Filter "*.js" -File -ErrorAction Stop) {
        $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        $tooltipIndex = $content.IndexOf("sidebarElectron.pluginsDisabledTooltip", [StringComparison]::Ordinal)
        if ($tooltipIndex -lt 0) {
            continue
        }
        if ($content.Contains($patchMarker)) {
            $patchableMatches += $file
            continue
        }

        $windowStart = [Math]::Max(0, $tooltipIndex - 20000)
        $windowLength = $tooltipIndex - $windowStart
        $prefix = $content.Substring($windowStart, $windowLength)
        $pattern = '([A-Za-z_$][A-Za-z0-9_$]*)=([A-Za-z_$][A-Za-z0-9_$]*)===`apikey`,([A-Za-z_$][A-Za-z0-9_$]*)=([A-Za-z_$][A-Za-z0-9_$]*)&&\1,'
        if ([regex]::IsMatch($prefix, $pattern)) {
            $patchableMatches += $file
        }
    }

    if ($patchableMatches.Count -eq 0) {
        throw "Plugin login gate marker was not found under: $assetRoot"
    }
    if ($patchableMatches.Count -gt 1) {
        throw "Plugin login gate marker matched multiple patchable files: $($patchableMatches.FullName -join ', ')"
    }

    return $patchableMatches[0].FullName
}

function Set-PluginLoginBypassPatch {
    param([Parameter(Mandatory = $true)][string] $TargetPath)

    $content = Get-Content -LiteralPath $TargetPath -Raw -Encoding UTF8
    if ($content.Contains($patchMarker)) {
        return "already patched"
    }

    $tooltipIndex = $content.IndexOf("sidebarElectron.pluginsDisabledTooltip", [StringComparison]::Ordinal)
    if ($tooltipIndex -lt 0) {
        throw "Plugin disabled tooltip marker was not found in $TargetPath"
    }

    $windowStart = [Math]::Max(0, $tooltipIndex - 20000)
    $windowLength = $tooltipIndex - $windowStart
    $prefix = $content.Substring($windowStart, $windowLength)

    $pattern = '([A-Za-z_$][A-Za-z0-9_$]*)=([A-Za-z_$][A-Za-z0-9_$]*)===`apikey`,([A-Za-z_$][A-Za-z0-9_$]*)=([A-Za-z_$][A-Za-z0-9_$]*)&&\1,'
    $matches = [regex]::Matches($prefix, $pattern)
    if ($matches.Count -eq 0) {
        throw "API-key plugin gate assignment was not found before the disabled Plugins tooltip in $TargetPath"
    }

    $match = $matches[$matches.Count - 1]
    $apiKeyFlagVar = $match.Groups[1].Value
    $disabledPluginsVar = $match.Groups[3].Value

    $absoluteMatchIndex = $windowStart + $match.Index
    $replacement = "$apiKeyFlagVar=false/*$patchMarker*/,$disabledPluginsVar=false,"
    $patched = $content.Substring(0, $absoluteMatchIndex) +
        $replacement +
        $content.Substring($absoluteMatchIndex + $match.Length)

    [System.IO.File]::WriteAllText($TargetPath, $patched, [System.Text.UTF8Encoding]::new($false))
    return "patched"
}

function Test-PluginLoginBypassPatch {
    param([Parameter(Mandatory = $true)][string] $TargetPath)

    $content = Get-Content -LiteralPath $TargetPath -Raw -Encoding UTF8
    if (-not $content.Contains($patchMarker)) {
        throw "Plugin login bypass marker is missing from $TargetPath"
    }

    if (-not $content.Contains("sidebarElectron.pluginsDisabledTooltip")) {
        throw "Plugin disabled tooltip marker disappeared unexpectedly from $TargetPath"
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
$extractedAppDir = Join-Path $resourcesRoot "app"
$backupRoot = Join-Path $rootPath "plugin-login-bypass-backup"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $backupRoot $stamp

Write-Host ""
Write-Host "Plugin API-key gate patch:"
Write-Host "Root:      $rootPath"
Write-Host "App root:  $appRootPath"
Write-Host "Mode:      $(if ($DryRun) { 'DRY-RUN PLUGINS FOR API KEY' } else { 'ENABLE PLUGINS FOR API KEY' })"
Write-Host ""

if ($DryRun) {
    if (Test-Path -LiteralPath $extractedAppDir -PathType Container) {
        $targetPath = Find-PluginGateFile -ExtractedAppDir $extractedAppDir
        $content = Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8
        if ($content.Contains($patchMarker)) {
            Write-Host "Already patched: $targetPath"
        } else {
            Write-Host "Would patch: $targetPath"
        }
    } else {
        Write-Host "Would resolve and patch the Plugins API-key gate after webview preparation."
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $extractedAppDir -PathType Container)) {
    throw "Missing extracted webview app after preparation: $extractedAppDir"
}

$targetPath = Find-PluginGateFile -ExtractedAppDir $extractedAppDir
$targetContentBefore = Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8
$backupPathForManifest = $null
if (-not $targetContentBefore.Contains($patchMarker)) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Copy-Item -LiteralPath $targetPath -Destination (Join-Path $backupDir (Split-Path -Leaf $targetPath)) -Force
    $backupPathForManifest = $backupDir
}

$patchState = Set-PluginLoginBypassPatch -TargetPath $targetPath
Test-PluginLoginBypassPatch -TargetPath $targetPath

$manifest = [ordered]@{
    enabledAt = (Get-Date).ToString("o")
    root = $rootPath
    appRoot = $appRootPath
    backupDir = $backupPathForManifest
    target = $targetPath
    patchState = $patchState
    marker = $patchMarker
    prepareManifest = (Join-Path $resourcesRoot "webview-patch-manifest.json")
}
$manifest | ConvertTo-Json -Depth 5 | Out-File -LiteralPath (Join-Path $resourcesRoot "plugin-login-bypass-manifest.json") -Encoding UTF8

Write-Host "Plugin API-key gate patch applied."
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
