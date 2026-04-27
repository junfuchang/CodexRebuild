# CodexRebuild

CodexRebuild builds a writable copy of the Microsoft Store Codex desktop app under the directory that contains these scripts:

```text
.\Codex
```

It avoids editing the original Store package in `%ProgramFiles%\WindowsApps`, because that package is protected and online replacement failed even as SYSTEM.

## Quick Use

To rebuild the current Store Codex app as a writable copy, double-click:

```text
.\CodexRebuild-OneClick.cmd
```

This rebuilds `.\Codex` from the currently installed Store app and runs the smoke test. It ignores `.\Core` completely.

To remove generated rebuild outputs and return this folder to script/doc/plan-only state, double-click:

```text
.\CodexRebuild-Remove-OneClick.cmd
```

The remove script deletes only known generated artifacts such as `.\Codex`, `.\Core`, backups, staging folders, runtime user data, and the generated `CodexRebuild-Launch.cmd`. It preserves scripts, docs, plans, and remaining user-provided release packages. A successful core update removes the selected local release package automatically.

To update the rebuilt app with a newer Codex core, put a new release folder or zip next to these scripts:

```text
.\codex-x86_64-pc-windows-msvc.exe\
.\codex-x86_64-pc-windows-msvc.exe.zip
```

If you do not have the update package yet, download the latest `codex-x86_64-pc-windows-msvc.exe.zip` from:

```text
https://github.com/openai/codex/releases
```

Then place that zip file in the current script folder.

Then double-click:

```text
.\CodexRebuild-UpdateCore-OneClick.cmd
```

That one-click update script searches the current script folder for `codex-x86_64-pc-windows-msvc.exe*` directories or `codex-x86_64-pc-windows-msvc.exe*.zip` archives, extracts zip files when needed, validates the three core binaries, backs up the old `.\Core` into `.\core-archive`, updates `.\Core`, rebuilds `.\Codex`, and runs the smoke test. After a successful update, it removes the selected local release folder/zip and temporary core staging folders.

If the release package is somewhere else, drag the release folder or zip onto `CodexRebuild-UpdateCore-OneClick.cmd`, or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\CodexRebuild-UpdateCore.ps1" -SourcePath "<release-folder-or-zip>"
```

Dry-run the update flow:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\CodexRebuild-UpdateCore.ps1" -DryRun
```

Dry-run validates the selected release package and passes that selected package into the rebuild dry-run. It does not validate an older `.\Core` folder. For zip packages, it extracts only to a temporary validation directory and removes that directory before exiting.

Restore the latest backed-up old Core:

```text
.\CodexRebuild-RestoreCore-OneClick.cmd
```

`CodexRebuild-RestoreCore.ps1` selects the newest valid backup under `.\core-archive` by default, restores it into `.\Core`, rebuilds `.\Codex`, and runs the smoke test. Drag a specific backup folder onto the one-click CMD or pass `-BackupPath "<backup-folder>"` to restore a specific backup.

Rebuild from the already installed `.\Core` folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\CodexRebuild-Rebuild.ps1"
```

If `.\Core` is absent, this command still rebuilds from the Store app and keeps the Store app's bundled core files.

Smoke test the rebuilt app:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\CodexRebuild-Test.ps1" -StopExisting
```

If the rebuilt copy does not exist yet, the smoke test and launcher will tell you to run `CodexRebuild-OneClick.cmd` first.

The smoke test, desktop shortcut, and `CodexRebuild-Launch.cmd` run `CodexRebuild-LaunchGuard.ps1` before starting the app. The guard dynamically compares the current Microsoft Store Codex package main version, for example `26.422`, with the main version recorded when `.\Codex` was rebuilt. If those main versions differ, startup is blocked and a Chinese warning is shown so you can rebuild before mixing old and new desktop state.

Or rebuild by double-clicking:

```text
.\CodexRebuild-OneClick.cmd
```

`CodexRebuild-OneClick.cmd` only rebuilds and smoke-tests the Store copy. It passes `-NoCoreReplacement`, so it does not discover, update, or apply `.\Core` even when `.\Core` exists. Use `CodexRebuild-UpdateCore-OneClick.cmd` for Core updates.

If no `-CoreDir` is supplied, `CodexRebuild-Rebuild.ps1` uses `.\Core` when present and valid. Pass `-NoCoreReplacement` to force a pure Store rebuild.

Use `CodexRebuild-UpdateCore.ps1` to discover a new release folder/zip from the current script folder and replace `.\Core`.

To enable Fast mode on the writable rebuilt copy, double-click:

```text
.\CodexRebuild-EnableFastMode-OneClick.cmd
```

Or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\CodexRebuild-EnableFastMode.ps1" -StopRunningRebuild
```

The Fast mode script patches only `.\Codex\app`, writes a backup under `.\fast-mode-backup` only when it changes the frontend file, disables the required Electron fuses, and runs the smoke test. See `FAST-MODE-NOTES.md` for the detailed patch contract.

Both Fast mode and the plugin entry bypass call the shared webview preparation script:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\CodexRebuild-PrepareWebviewPatch.ps1" -StopRunningRebuild
```

That shared step extracts `resources\app.asar` to `resources\app`, moves the original `app.asar` aside, and disables the Electron fuses required for loading the extracted webview files. It pins the npx tools to `@electron/asar@4.2.0` and `@electron/fuses@2.1.1` so webview preparation does not float to newly published npm packages. You normally do not need to run it manually; each patch script invokes it when needed.

The webview patch scripts require an existing rebuilt copy at `.\Codex\app`. If it is missing, run `CodexRebuild-OneClick.cmd` first. They are safe to rerun: `CodexRebuild-PrepareWebviewPatch.ps1` becomes a no-op once `resources\app` exists and the fuses are disabled, and already-patched Fast/plugin reruns do not create new timestamp backup folders.

