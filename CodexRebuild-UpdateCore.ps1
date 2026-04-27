[CmdletBinding()]
param(
    [string] $Root,

    [string] $SourcePath,

    [string] $PackageName = "OpenAI.Codex",

    [string] $WindowsAppsRoot,

    [switch] $StopRunningRebuild,

    [switch] $NoShortcut,

    [switch] $NoSmokeTest,

    [switch] $DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$corePackageStem = "codex-x86_64-pc-windows-msvc.exe"
$temporaryCoreExtractionRoot = $null

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

function Find-CoreDirectoryWithin {
    param([Parameter(Mandatory = $true)][string] $Directory)

    if (Test-CoreDirectory -Directory $Directory) {
        return (Get-Item -LiteralPath $Directory -ErrorAction Stop).FullName
    }

    $matches = @(Get-ChildItem -LiteralPath $Directory -Directory -Recurse -ErrorAction Stop |
        Where-Object { Test-CoreDirectory -Directory $_.FullName } |
        Sort-Object FullName)

    if ($matches.Count -eq 0) {
        throw "No valid Codex core directory found under: $Directory"
    }

    if ($matches.Count -gt 1) {
        Write-Warning "Multiple valid core directories found. Using the first one:"
        $matches | Select-Object FullName | Format-Table -AutoSize | Out-String | Write-Host
    }

    return $matches[0].FullName
}

function Resolve-CoreCandidate {
    param(
        [Parameter(Mandatory = $true)][string] $RootPath,
        [string] $Path
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        return [pscustomobject]@{
            Path = $item.FullName
            Type = if ($item.PSIsContainer) { "Directory" } else { "Zip" }
            LastWriteTime = $item.LastWriteTime
            Source = "parameter"
        }
    }

    $directoryCandidates = @(Get-ChildItem -LiteralPath $RootPath -Directory -ErrorAction Stop |
        Where-Object { $_.Name -like "$corePackageStem*" } |
        ForEach-Object {
            [pscustomobject]@{
                Path = $_.FullName
                Type = "Directory"
                LastWriteTime = $_.LastWriteTime
                Source = "current folder"
            }
        })

    $zipCandidates = @(Get-ChildItem -LiteralPath $RootPath -File -ErrorAction Stop |
        Where-Object { $_.Name -like "$corePackageStem*.zip" } |
        ForEach-Object {
            [pscustomobject]@{
                Path = $_.FullName
                Type = "Zip"
                LastWriteTime = $_.LastWriteTime
                Source = "current folder"
            }
        })

    $candidates = @($directoryCandidates + $zipCandidates | Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) {
        Write-Host "No Codex core release package was found in:"
        Write-Host "  $RootPath"
        Write-Host ""
        Write-Host "Download the latest $corePackageStem.zip from:"
        Write-Host "  https://github.com/openai/codex/releases"
        Write-Host ""
        Write-Host "Put the zip file in the current script directory, then run again:"
        Write-Host "  $RootPath"
        Write-Host ""
        Write-Host "Accepted local package names:"
        Write-Host "  $corePackageStem*"
        Write-Host "  $corePackageStem*.zip"
        Write-Host ""
        Write-Host "Or pass -SourcePath '<release-folder-or-zip>'."
        exit 1
    }

    Write-Host "Core package candidates:"
    $candidates | Select-Object Type, LastWriteTime, Path | Format-Table -AutoSize | Out-String | Write-Host

    return $candidates[0]
}

function Expand-CoreCandidateIfNeeded {
    param(
        [Parameter(Mandatory = $true)][object] $Candidate,
        [Parameter(Mandatory = $true)][string] $RootPath,
        [switch] $DryRun
    )

    if ($Candidate.Type -eq "Directory") {
        return [pscustomobject]@{
            CoreDir = Find-CoreDirectoryWithin -Directory $Candidate.Path
            TemporaryRoot = $null
        }
    }

    if ($Candidate.Type -ne "Zip") {
        throw "Unsupported core candidate type: $($Candidate.Type)"
    }

    if (-not ($Candidate.Path -match '\.zip$')) {
        throw "SourcePath must be a directory or .zip archive: $($Candidate.Path)"
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    if ($DryRun) {
        $extractBase = Join-Path ([System.IO.Path]::GetTempPath()) "CodexRebuild-CoreDryRun"
        $extractRoot = Join-Path $extractBase "core-$stamp"
    } else {
        $extractRoot = Join-Path (Join-Path $RootPath ".core-staging") "core-$stamp"
    }
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null

    Write-Host "Extracting core archive:"
    Write-Host "  zip:  $($Candidate.Path)"
    Write-Host "  dest: $extractRoot"
    if ($DryRun) {
        Write-Host "  mode: temporary dry-run validation; this directory will be removed"
    }
    Expand-Archive -LiteralPath $Candidate.Path -DestinationPath $extractRoot -Force

    return [pscustomobject]@{
        CoreDir = Find-CoreDirectoryWithin -Directory $extractRoot
        TemporaryRoot = if ($DryRun) { $extractRoot } else { $null }
    }
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

function Assert-CoreVersion {
    param([Parameter(Mandatory = $true)][string] $CodexExePath)

    $output = & $CodexExePath --version 2>&1
    $exit = $LASTEXITCODE
    $text = ($output | Out-String).Trim()
    if ($exit -ne 0 -or $text -notmatch '^codex-cli\s+') {
        throw "Core codex executable did not report a valid version. Exit=$exit Output='$text'"
    }

    return $text
}

function Install-CoreFiles {
    param(
        [Parameter(Mandatory = $true)][string] $RootPath,
        [Parameter(Mandatory = $true)][object[]] $Files,
        [Parameter(Mandatory = $true)][string] $VersionOutput,
        [switch] $DryRun
    )

    $coreDir = Join-Path $RootPath "Core"
    if ($DryRun) {
        Write-Host "Dry-run: would replace Core at $coreDir with the selected core source."
        return $coreDir
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $installStageRoot = Join-Path $RootPath ".core-install-staging"
    $installStage = Join-Path $installStageRoot "Core-$stamp"
    if (Test-Path -LiteralPath $installStage) {
        throw "Core install staging directory already exists: $installStage"
    }

    New-Item -ItemType Directory -Path $installStage -Force | Out-Null
    foreach ($file in $Files) {
        Copy-Item -LiteralPath $file.SourcePath -Destination (Join-Path $installStage $file.Target) -Force
    }

    $manifest = [ordered]@{
        installedAt = (Get-Date).ToString("o")
        versionOutput = $VersionOutput
        files = @($Files | ForEach-Object {
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
    $manifest | ConvertTo-Json -Depth 6 | Out-File -LiteralPath (Join-Path $installStage "codex-core-manifest.json") -Encoding UTF8

    if (Test-Path -LiteralPath $coreDir -PathType Container) {
        $archiveRoot = Join-Path $RootPath "core-archive"
        New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
        $archivePath = Join-Path $archiveRoot "Core-previous-$stamp"
        Move-Item -LiteralPath $coreDir -Destination $archivePath -Force
        Write-Host "Archived previous Core: $archivePath"
    }

    Move-Item -LiteralPath $installStage -Destination $coreDir -Force

    return $coreDir
}

$rootPath = Resolve-RootPath -Path $Root
if ([string]::IsNullOrWhiteSpace($WindowsAppsRoot) -and -not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
    $WindowsAppsRoot = Join-Path $env:ProgramFiles "WindowsApps"
}

try {
    $candidate = Resolve-CoreCandidate -RootPath $rootPath -Path $SourcePath
    $resolvedCore = Expand-CoreCandidateIfNeeded -Candidate $candidate -RootPath $rootPath -DryRun:$DryRun
    $temporaryCoreExtractionRoot = $resolvedCore.TemporaryRoot
    $coreSourceDir = $resolvedCore.CoreDir
    $coreFiles = @(Get-CoreFiles -Directory $coreSourceDir)
    $versionOutput = Assert-CoreVersion -CodexExePath (($coreFiles | Where-Object { $_.Role -eq "codex cli" } | Select-Object -First 1).SourcePath)

    Write-Host ""
    Write-Host "Selected core source: $coreSourceDir [$($candidate.Source), $($candidate.Type)]"
    Write-Host "Version: $versionOutput"
    $coreFiles | Select-Object Role, Length, ProductVersion, Sha256, SourcePath | Format-Table -AutoSize | Out-String | Write-Host

    $installedCore = Install-CoreFiles -RootPath $rootPath -Files $coreFiles -VersionOutput $versionOutput -DryRun:$DryRun
    $coreDirForRebuild = if ($DryRun) { $coreSourceDir } else { $installedCore }

    $rebuildScript = Join-Path $rootPath "CodexRebuild-Rebuild.ps1"
    if (-not (Test-Path -LiteralPath $rebuildScript -PathType Leaf)) {
        throw "Missing rebuild script: $rebuildScript"
    }

    $rebuildArgs = @("-Root", $rootPath, "-CoreDir", $coreDirForRebuild, "-PackageName", $PackageName)
    if (-not [string]::IsNullOrWhiteSpace($WindowsAppsRoot)) {
        $rebuildArgs += @("-WindowsAppsRoot", $WindowsAppsRoot)
    }
    if ($StopRunningRebuild) {
        $rebuildArgs += "-StopRunningRebuild"
    }
    if ($NoShortcut) {
        $rebuildArgs += "-NoShortcut"
    }
    if ($DryRun) {
        $rebuildArgs += "-DryRun"
    }

    & powershell -NoProfile -ExecutionPolicy Bypass -File $rebuildScript @rebuildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Rebuild script failed with exit code $LASTEXITCODE"
    }

    if ($DryRun -or $NoSmokeTest) {
        exit 0
    }

    $testScript = Join-Path $rootPath "CodexRebuild-Test.ps1"
    if (-not (Test-Path -LiteralPath $testScript -PathType Leaf)) {
        throw "Missing smoke test script: $testScript"
    }

    & powershell -NoProfile -ExecutionPolicy Bypass -File $testScript -Root $rootPath -StopExisting
    if ($LASTEXITCODE -ne 0) {
        throw "Smoke test script failed with exit code $LASTEXITCODE"
    }
} finally {
    if ($temporaryCoreExtractionRoot -and (Test-Path -LiteralPath $temporaryCoreExtractionRoot -PathType Container)) {
        $temporaryCoreExtractionParent = Split-Path -Parent $temporaryCoreExtractionRoot
        Remove-Item -LiteralPath $temporaryCoreExtractionRoot -Recurse -Force -ErrorAction SilentlyContinue
        if ($temporaryCoreExtractionParent -and
            (Split-Path -Leaf $temporaryCoreExtractionParent) -eq "CodexRebuild-CoreDryRun" -and
            (Test-Path -LiteralPath $temporaryCoreExtractionParent -PathType Container) -and
            -not @(Get-ChildItem -LiteralPath $temporaryCoreExtractionParent -Force -ErrorAction SilentlyContinue).Count) {
            Remove-Item -LiteralPath $temporaryCoreExtractionParent -Force -ErrorAction SilentlyContinue
        }
    }
}
