[CmdletBinding()]
param(
    [string] $Root,

    [int] $WaitSeconds = 12,

    [switch] $StopExisting,

    [switch] $KeepRunning
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-RootPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolved.Path -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw "Not a directory: $Path"
    }

    return $item.FullName.TrimEnd("\")
}

function Test-RebuildRuntimeFiles {
    param([Parameter(Mandatory = $true)][string] $ResourcesRoot)

    $checks = @(
        [pscustomobject]@{
            Name = "better-sqlite3 native module"
            RelativePaths = @("app.asar.unpacked\node_modules\better-sqlite3\build\Release\better_sqlite3.node")
            MinLength = 1000000
        },
        [pscustomobject]@{
            Name = "node-pty pty native module"
            RelativePaths = @(
                "app.asar.unpacked\node_modules\node-pty\prebuilds\win32-x64\pty.node",
                "app.asar.unpacked\node_modules\node-pty\build\Release\pty.node"
            )
            MinLength = 100000
        },
        [pscustomobject]@{
            Name = "node-pty conpty native module"
            RelativePaths = @(
                "app.asar.unpacked\node_modules\node-pty\prebuilds\win32-x64\conpty.node",
                "app.asar.unpacked\node_modules\node-pty\build\Release\conpty.node"
            )
            MinLength = 100000
        },
        [pscustomobject]@{
            Name = "bundled Browser Use skill"
            RelativePaths = @("plugins\openai-bundled\plugins\browser-use\skills\browser\SKILL.md")
            MinLength = 1000
        }
    )

    foreach ($check in $checks) {
        $bestCandidate = $null
        foreach ($relativePath in @($check.RelativePaths)) {
            $path = Join-Path $ResourcesRoot $relativePath
            $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            $length = if ($item) { $item.Length } else { 0 }
            $candidate = [pscustomobject]@{
                RelativePath = $relativePath
                Path = $path
                Exists = [bool]$item
                Length = $length
                Ok = ([bool]$item -and $length -ge $check.MinLength)
            }

            if ($candidate.Ok) {
                $bestCandidate = $candidate
                break
            }

            if ((-not $bestCandidate) -or ((-not $bestCandidate.Exists) -and $candidate.Exists) -or ($candidate.Exists -and $candidate.Length -gt $bestCandidate.Length)) {
                $bestCandidate = $candidate
            }
        }

        [pscustomobject]@{
            Name = $check.Name
            RelativePath = $bestCandidate.RelativePath
            CandidatePaths = @($check.RelativePaths)
            Path = $bestCandidate.Path
            Exists = $bestCandidate.Exists
            Length = $bestCandidate.Length
            MinLength = $check.MinLength
            Ok = $bestCandidate.Ok
        }
    }
}

function Assert-RebuildRuntimeFiles {
    param([Parameter(Mandatory = $true)][string] $ResourcesRoot)

    $results = @(Test-RebuildRuntimeFiles -ResourcesRoot $ResourcesRoot)
    $failed = @($results | Where-Object { -not $_.Ok })
    if ($failed.Count -gt 0) {
        $failed | Select-Object Name, RelativePath, @{Name = "CandidatePaths"; Expression = { $_.CandidatePaths -join "; " } }, Exists, Length, MinLength | Format-Table -AutoSize | Out-String | Write-Host
        throw "Runtime validation failed."
    }

    $results | Select-Object Name, Length, RelativePath | Format-Table -AutoSize | Out-String | Write-Host
    return $results
}

function Get-RebuildProcesses {
    param([Parameter(Mandatory = $true)][string] $AppRoot)

    Get-CimInstance Win32_Process |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -like "$AppRoot\*" } |
        Select-Object ProcessId, Name, ExecutablePath, CommandLine
}

