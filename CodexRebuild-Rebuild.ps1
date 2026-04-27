[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $CoreDir,

    [string] $Root,

    [string] $DestinationName = "Codex",

    [string] $PackageName = "OpenAI.Codex",

    [string] $WindowsAppsRoot,

    [switch] $StopRunningRebuild,

    [switch] $NoShortcut,

    [switch] $NoCoreReplacement,

    [switch] $SkipRuntimeValidation,

    [switch] $DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-ExistingDirectory {
    param([Parameter(Mandatory = $true)][string] $Path)

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolved.Path -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw "Not a directory: $Path"
    }

    return $item.FullName
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-FileSummary {
    param([Parameter(Mandatory = $true)][string] $Path)

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    [pscustomobject]@{
        Path = $item.FullName
        Length = $item.Length
        ProductVersion = $item.VersionInfo.ProductVersion
        LastWriteTime = $item.LastWriteTime
        Sha256 = Get-Sha256 -Path $item.FullName
    }
}

function Find-SourceFile {
    param(
        [Parameter(Mandatory = $true)][string] $Directory,
        [Parameter(Mandatory = $true)][string[]] $Candidates
    )

    foreach ($name in $Candidates) {
        $path = Join-Path $Directory $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return (Get-Item -LiteralPath $path).FullName
        }
    }

    throw "Missing source file. Looked for: $($Candidates -join ', ') in $Directory"
}

function Test-CoreDirectory {
    param([Parameter(Mandatory = $true)][string] $Directory)

    $required = @(
        @("codex-x86_64-pc-windows-msvc.exe", "codex.exe"),
        @("codex-command-runner.exe", "codex-command-runner-x86_64-pc-windows-msvc.exe"),
        @("codex-windows-sandbox-setup.exe", "codex-windows-sandbox-setup-x86_64-pc-windows-msvc.exe")
    )

    foreach ($group in $required) {
        $found = $false
        foreach ($candidate in $group) {
            if (Test-Path -LiteralPath (Join-Path $Directory $candidate) -PathType Leaf) {
                $found = $true
                break
            }
        }

        if (-not $found) {
            return $false
        }
    }

    return $true
}

function Resolve-CoreDirectory {
    param(
        [string] $CoreDir,
        [Parameter(Mandatory = $true)][string] $Root,
        [switch] $NoCoreReplacement
    )

    if ($NoCoreReplacement) {
        return [pscustomobject]@{ Path = $null; Source = "Store bundled core files"; ReplacementEnabled = $false }
    }

    if ($CoreDir) {
        $resolved = Resolve-ExistingDirectory -Path $CoreDir
        if (-not (Test-CoreDirectory -Directory $resolved)) {
            throw "CoreDir does not contain the required Codex core files: $resolved"
        }
        return [pscustomobject]@{ Path = $resolved; Source = "parameter" }
    }

    $localCore = Join-Path $Root "Core"
    if ((Test-Path -LiteralPath $localCore -PathType Container) -and (Test-CoreDirectory -Directory $localCore)) {
        return [pscustomobject]@{ Path = (Resolve-ExistingDirectory -Path $localCore); Source = "local Core folder" }
    }

    return [pscustomobject]@{ Path = $null; Source = "Store bundled core files"; ReplacementEnabled = $false }
}

function Resolve-CodexPackage {
    param(
        [Parameter(Mandatory = $true)][string] $PackageName,
        [Parameter(Mandatory = $true)][string] $WindowsAppsRoot
    )

    $package = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue |
        Where-Object { $_.InstallLocation } |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($package) {
        return [pscustomobject]@{
            InstallLocation = $package.InstallLocation
            PackageFullName = $package.PackageFullName
            Version = $package.Version.ToString()
            Source = "Get-AppxPackage"
        }
    }

    $escapedPackageName = [regex]::Escape($PackageName)
    $candidate = Get-ChildItem -LiteralPath $WindowsAppsRoot -Directory -Filter "$PackageName`_*" -ErrorAction Stop |
        ForEach-Object {
            $version = [version]"0.0"
            if ($_.Name -match "^${escapedPackageName}_(?<Version>[0-9]+(?:\.[0-9]+)+)_") {
                $version = [version]$Matches.Version
            }

            [pscustomobject]@{
                InstallLocation = $_.FullName
                PackageFullName = $_.Name
                Version = $version
                HasApp = (Test-Path -LiteralPath (Join-Path $_.FullName "app\Codex.exe") -PathType Leaf)
            }
        } |
        Where-Object { $_.HasApp } |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($candidate) {
        return [pscustomobject]@{
            InstallLocation = $candidate.InstallLocation
            PackageFullName = $candidate.PackageFullName
            Version = $candidate.Version.ToString()
            Source = "WindowsApps scan"
        }
    }

    throw "$PackageName package was not found."
}

