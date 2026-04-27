[CmdletBinding()]
param(
    [string] $Root,

    [switch] $Execute,

    [switch] $KeepDesktopShortcut,

    [switch] $NoStopProcesses
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

function Assert-UnderRoot {
    param(
        [Parameter(Mandatory = $true)][string] $RootPath,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
    $expectedPrefix = $RootPath.TrimEnd("\") + "\"
    if ($fullPath.Equals($RootPath, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath
    }

    throw "Refusing to remove path outside root. Root=$RootPath Path=$fullPath"
}

function Join-RootChild {
    param(
        [Parameter(Mandatory = $true)][string] $RootPath,
        [Parameter(Mandatory = $true)][string] $Name
    )

    return Assert-UnderRoot -RootPath $RootPath -Path (Join-Path $RootPath $Name)
}

function Get-RebuildProcesses {
    param([Parameter(Mandatory = $true)][string] $RootPath)

    $appRoot = Join-Path $RootPath "Codex\app"
    Get-CimInstance Win32_Process |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -like "$appRoot\*" } |
        Select-Object ProcessId, Name, ExecutablePath
}

function Stop-RebuildProcesses {
    param([Parameter(Mandatory = $true)][object[]] $Processes)

    foreach ($process in $Processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
    }
}

function Grant-DeleteAccess {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $account = "$env:COMPUTERNAME\$env:USERNAME"
    Write-Warning "Repairing ACL before delete: $Path"
    & takeown.exe /F $Path /R /D Y | Write-Host
    & icacls.exe $Path /grant "${account}:(OI)(CI)F" /T /C | Write-Host
}

function Remove-GeneratedPath {
    param(
        [Parameter(Mandatory = $true)][object] $Target,
        [switch] $Execute
    )

    if (-not (Test-Path -LiteralPath $Target.Path)) {
        return "missing"
    }

    if (-not $Execute) {
        return "would remove"
    }

    try {
        if ($Target.Kind -eq "Directory") {
            Remove-Item -LiteralPath $Target.Path -Recurse -Force -ErrorAction Stop
        } else {
            Remove-Item -LiteralPath $Target.Path -Force -ErrorAction Stop
        }
    } catch {
        if ($Target.Kind -ne "Directory") {
            throw
        }

        Grant-DeleteAccess -Path $Target.Path
        Remove-Item -LiteralPath $Target.Path -Recurse -Force -ErrorAction Stop
    }

    if (Test-Path -LiteralPath $Target.Path) {
        throw "Failed to remove generated artifact: $($Target.Path)"
    }

    return "removed"
}

function Test-ShortcutBelongsToRoot {
    param(
        [Parameter(Mandatory = $true)][string] $ShortcutPath,
        [Parameter(Mandatory = $true)][string] $RootPath
    )

    if (-not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) {
        return $false
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        if ([string]::IsNullOrWhiteSpace($shortcut.TargetPath)) {
            return $false
        }

        [void](Assert-UnderRoot -RootPath $RootPath -Path $shortcut.TargetPath)
        return $true
    } catch {
        Write-Warning "Skipping shortcut because its target is outside this root or unreadable: $ShortcutPath"
        return $false
    }
}

$rootPath = Resolve-RootPath -Path $Root

$generatedDirectories = @(
    ".smoke",
    ".staging",
    ".webview-patch-staging",
    ".core-staging",
    ".core-install-staging",
    "Codex",
    "Core",
    "archive",
    "core-archive",
    "UserData",
    "fast-mode-backup",
    "plugin-login-bypass-backup",
    "true-delete-backup",
    "webview-patch-backup"
)

$generatedFiles = @(
    "CodexRebuild-Launch.cmd"
)

$targets = New-Object System.Collections.Generic.List[object]
foreach ($name in $generatedDirectories) {
    $path = Join-RootChild -RootPath $rootPath -Name $name
    if (Test-Path -LiteralPath $path -PathType Container) {
        $targets.Add([pscustomobject]@{ Kind = "Directory"; Name = $name; Path = $path })
    }
}

foreach ($name in $generatedFiles) {
    $path = Join-RootChild -RootPath $rootPath -Name $name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $targets.Add([pscustomobject]@{ Kind = "File"; Name = $name; Path = $path })
    }
}

if (-not $KeepDesktopShortcut) {
    $desktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "CodexRebuild.lnk"
    if (Test-ShortcutBelongsToRoot -ShortcutPath $desktopShortcut -RootPath $rootPath) {
        $targets.Add([pscustomobject]@{ Kind = "File"; Name = "Desktop shortcut: CodexRebuild.lnk"; Path = $desktopShortcut })
    }
}

Write-Host "Root: $rootPath"
Write-Host "Mode: $(if ($Execute) { 'EXECUTE cleanup' } else { 'DRY-RUN cleanup' })"
Write-Host ""

if ($targets.Count -eq 0) {
    Write-Host "No generated artifacts found."
    exit 0
}

Write-Host "Generated artifacts:"
$targets | Select-Object Kind, Name, Path | Format-Table -AutoSize | Out-String | Write-Host

if ($Execute -and -not $NoStopProcesses) {
    $running = @(Get-RebuildProcesses -RootPath $rootPath)
    if ($running.Count -gt 0) {
        Write-Warning "Stopping CodexRebuild processes before cleanup."
        $running | Format-Table -AutoSize | Out-String | Write-Host
        Stop-RebuildProcesses -Processes $running
        Start-Sleep -Seconds 2
    }
}

$results = foreach ($target in $targets) {
    [pscustomobject]@{
        Kind = $target.Kind
        Name = $target.Name
        Path = $target.Path
        Result = Remove-GeneratedPath -Target $target -Execute:$Execute
    }
}

Write-Host ""
Write-Host "Cleanup results:"
$results | Format-Table -AutoSize | Out-String | Write-Host

if (-not $Execute) {
    Write-Host "Dry-run only. Rerun with -Execute to remove these generated artifacts."
    exit 0
}

$remaining = @($results | Where-Object { Test-Path -LiteralPath $_.Path })
if ($remaining.Count -gt 0) {
    $remaining | Format-Table -AutoSize | Out-String | Write-Host
    throw "Some generated artifacts still exist after cleanup."
}

Write-Host "Generated artifacts removed. Scripts, docs, plans, and user-provided release packages were preserved."