function Stop-RebuildProcesses {
    param([Parameter(Mandatory = $true)][object[]] $Processes)

    foreach ($process in $Processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-LaunchGuard {
    param([Parameter(Mandatory = $true)][string] $RootPath)

    $guardPath = Join-Path $RootPath "CodexRebuild-LaunchGuard.ps1"
    if (-not (Test-Path -LiteralPath $guardPath -PathType Leaf)) {
        throw "CodexRebuild launch guard was not found: $guardPath"
    }

    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $guardPath -Root $RootPath -NoMessageBox 2>&1
    $exit = $LASTEXITCODE
    $output | Write-Host
    if ($exit -ne 0) {
        throw "CodexRebuild launch guard failed with exit code $exit. Refusing to start smoke test."
    }
}

function Get-WindowTextsForProcessIds {
    param([Parameter(Mandatory = $true)][int[]] $ProcessIds)

    $texts = New-Object System.Collections.Generic.List[string]
    try {
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes

        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($window in $windows) {
            if ($ProcessIds -notcontains $window.Current.ProcessId) {
                continue
            }

            if ($window.Current.Name) {
                $texts.Add($window.Current.Name)
            }

            $children = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            foreach ($child in $children) {
                if ($child.Current.Name) {
                    $texts.Add($child.Current.Name)
                }
            }
        }
    } catch {
        Write-Warning "UI Automation window text probe failed: $($_.Exception.Message)"
    }

    return @($texts | Select-Object -Unique)
}

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}

$rootPath = Resolve-RootPath -Path $Root
$appRoot = Join-Path $rootPath "Codex\app"
$resourcesRoot = Join-Path $appRoot "resources"
$appExe = Join-Path $appRoot "Codex.exe"

if (-not (Test-Path -LiteralPath $appExe -PathType Leaf)) {
    throw "CodexRebuild app was not found: $appExe. Run CodexRebuild-OneClick.cmd first to build the writable Store copy, then rerun this script."
}

Invoke-LaunchGuard -RootPath $rootPath

Write-Host "Runtime file validation:"
[void](Assert-RebuildRuntimeFiles -ResourcesRoot $resourcesRoot)

$existing = @(Get-RebuildProcesses -AppRoot $appRoot)
if ($existing.Count -gt 0) {
    Write-Warning "Existing CodexRebuild processes are running."
    $existing | Select-Object ProcessId, Name, ExecutablePath | Format-Table -AutoSize | Out-String | Write-Host
    if ($StopExisting) {
        Stop-RebuildProcesses -Processes $existing
        Start-Sleep -Seconds 2
    } else {
        throw "Close CodexRebuild first, or rerun this smoke test with -StopExisting."
    }
}

$smokeRoot = Join-Path $rootPath ".smoke"
New-Item -ItemType Directory -Path $smokeRoot -Force | Out-Null
$smokeUserData = Join-Path $smokeRoot ("UserData-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Path $smokeUserData -Force | Out-Null

Write-Host "Starting smoke test:"
Write-Host "  app:       $appExe"
Write-Host "  user data: $smokeUserData"

$oldUserData = [Environment]::GetEnvironmentVariable("CODEX_ELECTRON_USER_DATA_PATH", "Process")
[Environment]::SetEnvironmentVariable("CODEX_ELECTRON_USER_DATA_PATH", $smokeUserData, "Process")
try {
    $process = Start-Process -FilePath $appExe -WorkingDirectory $appRoot -PassThru
} finally {
    [Environment]::SetEnvironmentVariable("CODEX_ELECTRON_USER_DATA_PATH", $oldUserData, "Process")
}
Start-Sleep -Seconds $WaitSeconds

$running = @(Get-RebuildProcesses -AppRoot $appRoot)
if ($running.Count -eq 0) {
    throw "CodexRebuild did not stay running during the smoke test."
}

$processIds = @($running | ForEach-Object { [int]$_.ProcessId })
$windowTexts = @(Get-WindowTextsForProcessIds -ProcessIds $processIds)
$knownFailure = @($windowTexts | Where-Object { $_ -match "Codex failed to start|better-sqlite3 is only bundled|failed to start" })

if ($knownFailure.Count -gt 0) {
    Write-Warning "Detected startup failure dialog text:"
    $knownFailure | Write-Host
    throw "CodexRebuild smoke test detected a startup failure dialog."
}

Write-Host "Smoke test passed. Running processes:"
$running | Select-Object ProcessId, Name, ExecutablePath | Format-Table -AutoSize | Out-String | Write-Host

if (-not $KeepRunning) {
    Stop-RebuildProcesses -Processes $running
    Write-Host "Smoke test processes stopped."
}
