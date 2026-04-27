[CmdletBinding()]
param(
    [string] $Root,

    [string] $AppRoot,

    [switch] $StopRunningRebuild,

    [switch] $DryRun,

    [switch] $NoSmokeTest
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

function Get-RebuildProcesses {
    param([Parameter(Mandatory = $true)][string] $AppRoot)

    Get-CimInstance Win32_Process |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -like "$AppRoot\*" } |
        Select-Object ProcessId, Name, ExecutablePath
}

function Stop-RebuildProcesses {
    param([Parameter(Mandatory = $true)][object[]] $Processes)

    foreach ($process in $Processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
    }
}

function Get-SingleFile {
    param(
        [Parameter(Mandatory = $true)][string] $Directory,
        [Parameter(Mandatory = $true)][string] $Filter,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $matches = @(Get-ChildItem -LiteralPath $Directory -Filter $Filter -File -ErrorAction Stop | Sort-Object Name)
    if ($matches.Count -eq 0) {
        throw "Could not find $Description in $Directory using filter $Filter."
    }
    if ($matches.Count -gt 1) {
        $names = ($matches | Select-Object -ExpandProperty Name) -join ", "
        throw "Found multiple $Description files in ${Directory}: $names"
    }
    return $matches[0].FullName
}

function Backup-FileOnce {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $BackupDir
    )

    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    $leaf = Split-Path -Leaf $Path
    $target = Join-Path $BackupDir $leaf
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        Copy-Item -LiteralPath $Path -Destination $target -Force
    }
}

function Replace-LiteralOnce {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Old,
        [Parameter(Mandatory = $true)][string] $New,
        [Parameter(Mandatory = $true)][string] $AlreadyPatchedNeedle,
        [Parameter(Mandatory = $true)][string] $Description,
        [Parameter(Mandatory = $true)][string] $BackupDir,
        [switch] $DryRun
    )

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $oldText = $Old.Trim("`r", "`n")
    $newText = $New.Trim("`r", "`n")
    if ($content.Contains($AlreadyPatchedNeedle)) {
        Write-Host "Already patched: $Description"
        return "already-patched"
    }
    if (-not $content.Contains($oldText)) {
        throw "Patch anchor not found for $Description in $Path"
    }

    Write-Host "$(if ($DryRun) { 'Would patch' } else { 'Patching' }): $Description"
    if ($DryRun) {
        return "would-patch"
    }

    Backup-FileOnce -Path $Path -BackupDir $BackupDir
    $updated = $content.Replace($oldText, $newText)
    Set-Content -LiteralPath $Path -Value $updated -Encoding UTF8 -NoNewline
    return "patched"
}

function Replace-LiteralMapOnce {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][object[]] $Replacements,
        [Parameter(Mandatory = $true)][string] $AlreadyPatchedNeedle,
        [Parameter(Mandatory = $true)][string] $Description,
        [Parameter(Mandatory = $true)][string] $BackupDir,
        [switch] $DryRun
    )

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($content.Contains($AlreadyPatchedNeedle)) {
        Write-Host "Already patched: $Description"
        return "already-patched"
    }

    foreach ($replacement in $Replacements) {
        $oldText = ([string]$replacement.Old).Trim("`r", "`n")
        $newText = ([string]$replacement.New).Trim("`r", "`n")
        if (-not $content.Contains($oldText)) {
            continue
        }

        Write-Host "$(if ($DryRun) { 'Would patch' } else { 'Patching' }): $Description"
        if ($DryRun) {
            return "would-patch"
        }

        Backup-FileOnce -Path $Path -BackupDir $BackupDir
        $updated = $content.Replace($oldText, $newText)
        Set-Content -LiteralPath $Path -Value $updated -Encoding UTF8 -NoNewline
        return "patched"
    }

    throw "Patch anchor not found for $Description in $Path"
}

function Add-SqliteFallbackToPath {
    if (Get-Command sqlite3 -ErrorAction SilentlyContinue) {
        return
    }

    $candidatePaths = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:CONDA_PREFIX)) {
        $candidatePaths.Add((Join-Path $env:CONDA_PREFIX "Library\bin\sqlite3.exe")) | Out-Null
    }

    foreach ($root in @($env:ProgramData, $env:LOCALAPPDATA, $env:USERPROFILE, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }
        $candidatePaths.Add((Join-Path $root "miniconda3\Library\bin\sqlite3.exe")) | Out-Null
        $candidatePaths.Add((Join-Path $root "anaconda3\Library\bin\sqlite3.exe")) | Out-Null
        $candidatePaths.Add((Join-Path $root "SQLite\sqlite3.exe")) | Out-Null
    }

    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $env:PATH = (Split-Path -Parent $candidate) + [IO.Path]::PathSeparator + $env:PATH
            return
        }
    }
}

function Add-PrerequisiteFailure {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]] $Failures,
        [Parameter(Mandatory = $true)][string] $Message
    )

    $Failures.Add($Message) | Out-Null
}