function Invoke-Robocopy {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination,
        [string[]] $ExcludeDirectories = @(),
        [string[]] $ExcludeFiles = @(),
        [string] $LogPath
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $args = @($Source, $Destination, "/MIR", "/COPY:DAT", "/DCOPY:DAT", "/R:2", "/W:1", "/NP")
    if ($ExcludeDirectories.Count -gt 0) {
        $args += "/XD"
        $args += $ExcludeDirectories
    }
    if ($ExcludeFiles.Count -gt 0) {
        $args += "/XF"
        $args += $ExcludeFiles
    }
    if ($LogPath) {
        $args += "/LOG:$LogPath"
    }

    $robocopyOutput = & robocopy.exe @args 2>&1
    $exit = $LASTEXITCODE
    if (-not $LogPath -and $robocopyOutput) {
        $robocopyOutput | Write-Host
    }
    if ($exit -gt 7) {
        if ($LogPath -and (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
            Write-Warning "robocopy failed. Tail of log:"
            Get-Content -LiteralPath $LogPath -Tail 80 | Write-Host
        }
        throw "robocopy failed with exit code $exit"
    }

    return $exit
}

function Test-RebuildRuntimeFiles {
    param([Parameter(Mandatory = $true)][string] $ResourcesRoot)

    $checks = @(
        [pscustomobject]@{
            Name = "better-sqlite3 native module"
            RelativePath = "app.asar.unpacked\node_modules\better-sqlite3\build\Release\better_sqlite3.node"
            MinLength = 1000000
        },
        [pscustomobject]@{
            Name = "node-pty pty native module"
            RelativePath = "app.asar.unpacked\node_modules\node-pty\prebuilds\win32-x64\pty.node"
            MinLength = 100000
        },
        [pscustomobject]@{
            Name = "node-pty conpty native module"
            RelativePath = "app.asar.unpacked\node_modules\node-pty\prebuilds\win32-x64\conpty.node"
            MinLength = 100000
        },
        [pscustomobject]@{
            Name = "bundled Browser Use skill"
            RelativePath = "plugins\openai-bundled\plugins\browser-use\skills\browser\SKILL.md"
            MinLength = 1000
        }
    )

    foreach ($check in $checks) {
        $path = Join-Path $ResourcesRoot $check.RelativePath
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        $length = if ($item) { $item.Length } else { 0 }
        [pscustomobject]@{
            Name = $check.Name
            RelativePath = $check.RelativePath
            Path = $path
            Exists = [bool]$item
            Length = $length
            MinLength = $check.MinLength
            Ok = ([bool]$item -and $length -ge $check.MinLength)
        }
    }
}

function Assert-RebuildRuntimeFiles {
    param([Parameter(Mandatory = $true)][string] $ResourcesRoot)

    $results = @(Test-RebuildRuntimeFiles -ResourcesRoot $ResourcesRoot)
    $failed = @($results | Where-Object { -not $_.Ok })
    if ($failed.Count -gt 0) {
        Write-Warning "Runtime validation failed:"
        $failed | Select-Object Name, RelativePath, Exists, Length, MinLength | Format-Table -AutoSize | Out-String | Write-Host
        throw "Rebuilt copy is missing required Electron runtime files. Refusing to switch a startup-broken copy into place."
    }

    Write-Host "Runtime validation passed:"
    $results | Select-Object Name, Length, RelativePath | Format-Table -AutoSize | Out-String | Write-Host
    return $results
}

function Get-RebuildProcesses {
    param([Parameter(Mandatory = $true)][string] $DestinationRoot)

    $appRoot = Join-Path $DestinationRoot "app"
    Get-CimInstance Win32_Process |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -like "$appRoot\*" } |
        Select-Object ProcessId, Name, ExecutablePath
}

