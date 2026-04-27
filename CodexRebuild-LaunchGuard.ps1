[CmdletBinding()]
param(
    [string] $Root,

    [string] $PackageName = "OpenAI.Codex",

    [string] $WindowsAppsRoot,

    [string] $StoreVersionOverride,

    [string] $RebuildVersionOverride,

    [switch] $NoMessageBox
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-Utf8String {
    param([Parameter(Mandatory = $true)][string] $Base64)

    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
}

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

function Get-MainVersion {
    param([Parameter(Mandatory = $true)][string] $VersionText)

    if ($VersionText -notmatch '^(?<Major>\d+)\.(?<Minor>\d+)') {
        throw "Could not parse major version from: $VersionText"
    }

    return "$($Matches.Major).$($Matches.Minor)"
}

function Resolve-StoreVersion {
    param(
        [Parameter(Mandatory = $true)][string] $PackageName,
        [string] $WindowsAppsRoot,
        [string] $Override
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return [pscustomobject]@{
            Version = $Override
            Source = "override"
        }
    }

    $package = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue |
        Where-Object { $_.InstallLocation } |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($package) {
        return [pscustomobject]@{
            Version = $package.Version.ToString()
            Source = "Get-AppxPackage"
        }
    }

    if ([string]::IsNullOrWhiteSpace($WindowsAppsRoot)) {
        if ([string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
            throw "ProgramFiles environment variable is not set."
        }
        $WindowsAppsRoot = Join-Path $env:ProgramFiles "WindowsApps"
    }

    $escapedPackageName = [regex]::Escape($PackageName)
    $candidate = Get-ChildItem -LiteralPath $WindowsAppsRoot -Directory -Filter "$PackageName`_*" -ErrorAction Stop |
        ForEach-Object {
            $version = $null
            if ($_.Name -match "^${escapedPackageName}_(?<Version>[0-9]+(?:\.[0-9]+)+)_") {
                $version = $Matches.Version
            }

            [pscustomobject]@{
                Version = $version
                HasApp = (Test-Path -LiteralPath (Join-Path $_.FullName "app\Codex.exe") -PathType Leaf)
            }
        } |
        Where-Object { $_.HasApp -and $_.Version } |
        Sort-Object { [version]$_.Version } -Descending |
        Select-Object -First 1

    if (-not $candidate) {
        throw "$PackageName package was not found."
    }

    return [pscustomobject]@{
        Version = $candidate.Version
        Source = "WindowsApps scan"
    }
}

function Resolve-RebuildVersion {
    param(
        [Parameter(Mandatory = $true)][string] $RootPath,
        [string] $Override
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return [pscustomobject]@{
            Version = $Override
            Source = "override"
        }
    }

    $manifestPath = Join-Path $RootPath "Codex\codex-rebuild-manifest.json"
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($manifest.store -and $manifest.store.Version) {
            return [pscustomobject]@{
                Version = [string]$manifest.store.Version
                Source = $manifestPath
            }
        }

        if ($manifest.store -and $manifest.store.PackageFullName -and $manifest.store.PackageFullName -match "^OpenAI\.Codex_(?<Version>[0-9]+(?:\.[0-9]+)+)_") {
            return [pscustomobject]@{
                Version = $Matches.Version
                Source = $manifestPath
            }
        }
    }

    $codexExe = Join-Path $RootPath "Codex\app\Codex.exe"
    $item = Get-Item -LiteralPath $codexExe -ErrorAction Stop
    $productVersion = $item.VersionInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($productVersion)) {
        throw "Rebuilt Codex.exe has no ProductVersion: $codexExe"
    }

    return [pscustomobject]@{
        Version = $productVersion
        Source = $codexExe
    }
}

function Show-BlockMessage {
    param(
        [Parameter(Mandatory = $true)][string] $Message,
        [Parameter(Mandatory = $true)][string] $Title,
        [string] $Icon = "Warning"
    )

    if ($NoMessageBox) {
        return
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $iconValue = [System.Windows.Forms.MessageBoxIcon]::$Icon
        [System.Windows.Forms.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            $iconValue
        ) | Out-Null
    } catch {
        Write-Output "Could not show message box: $($_.Exception.Message)"
    }
}

$mismatchMessage = Get-Utf8String -Base64 "5b2T5YmNQ29kZXjph43lu7rniYjkuI7mnKzmnLpNaWNyb3NvZnQgU3RvcmXniYjkuLvniYjmnKzlj7fkuI3nm7jlkIzvvIHlh7rkuo7lr7nmgqjnmoTotJ/otKPkuI7lr7lWaWJlQ29kaW5n55qE5oCA55aR5oCB5bqm77yM5L2g6ZyA6KaB6YeN5paw6L+b6KGM6YeN5bu65Lul6YG/5YWN5paw5pen54mI5pys5LiN5YW85a655a+86Ie06YWN572u5Yay56qB562J5oSP5aSW5oOF5Ya177yB5aaC6YGHQlVH6K+35o+QSXNzdWVz77yMR2l0SHVi5Zyw5Z2A77yaaHR0cHM6Ly9naXRodWIuY29tL2p1bmZ1Y2hhbmc="
$verifyFailureMessage = Get-Utf8String -Base64 "5peg5rOV56Gu6K6k5b2T5YmNQ29kZXjph43lu7rniYjkuI7mnKzmnLpNaWNyb3NvZnQgU3RvcmXniYjkuLvniYjmnKzlj7fmmK/lkKbnm7jlkIzvvIzlt7LpmLvmraLlkK/liqjjgILor7fph43mlrDov5vooYzph43lu7rmiJbmo4Dmn6UgTWljcm9zb2Z0IFN0b3JlIOeJiCBDb2RleCDmmK/lkKblt7Llronoo4XjgII="
$title = Get-Utf8String -Base64 "Q29kZXhSZWJ1aWxkIOeJiOacrOS4jeS4gOiHtA=="

try {
    $rootPath = Resolve-RootPath -Path $Root
    $store = Resolve-StoreVersion -PackageName $PackageName -WindowsAppsRoot $WindowsAppsRoot -Override $StoreVersionOverride
    $rebuild = Resolve-RebuildVersion -RootPath $rootPath -Override $RebuildVersionOverride
    $storeMain = Get-MainVersion -VersionText $store.Version
    $rebuildMain = Get-MainVersion -VersionText $rebuild.Version

    Write-Output "Store Codex version: $($store.Version) [$($store.Source)]"
    Write-Output "CodexRebuild version: $($rebuild.Version) [$($rebuild.Source)]"
    Write-Output "Store main version: $storeMain"
    Write-Output "CodexRebuild main version: $rebuildMain"

    if ($storeMain -ne $rebuildMain) {
        Write-Output $mismatchMessage
        Show-BlockMessage -Message $mismatchMessage -Title $title
        exit 20
    }

    Write-Output "CodexRebuild launch version guard passed."
    exit 0
} catch {
    $details = $_.Exception.Message
    Write-Output $verifyFailureMessage
    Write-Output "Details: $details"
    Show-BlockMessage -Message $verifyFailureMessage -Title $title
    exit 21
}