function Invoke-SqliteLines {
    param(
        [Parameter(Mandatory = $true)][string] $Database,
        [Parameter(Mandatory = $true)][string] $Sql,
        [Parameter(Mandatory = $true)] $SqliteCommand
    )

    $output = & $SqliteCommand.Source $Database $Sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "sqlite3 failed for $Database. SQL=$Sql Output=$($output -join ' ')"
    }

    return @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-SqliteTableColumns {
    param(
        [Parameter(Mandatory = $true)][string] $Database,
        [Parameter(Mandatory = $true)][string] $Table,
        [Parameter(Mandatory = $true)][string[]] $Columns,
        [Parameter(Mandatory = $true)] $SqliteCommand,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]] $Failures
    )

    try {
        $present = @(Invoke-SqliteLines -Database $Database -Sql "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '$Table';" -SqliteCommand $SqliteCommand)
        if ($present.Count -eq 0) {
            Add-PrerequisiteFailure -Failures $Failures -Message "Missing required SQLite table '$Table' in $Database."
            return
        }

        $actualColumns = @(Invoke-SqliteLines -Database $Database -Sql "SELECT name FROM pragma_table_info('$Table');" -SqliteCommand $SqliteCommand)
        foreach ($column in $Columns) {
            if ($actualColumns -notcontains $column) {
                Add-PrerequisiteFailure -Failures $Failures -Message "Missing required SQLite column '$Table.$column' in $Database."
            }
        }
    } catch {
        Add-PrerequisiteFailure -Failures $Failures -Message $_.Exception.Message
    }
}

function Test-PowerShellScriptSyntax {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]] $Failures
    )

    try {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors) | Out-Null
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            Add-PrerequisiteFailure -Failures $Failures -Message "PowerShell syntax check failed for ${Path}: $($parseErrors[0].Message)"
        }
    } catch {
        Add-PrerequisiteFailure -Failures $Failures -Message "Could not parse PowerShell script ${Path}: $($_.Exception.Message)"
    }
}

function Test-PatchAnchorCompatibility {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description,
        [Parameter(Mandatory = $true)][string] $AlreadyPatchedNeedle,
        [Parameter(Mandatory = $true)][string[]] $CandidateOldTexts,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]] $Failures,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]] $Results
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-PrerequisiteFailure -Failures $Failures -Message "Missing patch target for ${Description}: $Path"
        return
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($content.Contains($AlreadyPatchedNeedle)) {
        $Results.Add([pscustomobject]@{ target = $Description; state = "already-patched" }) | Out-Null
        return
    }

    foreach ($oldText in $CandidateOldTexts) {
        $candidate = ([string]$oldText).Trim("`r", "`n")
        if ($content.Contains($candidate)) {
            $Results.Add([pscustomobject]@{ target = $Description; state = "patchable" }) | Out-Null
            return
        }
    }

    Add-PrerequisiteFailure -Failures $Failures -Message "Patch anchor for '$Description' was not found in $Path."
}