function New-DesktopShortcut {
    param(
        [Parameter(Mandatory = $true)][string] $TargetPath,
        [Parameter(Mandatory = $true)][string] $WorkingDirectory,
        [Parameter(Mandatory = $true)][string] $IconPath
    )

    $shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "CodexRebuild.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = ""
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.IconLocation = "$IconPath,0"
    $shortcut.Description = "CodexRebuild writable Codex desktop copy"
    $shortcut.Save()

    return $shortcutPath
}

function New-LaunchScript {
    param(
        [Parameter(Mandatory = $true)][string] $RootPath,
        [Parameter(Mandatory = $true)][string] $TargetPath,
        [Parameter(Mandatory = $true)][string] $WorkingDirectory,
        [Parameter(Mandatory = $true)][string] $UserDataDir
    )

    $launcherPath = Join-Path $RootPath "CodexRebuild-Launch.cmd"
    $content = @(
        "@echo off",
        "setlocal",
        "set `"ROOT=%~dp0`"",
        "if `"%ROOT:~-1%`"==`"\`" set `"ROOT=%ROOT:~0,-1%`"",
        "set `"APPDIR=%ROOT%\Codex\app`"",
        "if not exist `"%APPDIR%\Codex.exe`" (",
        "  echo CodexRebuild app was not found: %APPDIR%\Codex.exe",
        "  echo Run CodexRebuild-OneClick.cmd first to build the writable Store copy.",
        "  exit /b 1",
        ")",
        "set `"GUARD=%ROOT%\CodexRebuild-LaunchGuard.ps1`"",
        "if not exist `"%GUARD%`" (",
        "  echo CodexRebuild launch guard was not found: %GUARD%",
        "  exit /b 1",
        ")",
        "powershell -NoProfile -ExecutionPolicy Bypass -File `"%GUARD%`" -Root `"%ROOT%`"",
        "if errorlevel 1 exit /b %ERRORLEVEL%",
        "set `"CODEX_ELECTRON_USER_DATA_PATH=%ROOT%\UserData`"",
        "if `"%CODEXREBUILD_LAUNCH_DRY_RUN%`"==`"1`" (",
        "  echo CodexRebuild launch dry run passed.",
        "  exit /b 0",
        ")",
        "start `"`" /D `"%APPDIR%`" `"%APPDIR%\Codex.exe`""
    )
    [System.IO.File]::WriteAllLines($launcherPath, $content, [System.Text.UTF8Encoding]::new($false))
    return $launcherPath
}

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}

if ([string]::IsNullOrWhiteSpace($WindowsAppsRoot)) {
    if ([string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        throw "ProgramFiles environment variable is not set. Pass -WindowsAppsRoot explicitly."
    }
    $WindowsAppsRoot = Join-Path $env:ProgramFiles "WindowsApps"
}

$rootPath = $Root.TrimEnd("\")
$destinationRoot = Join-Path $rootPath $DestinationName
$archiveRoot = Join-Path $rootPath "archive"
$stagingRoot = Join-Path $rootPath ".staging"
$userDataRoot = Join-Path $rootPath "UserData"

$coreInfo = Resolve-CoreDirectory -CoreDir $CoreDir -Root $rootPath -NoCoreReplacement:$NoCoreReplacement
$packageInfo = Resolve-CodexPackage -PackageName $PackageName -WindowsAppsRoot $WindowsAppsRoot
$storeAppRoot = Join-Path $packageInfo.InstallLocation "app"
$storeResourcesRoot = Join-Path $storeAppRoot "resources"

if (-not (Test-Path -LiteralPath (Join-Path $storeAppRoot "Codex.exe") -PathType Leaf)) {
    throw "Store app root does not contain Codex.exe: $storeAppRoot"
}

$mappings = @(
    [pscustomobject]@{
        Target = "codex.exe"
        Sources = @("codex-x86_64-pc-windows-msvc.exe", "codex.exe")
    },
    [pscustomobject]@{
        Target = "codex-command-runner.exe"
        Sources = @("codex-command-runner.exe", "codex-command-runner-x86_64-pc-windows-msvc.exe")
    },
    [pscustomobject]@{
        Target = "codex-windows-sandbox-setup.exe"
        Sources = @("codex-windows-sandbox-setup.exe", "codex-windows-sandbox-setup-x86_64-pc-windows-msvc.exe")
    }
)

$sourceFiles = @()
if ($coreInfo.Path) {
    $sourceFiles = foreach ($mapping in $mappings) {
        $sourcePath = Find-SourceFile -Directory $coreInfo.Path -Candidates $mapping.Sources
        [pscustomobject]@{
            Target = $mapping.Target
            SourcePath = $sourcePath
            Source = Get-FileSummary -Path $sourcePath
        }
    }
}

$existingManifestPath = Join-Path $destinationRoot "codex-rebuild-manifest.json"
$existingManifest = $null
if (Test-Path -LiteralPath $existingManifestPath -PathType Leaf) {
    try {
        $existingManifest = Get-Content -LiteralPath $existingManifestPath -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "Existing manifest could not be parsed: $existingManifestPath"
    }
}

$running = Get-RebuildProcesses -DestinationRoot $destinationRoot
if ($running) {
    Write-Warning "CodexRebuild processes are running from $destinationRoot"
    $running | Format-Table -AutoSize | Out-String | Write-Host
    if ($StopRunningRebuild) {
        foreach ($process in $running) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        }
        Start-Sleep -Seconds 2
    } else {
        throw "Close CodexRebuild first, or rerun with -StopRunningRebuild."
    }
}

Write-Host ""
Write-Host "Root:        $rootPath"
Write-Host "Destination: $destinationRoot"
Write-Host "Store:       $($packageInfo.PackageFullName) [$($packageInfo.Source)]"
Write-Host "Store app:   $storeAppRoot"
if ($coreInfo.Path) {
    Write-Host "Core:        $($coreInfo.Path) [$($coreInfo.Source)]"
} else {
    Write-Host "Core:        Store bundled core files [no replacement]"
}
Write-Host "Mode:        $(if ($DryRun) { 'DRY-RUN' } else { 'REBUILD' })"
Write-Host ""

if ($sourceFiles.Count -gt 0) {
    foreach ($source in $sourceFiles) {
        Write-Host "$($source.Target) <= $($source.SourcePath)"
        Write-Host "  version: $($source.Source.ProductVersion)"
        Write-Host "  sha256:  $($source.Source.Sha256)"
    }
} else {
    Write-Host "No Core replacement will be applied."
}

if ($existingManifest) {
    Write-Host ""
    Write-Host "Existing build:"
    Write-Host "  builtAt: $($existingManifest.builtAt)"
    Write-Host "  store:   $($existingManifest.store.PackageFullName)"
    Write-Host "  core:    $($existingManifest.core.SourceDir)"
}

if ($DryRun) {
    Write-Host ""
    Write-Host "Dry-run only. Rerun without -DryRun to rebuild."
    exit 0
}

New-Item -ItemType Directory -Path $rootPath, $archiveRoot, $stagingRoot, $userDataRoot -Force | Out-Null

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$stageRoot = Join-Path $stagingRoot "Codex-$stamp"
$stageAppRoot = Join-Path $stageRoot "app"
$stageResourcesRoot = Join-Path $stageAppRoot "resources"

if (Test-Path -LiteralPath $stageRoot) {
    throw "Staging directory already exists: $stageRoot"
}

Write-Host ""
Write-Host "Copying Store app to staging..."
$robocopyLog = Join-Path $stageRoot "robocopy-store-copy.log"
$copyExit = Invoke-Robocopy -Source $storeAppRoot -Destination $stageAppRoot -LogPath $robocopyLog
Write-Host "robocopy exit code: $copyExit"

New-Item -ItemType Directory -Path (Join-Path $stageResourcesRoot "app.asar.unpacked") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stageResourcesRoot "plugins") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stageResourcesRoot "native") -Force | Out-Null