If Codex is authenticated with an API key and the Plugins entry asks for ChatGPT sign-in, enable the local plugin entry bypass independently:

```text
.\CodexRebuild-EnablePluginsForApiKey-OneClick.cmd
```

Or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\CodexRebuild-EnablePluginsForApiKey.ps1" -StopRunningRebuild
```

This only removes the desktop frontend gate that hides the Plugins navigation for API-key users. It does not create ChatGPT server credentials, so plugins that require ChatGPT/OAuth services can still fail until the account is actually signed in.

To add real local delete actions to the rebuilt copy, double-click:

```text
.\CodexRebuild-EnableTrueDelete-OneClick.cmd
```

Or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\CodexRebuild-EnableTrueDelete.ps1" -StopRunningRebuild
```

This adds a permanent delete entry to the left sidebar chat context menu and a Delete button in Settings -> Data controls -> Archived chats. It patches only `.\Codex\app`, writes a helper into the rebuilt app resources, and uses the existing local hard-delete semantics for session JSONL files, archived session JSONL files, `session_index.jsonl`, `state_5.sqlite`, `logs_2.sqlite`, and descendant subagent threads. It also removes leftover internal Codex files/directories whose names contain the deleted thread id under safe `~\.codex` roots. It does not recursively delete arbitrary project folders used as chat workspaces.

After a successful permanent delete, the patched UI asks you to restart Codex so the conversation list refreshes.

The core directory must contain these three files, either in release names or target names:

```text
codex-x86_64-pc-windows-msvc.exe  -> codex.exe
codex-command-runner.exe          -> codex-command-runner.exe
codex-windows-sandbox-setup.exe   -> codex-windows-sandbox-setup.exe
```

## What The Script Does

- Dynamically finds the current Store Codex package with `Get-AppxPackage -Name OpenAI.Codex`.
- Falls back to scanning `%ProgramFiles%\WindowsApps\OpenAI.Codex_*` and selecting the highest version with `app\Codex.exe`.
- Copies the Store app to a staging directory under `.staging`.
- Performs a full Store app copy, including `resources\app.asar.unpacked\node_modules` and `resources\plugins\openai-bundled`.
- Validates required runtime files before switching: `better-sqlite3`, `node-pty`, and the bundled Browser Use skill.
- Replaces the three Codex core files only when `.\Core` or `-CoreDir` is available.
- Verifies SHA256 hashes after patching when core replacement is enabled.
- Backs up the old `.\Core` under `.\core-archive` before installing a new Core.
- Removes the selected local core release package and core staging directories only after UpdateCore succeeds.
- Restores old Core backups with `CodexRebuild-RestoreCore.ps1` / `CodexRebuild-RestoreCore-OneClick.cmd`.
- Archives the previous rebuilt copy under `archive`.
- Moves the staged copy into `.\Codex`.
- Creates or updates `CodexRebuild-Launch.cmd`.
- The launcher and smoke test check that `.\Codex\app\Codex.exe` exists and that the rebuilt copy's main version matches the current Store app main version before starting the app.
- Creates or updates the desktop shortcut `CodexRebuild.lnk` to point at the launcher.
- Webview patch scripts are independent: `CodexRebuild-EnableFastMode.ps1`, `CodexRebuild-EnablePluginsForApiKey.ps1`, and `CodexRebuild-EnableTrueDelete.ps1` each call `CodexRebuild-PrepareWebviewPatch.ps1` when needed.
- Webview patch scripts fail early with an actionable message if `.\Codex\app` has not been built yet.
- Already-applied Fast/plugin patch reruns update the manifest but do not create a new backup directory.
- `CodexRebuild-Remove.ps1` removes generated rebuild artifacts while preserving scripts, docs, plans, and user-provided release packages, including webview patch backup folders such as `true-delete-backup`.

## Conflict Handling

The script never merges a new Store copy into the old rebuilt copy. It always builds a fresh staging copy first, then archives the old `Codex` directory and switches the new one into place.

This matters when the Store app updates and the package directory changes, for example:

```text
OpenAI.Codex_26.422.3464.0_x64__2p2nqsd0c76g0
OpenAI.Codex_26.x.y.z_x64__2p2nqsd0c76g0
```

The script discovers the new directory on each run.

If `CodexRebuild` is running, the rebuild stops before changing files. Close the app first, or use:

```powershell
-StopRunningRebuild
```

## Launching

The desktop shortcut launches:

```text
.\CodexRebuild-Launch.cmd
```

The launcher sets the separate Electron profile with:

```text
CODEX_ELECTRON_USER_DATA_PATH=.\UserData
```

The generated launcher computes that path from its own location, so moving the whole folder and rebuilding regenerates a matching shortcut. This matters because the Codex Electron bootstrap reads `CODEX_ELECTRON_USER_DATA_PATH`; `--user-data-dir` alone is not enough and can cause the rebuilt copy to hit the Store app's single-instance lock.

## Notes

- Store updates can break or change the copied app layout. Re-run the rebuild script after Store updates.
- Store rebuilds replace webview patches. After rebuilding, run only the patch scripts you actually want: Fast mode, plugin entry bypass, or both.
- Old rebuilt copies are archived, not deleted.
- The original Store app is not modified.
- The rebuilt copy is not an installed AppX package; it is just a writable desktop app copy.
- If runtime validation fails, the script refuses to switch the staged copy into place. This avoids producing a rebuilt app that immediately fails with missing native module errors such as `better-sqlite3 is only bundled with the Electron app`.