function Assert-TrueDeletePrerequisites {
    param(
        [Parameter(Mandatory = $true)][string] $RootPath,
        [Parameter(Mandatory = $true)][string] $AppRootPath,
        [Parameter(Mandatory = $true)][string] $ResourcesRoot,
        [Parameter(Mandatory = $true)][string] $MainPath,
        [Parameter(Mandatory = $true)][string] $IndexPath,
        [Parameter(Mandatory = $true)][string] $DataControlsPath,
        [Parameter(Mandatory = $true)][string] $MainOld,
        [Parameter(Mandatory = $true)][string[]] $IndexHandlerCandidates,
        [Parameter(Mandatory = $true)][string[]] $SidebarActionCandidates,
        [Parameter(Mandatory = $true)][string[]] $SidebarMenuCandidates,
        [Parameter(Mandatory = $true)][string[]] $ArchivedSettingsCandidates
    )

    Write-Host "Checking true-delete prerequisites..."

    $failures = [System.Collections.Generic.List[string]]::new()
    $patchResults = [System.Collections.Generic.List[object]]::new()
    $homeDir = [Environment]::GetFolderPath("UserProfile")
    $codexRoot = Join-Path $homeDir ".codex"
    $stateDb = Join-Path $codexRoot "state_5.sqlite"
    $logsDb = Join-Path $codexRoot "logs_2.sqlite"
    $sessionIndex = Join-Path $codexRoot "session_index.jsonl"
    $sessionsRoot = Join-Path $codexRoot "sessions"
    $archivedRoot = Join-Path $codexRoot "archived_sessions"
    $skillScript = Join-Path $codexRoot "skills\junfu-delete-codex-session\scripts\remove-codex-session-hard.ps1"

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        Add-PrerequisiteFailure -Failures $failures -Message "Root path does not exist: $RootPath"
    }
    if (-not (Test-Path -LiteralPath $AppRootPath -PathType Container)) {
        Add-PrerequisiteFailure -Failures $failures -Message "CodexRebuild app root does not exist: $AppRootPath"
    }
    if (-not (Test-Path -LiteralPath $ResourcesRoot -PathType Container)) {
        Add-PrerequisiteFailure -Failures $failures -Message "CodexRebuild resources directory does not exist: $ResourcesRoot"
    }
    if (-not (Test-Path -LiteralPath $codexRoot -PathType Container)) {
        Add-PrerequisiteFailure -Failures $failures -Message "Codex home directory does not exist: $codexRoot"
    }
    if (-not ((Test-Path -LiteralPath $sessionsRoot -PathType Container) -or (Test-Path -LiteralPath $archivedRoot -PathType Container))) {
        Add-PrerequisiteFailure -Failures $failures -Message "Neither Codex session root exists: $sessionsRoot or $archivedRoot"
    }
    if (-not (Test-Path -LiteralPath $sessionIndex -PathType Leaf)) {
        Add-PrerequisiteFailure -Failures $failures -Message "Missing session index file expected by delete logic: $sessionIndex"
    }

    Add-SqliteFallbackToPath
    $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if (-not $sqlite) {
        Add-PrerequisiteFailure -Failures $failures -Message "sqlite3 was not found. Cannot verify Codex session database schema."
    } else {
        if (-not (Test-Path -LiteralPath $stateDb -PathType Leaf)) {
            Add-PrerequisiteFailure -Failures $failures -Message "Missing Codex state database: $stateDb"
        } else {
            Test-SqliteTableColumns -Database $stateDb -Table "threads" -Columns @("id", "title", "archived", "rollout_path", "agent_path", "updated_at_ms") -SqliteCommand $sqlite -Failures $failures
            Test-SqliteTableColumns -Database $stateDb -Table "thread_dynamic_tools" -Columns @("thread_id") -SqliteCommand $sqlite -Failures $failures
            Test-SqliteTableColumns -Database $stateDb -Table "stage1_outputs" -Columns @("thread_id") -SqliteCommand $sqlite -Failures $failures
            Test-SqliteTableColumns -Database $stateDb -Table "thread_spawn_edges" -Columns @("parent_thread_id", "child_thread_id") -SqliteCommand $sqlite -Failures $failures
            Test-SqliteTableColumns -Database $stateDb -Table "agent_job_items" -Columns @("assigned_thread_id") -SqliteCommand $sqlite -Failures $failures
        }

        if (Test-Path -LiteralPath $logsDb -PathType Leaf) {
            Test-SqliteTableColumns -Database $logsDb -Table "logs" -Columns @("thread_id") -SqliteCommand $sqlite -Failures $failures
        }
    }

    if (-not (Test-Path -LiteralPath $skillScript -PathType Leaf)) {
        Add-PrerequisiteFailure -Failures $failures -Message "Missing authoritative hard-delete script: $skillScript"
    } else {
        Test-PowerShellScriptSyntax -Path $skillScript -Failures $failures
        $skillText = Get-Content -LiteralPath $skillScript -Raw -Encoding UTF8
        foreach ($needle in @("[string]`$Id", "[switch]`$Execute", "thread_spawn_edges", "session_index.jsonl", "rollout_path", "logs_2.sqlite", "DELETE FROM threads")) {
            if (-not $skillText.Contains($needle)) {
                Add-PrerequisiteFailure -Failures $failures -Message "Hard-delete script no longer contains expected marker '$needle': $skillScript"
            }
        }
    }

    Test-PatchAnchorCompatibility -Path $MainPath -Description "Electron hard-delete handler" -AlreadyPatchedNeedle "CodexRebuild-HardDeleteSession.ps1" -CandidateOldTexts @($MainOld) -Failures $failures -Results $patchResults
    $mainContent = if (Test-Path -LiteralPath $MainPath -PathType Leaf) { Get-Content -LiteralPath $MainPath -Raw -Encoding UTF8 } else { "" }
    if ($mainContent.Contains('case`hard-delete-thread`') -and -not $mainContent.Contains("CodexRebuild-HardDeleteSession.ps1")) {
        Add-PrerequisiteFailure -Failures $failures -Message "Electron bundle appears to contain a native or changed hard-delete handler. Refusing to patch blindly: $MainPath"
    }

    Test-PatchAnchorCompatibility -Path $IndexPath -Description "webview hard-delete conversation handler" -AlreadyPatchedNeedle "CodexRebuildHardDeleteV2" -CandidateOldTexts $IndexHandlerCandidates -Failures $failures -Results $patchResults
    Test-PatchAnchorCompatibility -Path $IndexPath -Description "sidebar permanent delete menu action" -AlreadyPatchedNeedle "CodexRebuildDeleteActionV3" -CandidateOldTexts $SidebarActionCandidates -Failures $failures -Results $patchResults
    Test-PatchAnchorCompatibility -Path $IndexPath -Description "sidebar permanent delete menu insertion" -AlreadyPatchedNeedle "We,CodexRebuildDeleteActionV3,qe" -CandidateOldTexts $SidebarMenuCandidates -Failures $failures -Results $patchResults
    Test-PatchAnchorCompatibility -Path $DataControlsPath -Description "archived chats permanent delete button" -AlreadyPatchedNeedle "CodexRebuildDeleteArchivedV3" -CandidateOldTexts $ArchivedSettingsCandidates -Failures $failures -Results $patchResults

    if (Test-Path -LiteralPath $IndexPath -PathType Leaf) {
        $indexContent = Get-Content -LiteralPath $IndexPath -Raw -Encoding UTF8
        foreach ($needle in @("function r9", "zr=", "E.dispatchMessage")) {
            if (-not $indexContent.Contains($needle)) {
                Add-PrerequisiteFailure -Failures $failures -Message "Webview bundle no longer contains expected runtime marker '$needle'. Refusing true-delete patch: $IndexPath"
            }
        }
    }

    $sampleThreadId = $null
    if ($sqlite -and (Test-Path -LiteralPath $stateDb -PathType Leaf) -and (Test-Path -LiteralPath $skillScript -PathType Leaf) -and $failures.Count -eq 0) {
        try {
            $sample = @(Invoke-SqliteLines -Database $stateDb -Sql "SELECT id FROM threads ORDER BY updated_at_ms DESC, id DESC LIMIT 1;" -SqliteCommand $sqlite)
            if ($sample.Count -gt 0) {
                $sampleThreadId = $sample[0]
                $dryRunOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $skillScript -Id $sampleThreadId 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $tail = (($dryRunOutput | Select-Object -Last 20) -join " ")
                    Add-PrerequisiteFailure -Failures $failures -Message "Authoritative hard-delete script dry-run failed for sample thread $sampleThreadId. Output=$tail"
                }
            }
        } catch {
            Add-PrerequisiteFailure -Failures $failures -Message "Could not run hard-delete dry-run compatibility check: $($_.Exception.Message)"
        }
    }

    if ($failures.Count -gt 0) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("CodexRebuild true-delete prerequisite check failed.") | Out-Null
        $lines.Add("Current Codex session storage or UI flow may have changed; true-delete cannot be enabled safely.") | Out-Null
        $lines.Add("Do not run CodexRebuild-EnableTrueDelete-OneClick until the new version's session, archive, cache, and bundle flow is reviewed.") | Out-Null
        $lines.Add("") | Out-Null
        $lines.Add("Failed checks:") | Out-Null
        foreach ($failure in $failures) {
            $lines.Add("  - $failure") | Out-Null
        }
        throw ($lines -join [Environment]::NewLine)
    }

    Write-Host "True-delete prerequisite check passed."
    return [ordered]@{
        checkedAt = (Get-Date).ToString("o")
        codexRoot = $codexRoot
        stateDb = $stateDb
        logsDb = $logsDb
        sessionIndex = $sessionIndex
        hardDeleteScript = $skillScript
        sampleDryRunThreadId = $sampleThreadId
        patchAnchors = @($patchResults)
    }
}