$runtimeChecks = @()
if (-not $SkipRuntimeValidation) {
    $runtimeChecks = @(Assert-RebuildRuntimeFiles -ResourcesRoot $stageResourcesRoot)
}

if ($sourceFiles.Count -gt 0) {
    Write-Host "Patching core files in staging..."
    foreach ($source in $sourceFiles) {
        $targetPath = Join-Path $stageResourcesRoot $source.Target
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            throw "Missing staging target file: $targetPath"
        }

        Copy-Item -LiteralPath $source.SourcePath -Destination $targetPath -Force
        $targetHash = Get-Sha256 -Path $targetPath
        if ($targetHash -ne $source.Source.Sha256) {
            throw "Hash mismatch after patching $targetPath"
        }
    }
} else {
    Write-Host "Skipping core replacement; using Store bundled core files."
}

$manifest = [ordered]@{
    builtAt = (Get-Date).ToString("o")
    root = $rootPath
    destinationRoot = $destinationRoot
    userDataDir = $userDataRoot
    store = [ordered]@{
        PackageFullName = $packageInfo.PackageFullName
        Version = $packageInfo.Version
        InstallLocation = $packageInfo.InstallLocation
        AppRoot = $storeAppRoot
        Source = $packageInfo.Source
    }
    storeCopy = [ordered]@{
        RobocopyLog = $robocopyLog
        CopyMode = "Full Store app copy"
        ExcludedProtectedPaths = @()
        RuntimeChecks = @($runtimeChecks | ForEach-Object {
            [ordered]@{
                Name = $_.Name
                RelativePath = $_.RelativePath
                Path = $_.Path
                Length = $_.Length
                MinLength = $_.MinLength
                Ok = $_.Ok
            }
        })
    }
    core = [ordered]@{
        ReplacementEnabled = ($sourceFiles.Count -gt 0)
        SourceDir = $coreInfo.Path
        Source = $coreInfo.Source
        Files = @($sourceFiles | ForEach-Object {
            [ordered]@{
                Target = $_.Target
                SourcePath = $_.SourcePath
                ProductVersion = $_.Source.ProductVersion
                Length = $_.Source.Length
                Sha256 = $_.Source.Sha256
            }
        })
    }
}

