# CodexRebuild

CodexRebuild is a set of Windows scripts that copy the Microsoft Store Codex desktop app into a writable local copy.

It does not modify the original Store app under `%ProgramFiles%\WindowsApps`. All changes happen under `.\Codex` in this folder.

中文说明：见 [README.md](README.md).

## Who It Is For

- You already installed the Microsoft Store version of Codex.
- You want a writable Codex copy for local patches.
- You do not want to edit the protected WindowsApps package.

## Quick Start

Double-click:

```text
CodexRebuild-OneClick.cmd
```

The script does three things:

1. Finds the installed Store Codex app.
2. Copies it into `.\Codex`.
3. Runs a startup smoke test.

After it succeeds, launch Codex from the desktop shortcut `CodexRebuild.lnk`, or run:

```text
CodexRebuild-Launch.cmd
```

## Update The Codex Core

Download the Windows package from OpenAI Codex releases:

```text
codex-x86_64-pc-windows-msvc.exe.zip
```

Release page:

```text
https://github.com/openai/codex/releases
```

Put the zip in this folder, then double-click:

```text
CodexRebuild-UpdateCore-OneClick.cmd
```

It updates `.\Core`, rebuilds `.\Codex`, and runs the smoke test. If an older `.\Core` exists, it is backed up under `.\core-archive` first. After a successful update, the script removes the release zip or release folder used from this script folder, plus temporary core staging folders.

If the file is somewhere else, drag the zip onto `CodexRebuild-UpdateCore-OneClick.cmd`.

To restore the latest backed-up old Core, double-click:

```text
CodexRebuild-RestoreCore-OneClick.cmd
```

It selects the latest valid Core backup from `.\core-archive`, restores it into `.\Core`, rebuilds `.\Codex`, and runs the smoke test.

## Optional Patches

These patches only modify `.\Codex\app`. They do not modify the original Store app.

Enable Fast mode:

```text
CodexRebuild-EnableFastMode-OneClick.cmd
```

Show the Plugins entry when Codex is authenticated with an API key:

```text
CodexRebuild-EnablePluginsForApiKey-OneClick.cmd
```

Add permanent local delete actions for chats:

```text
CodexRebuild-EnableTrueDelete-OneClick.cmd
```

After a Store app update, run `CodexRebuild-OneClick.cmd` again, then reapply only the patches you need.

## Clean Generated Files

Double-click:

```text
CodexRebuild-Remove-OneClick.cmd
```

It removes known generated files and folders, such as:

- `.\Codex`
- `.\Core`
- `.\UserData`
- staging folders
- backup folders
- generated launch script and shortcut

It keeps scripts, README files, plan docs, and remaining release packages. Note: after `CodexRebuild-UpdateCore-OneClick.cmd` succeeds, the local release package it used is removed automatically; `.\core-archive` is also a generated backup folder and is removed by the cleanup script.

## How It Works

CodexRebuild first finds the current Store package. It uses `Get-AppxPackage -Name OpenAI.Codex`, then falls back to scanning `%ProgramFiles%\WindowsApps\OpenAI.Codex_*`.

It copies the Store app into a staging folder and validates required runtime files, including `better-sqlite3`, `node-pty`, and the bundled Browser Use plugin.

After validation passes, it switches the staged copy into `.\Codex`. The old `.\Codex` is archived under `.\archive`; it is not merged.

The rebuilt app uses its own user data folder:

```text
.\UserData
```

This keeps it separate from the Store app's Electron single-instance state.

Before launch, a version guard compares the current Store app main version with the rebuilt copy's recorded main version. If they differ, launch is blocked to avoid mixing old and new desktop state.

## Folder Guide

```text
CodexRebuild-*.ps1     main scripts
CodexRebuild-*.cmd     double-click launchers
.\Codex                rebuilt writable app
.\Core                 optional new Codex core files
.\UserData             user data for the rebuilt app
.\archive              archived old rebuilt copies
.\core-archive         old Core backups used by RestoreCore
GPT-README.md          longer maintenance notes
```

## Notes

- This project is Windows-only.
- The original Microsoft Store app is not modified.
- `.\Codex` is a writable copy, not an installed AppX package.
- If validation fails, the script refuses to switch to the new copy.
- Detailed maintenance notes are in `GPT-README.md`.