function Write-HelperScript {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $BackupDir,
        [switch] $DryRun
    )

    $helper = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ThreadId,

    [switch] $Execute
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($ThreadId -notmatch '^[0-9A-Za-z-]{16,80}$') {
    throw "Refusing suspicious thread id: $ThreadId"
}

$homeDir = [Environment]::GetFolderPath("UserProfile")
$codexRoot = Join-Path $homeDir ".codex"
$skillScript = Join-Path $codexRoot "skills\junfu-delete-codex-session\scripts\remove-codex-session-hard.ps1"
if (-not (Test-Path -LiteralPath $skillScript -PathType Leaf)) {
    throw "Hard-delete helper was not found: $skillScript"
}

function Add-SqliteFallbackToPath {
    if (Get-Command sqlite3 -ErrorAction SilentlyContinue) {
        return
    }

    $candidatePaths = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:CONDA_PREFIX)) {
        $candidatePaths.Add((Join-Path $env:CONDA_PREFIX "Library\bin\sqlite3.exe")) | Out-Null
    }

    foreach ($root in @($env:ProgramData, $env:LOCALAPPDATA, $env:USERPROFILE, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }
        $candidatePaths.Add((Join-Path $root "miniconda3\Library\bin\sqlite3.exe")) | Out-Null
        $candidatePaths.Add((Join-Path $root "anaconda3\Library\bin\sqlite3.exe")) | Out-Null
        $candidatePaths.Add((Join-Path $root "SQLite\sqlite3.exe")) | Out-Null
    }

    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $env:PATH = (Split-Path -Parent $candidate) + [IO.Path]::PathSeparator + $env:PATH
            return
        }
    }
}

Add-SqliteFallbackToPath