$manifestPath = Join-Path $stageRoot "codex-rebuild-manifest.json"
$manifest | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $manifestPath -Encoding UTF8

$stageCodexExe = Join-Path $stageAppRoot "Codex.exe"
if (-not (Test-Path -LiteralPath $stageCodexExe -PathType Leaf)) {
    throw "Staging app is missing Codex.exe"
}

Write-Host "Switching staged copy into place..."
if (Test-Path -LiteralPath $destinationRoot) {
    $archiveName = "Codex-previous-$stamp"
    if ($existingManifest -and $existingManifest.store.PackageFullName) {
        $safePackage = ($existingManifest.store.PackageFullName -replace '[^\w.-]', '_')
        $archiveName = "Codex-previous-$safePackage-$stamp"
    }

    $archivePath = Join-Path $archiveRoot $archiveName
    Move-Item -LiteralPath $destinationRoot -Destination $archivePath -Force
    Write-Host "Archived previous copy: $archivePath"
}

Move-Item -LiteralPath $stageRoot -Destination $destinationRoot -Force

$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $destinationRoot /inheritance:e /grant "${currentUser}:(OI)(CI)F" /T /C | Write-Host

$finalAppRoot = Join-Path $destinationRoot "app"
$finalCodexExe = Join-Path $finalAppRoot "Codex.exe"
$finalResourcesRoot = Join-Path $finalAppRoot "resources"

if ($sourceFiles.Count -gt 0) {
    foreach ($source in $sourceFiles) {
        $finalTarget = Join-Path $finalResourcesRoot $source.Target
        $finalHash = Get-Sha256 -Path $finalTarget
        if ($finalHash -ne $source.Source.Sha256) {
            throw "Final hash mismatch for $finalTarget"
        }
    }
}

if (-not $SkipRuntimeValidation) {
    [void](Assert-RebuildRuntimeFiles -ResourcesRoot $finalResourcesRoot)
}

$launcherPath = New-LaunchScript -RootPath $rootPath -TargetPath $finalCodexExe -WorkingDirectory $finalAppRoot -UserDataDir $userDataRoot
Write-Host "Launch wrapper: $launcherPath"

$shortcutPath = $null
if (-not $NoShortcut) {
    $shortcutPath = New-DesktopShortcut -TargetPath $launcherPath -WorkingDirectory $rootPath -IconPath $finalCodexExe
    Write-Host "Desktop shortcut: $shortcutPath"
}

Write-Host ""
Write-Host "CodexRebuild complete."
Write-Host "Launch target: $finalCodexExe"
Write-Host "Manifest:      $(Join-Path $destinationRoot 'codex-rebuild-manifest.json')"
Write-Host "User data:     $userDataRoot"