function Invoke-SqliteScalar {
    param(
        [Parameter(Mandatory = $true)][string] $Database,
        [Parameter(Mandatory = $true)][string] $Sql
    )

    if (-not (Test-Path -LiteralPath $Database -PathType Leaf)) {
        return $null
    }

    $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if (-not $sqlite) {
        return $null
    }

    $result = & $sqlite.Source $Database $Sql 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    if ($null -eq $result) {
        return ""
    }

    return ([string]($result | Select-Object -First 1)).Trim()
}

function ConvertTo-SqlLiteral {
    param([Parameter(Mandatory = $true)][string] $Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function Test-ThreadExists {
    param([Parameter(Mandatory = $true)][string] $ThreadId)

    $stateDb = Join-Path $codexRoot "state_5.sqlite"
    $threadLiteral = ConvertTo-SqlLiteral -Value $ThreadId
    $countText = Invoke-SqliteScalar -Database $stateDb -Sql "SELECT COUNT(*) FROM threads WHERE id = $threadLiteral;"
    if ($null -eq $countText) {
        # If SQLite cannot be queried, let the authoritative hard-delete script decide.
        return $true
    }

    $count = 0
    if (-not [int]::TryParse($countText, [ref]$count)) {
        return $true
    }

    return $count -gt 0
}

if (-not (Test-ThreadExists -ThreadId $ThreadId)) {
    Write-Output "Thread does not exist; nothing to delete: $ThreadId"
    exit 0
}

$argsList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $skillScript, "-Id", $ThreadId)
if ($Execute) {
    $argsList += "-Execute"
}

$output = & powershell.exe @argsList 2>&1
$exit = $LASTEXITCODE
$output | Write-Output
if ($exit -ne 0) {
    exit $exit
}

if (-not $Execute) {
    exit 0
}

function Remove-ItemsNamedForThread {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $ThreadId
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return
    }

    $matches = @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name.IndexOf($ThreadId, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 } |
            Sort-Object FullName -Descending
    )

    foreach ($item in $matches) {
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse:$item.PSIsContainer -Force -ErrorAction Stop
            Write-Output "Removed leftover item: $($item.FullName)"
        } catch {
            Write-Output "Skipping leftover item that could not be removed: $($item.FullName) | $($_.Exception.Message)"
        }
    }
}

function Remove-EmptyDirectories {
    param([Parameter(Mandatory = $true)][string] $Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return
    }

    $dirs = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -Directory -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
    foreach ($dir in $dirs) {
        try {
            $children = @(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction Stop)
            if ($children.Count -eq 0) {
                Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop
                Write-Output "Removed empty directory: $($dir.FullName)"
            }
        } catch {
            Write-Output "Skipping directory cleanup: $($dir.FullName) | $($_.Exception.Message)"
        }
    }
}

$safeCleanupRoots = @(
    (Join-Path $codexRoot "sessions"),
    (Join-Path $codexRoot "archived_sessions"),
    (Join-Path $codexRoot "tmp"),
    (Join-Path $codexRoot ".tmp"),
    (Join-Path $codexRoot "log")
)

foreach ($root in $safeCleanupRoots) {
    Remove-ItemsNamedForThread -Root $root -ThreadId $ThreadId
}

Remove-EmptyDirectories -Root (Join-Path $codexRoot "sessions")
Remove-EmptyDirectories -Root (Join-Path $codexRoot "archived_sessions")
'@

    $current = if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    } else {
        $null
    }

    if ($current -eq $helper) {
        Write-Host "Already current: hard-delete helper"
        return "already-current"
    }

    Write-Host "$(if ($DryRun) { 'Would write' } else { 'Writing' }): hard-delete helper"
    if ($DryRun) {
        return "would-write"
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Backup-FileOnce -Path $Path -BackupDir $BackupDir
    }
    Set-Content -LiteralPath $Path -Value $helper -Encoding UTF8 -NoNewline
    return "written"
}

function Assert-Patched {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string[]] $Needles
    )

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    foreach ($needle in $Needles) {
        if (-not $content.Contains($needle)) {
            throw "Verification failed. Missing '$needle' in $Path"
        }
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
    throw "Missing webview preparation script: $prepareScript"
}

$prepareArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $prepareScript, "-Root", $rootPath, "-AppRoot", $appRootPath)
if ($StopRunningRebuild) {
    $prepareArgs += "-StopRunningRebuild"
}
if ($DryRun) {
    $prepareArgs += "-DryRun"
}

& powershell.exe @prepareArgs
if ($LASTEXITCODE -ne 0) {
    throw "Webview preparation failed with exit code $LASTEXITCODE"
}

$resourcesRoot = Join-Path $appRootPath "resources"
$unpackedAppDir = Join-Path $resourcesRoot "app"
$buildDir = Join-Path $unpackedAppDir ".vite\build"
$assetsDir = Join-Path $unpackedAppDir "webview\assets"
$helperPath = Join-Path $resourcesRoot "CodexRebuild-HardDeleteSession.ps1"
$backupRoot = Join-Path $rootPath "true-delete-backup"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $backupRoot $stamp
$manifestPath = Join-Path $resourcesRoot "true-delete-manifest.json"

if ($DryRun) {
    Write-Host "Would resolve and patch true-delete files after webview preparation."
    exit 0
}

if (-not (Test-Path -LiteralPath $unpackedAppDir -PathType Container)) {
    throw "Missing extracted webview app after preparation: $unpackedAppDir"
}
if (-not (Test-Path -LiteralPath $buildDir -PathType Container)) {
    throw "Missing Electron build directory: $buildDir"
}
if (-not (Test-Path -LiteralPath $assetsDir -PathType Container)) {
    throw "Missing webview assets directory: $assetsDir"
}

$mainPath = Get-SingleFile -Directory $buildDir -Filter "main-*.js" -Description "Electron main bundle"
$indexPath = Get-SingleFile -Directory $assetsDir -Filter "index-*.js" -Description "webview index bundle"
$dataControlsPath = Get-SingleFile -Directory $assetsDir -Filter "data-controls-*.js" -Description "data controls bundle"

$mainOld = @'
case`archive-thread`:this.getAppServerConnection(i.hostId).registerArchiveThread(i.conversationId,{cwd:i.cwd,cleanupWorktree:i.cleanupWorktree,replacementOwnerThreadId:i.replacementOwnerThreadId,replacementOwnerCwd:i.replacementOwnerCwd});break;
'@
$mainNew = @'
case`hard-delete-thread`:{let e=i.conversationId;if(typeof e!==`string`||e.trim().length===0)throw Error(`Missing conversationId for hard delete`);let t=require(`node:path`),n=require(`node:os`),r=require(`node:fs`),a=require(`node:child_process`),o=t.join(process.resourcesPath||process.cwd(),`CodexRebuild-HardDeleteSession.ps1`),s=r.existsSync(o),c=s?o:t.join(n.homedir(),`.codex`,`skills`,`junfu-delete-codex-session`,`scripts`,`remove-codex-session-hard.ps1`);if(!r.existsSync(c))throw Error(`Hard delete helper not found: ${c}`);let l=s?[`-ThreadId`,e,`-Execute`]:[`-Id`,e,`-Execute`];await new Promise((e,t)=>{let n=a.spawn(`powershell.exe`,[`-NoProfile`,`-ExecutionPolicy`,`Bypass`,`-File`,c,...l],{windowsHide:!0}),r=``,i=``;n.stdout&&n.stdout.on(`data`,e=>{r+=String(e)}),n.stderr&&n.stderr.on(`data`,e=>{i+=String(e)}),n.on(`error`,t),n.on(`close`,n=>{n===0?e({stdout:r,stderr:i}):t(Error(`Hard delete failed with exit code ${n}: ${(i||r).slice(-4000)}`))})});break}case`archive-thread`:this.getAppServerConnection(i.hostId).registerArchiveThread(i.conversationId,{cwd:i.cwd,cleanupWorktree:i.cleanupWorktree,replacementOwnerThreadId:i.replacementOwnerThreadId,replacementOwnerCwd:i.replacementOwnerCwd});break;
'@

$indexHandlerOld = @'
"archive-conversation":t9(async(e,{conversationId:t,cleanupWorktree:n})=>{await e.archiveConversation(t,{cleanupWorktree:n})}),
'@
$indexHandlerV2 = @'
"hard-delete-conversation":async(e,{hostId:t,conversationId:n})=>{let CodexRebuildHardDeleteV2=!0,r=t!=null?r9(e,t):zr(e,n);if(r==null)throw Error(`No AppServerManager registered for hard delete target`);let i=window.electronBridge?.sendMessageFromView;if(!i)throw Error(`CodexRebuild hard delete requires Electron bridge`);await i({type:`hard-delete-thread`,hostId:r.hostId,conversationId:n});r.removeConversationFromCache(n),E.dispatchMessage(`thread-archived`,{hostId:r.hostId,conversationId:n}),E.dispatchMessage(`query-cache-invalidate`,{queryKey:[`archived-threads`,r.hostId]})}
'@
$indexHandlerNew = @'
"archive-conversation":t9(async(e,{conversationId:t,cleanupWorktree:n})=>{await e.archiveConversation(t,{cleanupWorktree:n})}),"hard-delete-conversation":async(e,{hostId:t,conversationId:n})=>{let CodexRebuildHardDeleteV2=!0,r=t!=null?r9(e,t):zr(e,n);if(r==null)throw Error(`No AppServerManager registered for hard delete target`);let i=window.electronBridge?.sendMessageFromView;if(!i)throw Error(`CodexRebuild hard delete requires Electron bridge`);await i({type:`hard-delete-thread`,hostId:r.hostId,conversationId:n});r.removeConversationFromCache(n),E.dispatchMessage(`thread-archived`,{hostId:r.hostId,conversationId:n}),E.dispatchMessage(`query-cache-invalidate`,{queryKey:[`archived-threads`,r.hostId]})},
'@

$sidebarActionOld = @'
let Ue;t[63]===Le?Ue=t[64]:(Ue={id:`rename-thread`,message:Zw.renameThread,onSelect:Le},t[63]=Le,t[64]=Ue);let We;t[65]===Ne?We=t[66]:(We={id:`archive-thread`,message:Zw.archiveThread,onSelect:Ne},t[65]=Ne,t[66]=We);let Ge=y!==!0
'@
$sidebarActionNew = @'
let Ue;t[63]===Le?Ue=t[64]:(Ue={id:`rename-thread`,message:Zw.renameThread,onSelect:Le},t[63]=Le,t[64]=Ue);let We;t[65]===Ne?We=t[66]:(We={id:`archive-thread`,message:Zw.archiveThread,onSelect:Ne},t[65]=Ne,t[66]=We);let CodexRebuildDeleteActionV3={id:`codexrebuild-hard-delete-thread`,message:{id:`sidebarElectron.hardDeleteThread`,defaultMessage:`Delete chat permanently`,description:`Menu item to permanently delete a local thread`},onSelect:()=>{window.confirm(`Delete this chat permanently? This cannot be undone.`)&&ri(`hard-delete-conversation`,{hostId:b??me,conversationId:n}).then(()=>{q&&o?.(),m.get(wg).success(`\u5df2\u5220\u9664\u4f1a\u8bdd\u3002\u8bf7\u91cd\u542f Codex \u5e94\u7528\u7a0b\u5e8f\u4ee5\u5237\u65b0\u4f1a\u8bdd\u5217\u8868\u3002`)}).catch(e=>{m.get(wg).danger(`Failed to delete chat: ${e instanceof Error?e.message:String(e)}`)})}};let Ge=y!==!0
'@

$sidebarMenuOld = @'
Je=[...He,Ue,We,qe,...zE({canToggleActiveStatus:ve,scope:m,showActiveStatus:w}),e,...r,o,s,c,...l,...u]
'@
$sidebarMenuNew = @'
Je=[...He,Ue,We,CodexRebuildDeleteActionV3,qe,...zE({canToggleActiveStatus:ve,scope:m,showActiveStatus:w}),e,...r,o,s,c,...l,...u]
'@

$dataControlsOld = @'
let H;t[58]===k?H=t[59]:(H=()=>{k.isPending||k.mutate()},t[58]=k,t[59]=H);let U;t[60]===Symbol.for(`react.memo_cache_sentinel`)?(U=(0,D.jsx)(p,{id:`settings.dataControls.archivedChats.unarchive`,defaultMessage:`Unarchive`,description:`Button label to unarchive a chat`}),t[60]=U):U=t[60];let W;t[61]!==H||t[62]!==k.isPending?(W=(0,D.jsx)(m,{className:`shrink-0`,color:`secondary`,size:`toolbar`,disabled:k.isPending,loading:k.isPending,onClick:H,children:U}),t[61]=H,t[62]=k.isPending,t[63]=W):W=t[63];let G;return t[64]!==V||t[65]!==W?(G=(0,D.jsxs)(`div`,{className:`flex w-full items-center justify-between gap-3 px-4 py-3 hover:bg-token-list-hover-background`,children:[V,W]}),t[64]=V,t[65]=W,t[66]=G):G=t[66],G
'@
$dataControlsNew = @'
let H;t[58]===k?H=t[59]:(H=()=>{k.isPending||k.mutate()},t[58]=k,t[59]=H);let CodexRebuildDeleteArchivedV3=()=>{k.isPending||window.confirm(`Delete this archived chat permanently? This cannot be undone.`)&&d(`hard-delete-conversation`,{hostId:o,conversationId:a}).then(()=>{f.setQueryData([`archived-threads`,o],(f.getQueryData([`archived-threads`,o])??[]).filter(e=>e.id!==i.id)),g.get(_).success(`\u5df2\u5220\u9664\u4f1a\u8bdd\u3002\u8bf7\u91cd\u542f Codex \u5e94\u7528\u7a0b\u5e8f\u4ee5\u5237\u65b0\u4f1a\u8bdd\u5217\u8868\u3002`)}).catch(e=>{g.get(_).danger(`Failed to delete chat: ${e instanceof Error?e.message:String(e)}`)})};let U;t[60]===Symbol.for(`react.memo_cache_sentinel`)?(U=(0,D.jsx)(p,{id:`settings.dataControls.archivedChats.unarchive`,defaultMessage:`Unarchive`,description:`Button label to unarchive a chat`}),t[60]=U):U=t[60];let W;t[61]!==H||t[62]!==k.isPending?(W=(0,D.jsx)(m,{className:`shrink-0`,color:`secondary`,size:`toolbar`,disabled:k.isPending,loading:k.isPending,onClick:H,children:U}),t[61]=H,t[62]=k.isPending,t[63]=W):W=t[63];let CodexRebuildDeleteLabel=(0,D.jsx)(p,{id:`settings.dataControls.archivedChats.delete`,defaultMessage:`Delete`,description:`Button label to permanently delete an archived chat`}),CodexRebuildDeleteButton=(0,D.jsx)(m,{className:`shrink-0`,color:`secondary`,size:`toolbar`,disabled:k.isPending,onClick:CodexRebuildDeleteArchivedV3,children:CodexRebuildDeleteLabel});return(0,D.jsxs)(`div`,{className:`flex w-full items-center justify-between gap-3 px-4 py-3 hover:bg-token-list-hover-background`,children:[V,(0,D.jsxs)(`div`,{className:`flex shrink-0 gap-2`,children:[W,CodexRebuildDeleteButton]})]})
'@

$prerequisiteState = Assert-TrueDeletePrerequisites `
    -RootPath $rootPath `
    -AppRootPath $appRootPath `
    -ResourcesRoot $resourcesRoot `
    -MainPath $mainPath `
    -IndexPath $indexPath `
    -DataControlsPath $dataControlsPath `
    -MainOld $mainOld `
    -IndexHandlerCandidates @($indexHandlerOld) `
    -SidebarActionCandidates @($sidebarActionOld) `
    -SidebarMenuCandidates @($sidebarMenuOld) `
    -ArchivedSettingsCandidates @($dataControlsOld)

$states = [ordered]@{}
$states.helper = Write-HelperScript -Path $helperPath -BackupDir $backupDir
$states.mainHandler = Replace-LiteralOnce -Path $mainPath -Old $mainOld -New $mainNew -AlreadyPatchedNeedle "CodexRebuild-HardDeleteSession.ps1" -Description "Electron hard-delete handler" -BackupDir $backupDir
$states.indexHandler = Replace-LiteralMapOnce -Path $indexPath -Replacements @(
    [pscustomobject]@{ Old = $indexHandlerOld; New = $indexHandlerNew }
) -AlreadyPatchedNeedle "CodexRebuildHardDeleteV2" -Description "webview hard-delete conversation handler" -BackupDir $backupDir
$states.sidebarAction = Replace-LiteralMapOnce -Path $indexPath -Replacements @(
    [pscustomobject]@{ Old = $sidebarActionOld; New = $sidebarActionNew }
) -AlreadyPatchedNeedle "CodexRebuildDeleteActionV3" -Description "sidebar permanent delete menu action" -BackupDir $backupDir
$states.sidebarMenu = Replace-LiteralMapOnce -Path $indexPath -Replacements @(
    [pscustomobject]@{ Old = $sidebarMenuOld; New = $sidebarMenuNew }
) -AlreadyPatchedNeedle "We,CodexRebuildDeleteActionV3,qe" -Description "sidebar permanent delete menu insertion" -BackupDir $backupDir
$states.archivedSettings = Replace-LiteralMapOnce -Path $dataControlsPath -Replacements @(
    [pscustomobject]@{ Old = $dataControlsOld; New = $dataControlsNew }
) -AlreadyPatchedNeedle "CodexRebuildDeleteArchivedV3" -Description "archived chats permanent delete button" -BackupDir $backupDir

Assert-Patched -Path $mainPath -Needles @('case`hard-delete-thread`', "CodexRebuild-HardDeleteSession.ps1")
Assert-Patched -Path $indexPath -Needles @("hard-delete-conversation", "CodexRebuildHardDeleteV2", "CodexRebuildDeleteActionV3", "We,CodexRebuildDeleteActionV3,qe", "\u8bf7\u91cd\u542f Codex")
Assert-Patched -Path $dataControlsPath -Needles @("CodexRebuildDeleteArchivedV3", "settings.dataControls.archivedChats.delete", "\u8bf7\u91cd\u542f Codex")
Assert-Patched -Path $helperPath -Needles @("remove-codex-session-hard.ps1", "Test-ThreadExists", "Thread does not exist; nothing to delete", "Remove-EmptyDirectories")

$manifest = [ordered]@{
    enabledAt = (Get-Date).ToString("o")
    root = $rootPath
    appRoot = $appRootPath
    resourcesRoot = $resourcesRoot
    helper = $helperPath
    mainBundle = $mainPath
    indexBundle = $indexPath
    dataControlsBundle = $dataControlsPath
    backupDir = if (Test-Path -LiteralPath $backupDir -PathType Container) { $backupDir } else { $null }
    prerequisiteState = $prerequisiteState
    patchState = $states
    prepareManifest = (Join-Path $resourcesRoot "webview-patch-manifest.json")
}
$manifest | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $manifestPath -Encoding UTF8

Write-Host "True delete patch applied."
Write-Host "Main:     $mainPath"
Write-Host "Index:    $indexPath"
Write-Host "Settings: $dataControlsPath"
Write-Host "Helper:   $helperPath"
Write-Host "Manifest: $manifestPath"
if (Test-Path -LiteralPath $backupDir -PathType Container) {
    Write-Host "Backup:   $backupDir"
} else {
    Write-Host "Backup:   <not needed>"
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
