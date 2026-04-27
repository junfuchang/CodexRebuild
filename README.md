# CodexRebuild

CodexRebuild 是一组 Windows 脚本，用来把 Microsoft Store 版 Codex 桌面应用复制成一个可写的本地副本。

它不会修改 `%ProgramFiles%\WindowsApps` 里的原始 Store 应用。所有改动都发生在当前目录下的 `.\Codex`。

English: see [README-en.md](README-en.md).

## 适合谁

- 你已经安装 Microsoft Store 版 Codex。
- 你想要一个可写、可打补丁、可单独使用的 Codex 副本。
- 你不想直接改受保护的 WindowsApps 目录。

## 快速开始

双击：

```text
CodexRebuild-OneClick.cmd
```

脚本会做三件事：

1. 找到当前安装的 Store 版 Codex。
2. 复制成当前目录下的 `.\Codex`。
3. 运行一次启动 smoke test。

成功后，用桌面快捷方式 `CodexRebuild.lnk` 启动，或运行生成的：

```text
CodexRebuild-Launch.cmd
```

## 更新 Codex 核心

从 OpenAI Codex releases 下载 Windows 包：

```text
codex-x86_64-pc-windows-msvc.exe.zip
```

下载地址：

```text
https://github.com/openai/codex/releases
```

把 zip 放到本目录，然后双击：

```text
CodexRebuild-UpdateCore-OneClick.cmd
```

它会更新 `.\Core`，重新构建 `.\Codex`，并运行 smoke test。

如果文件在别的目录，可以把 zip 拖到 `CodexRebuild-UpdateCore-OneClick.cmd` 上。

## 可选补丁

这些补丁都只修改 `.\Codex\app`，不会修改原始 Store 应用。

启用 Fast mode：

```text
CodexRebuild-EnableFastMode-OneClick.cmd
```

让 API key 登录状态也能显示 Plugins 入口：

```text
CodexRebuild-EnablePluginsForApiKey-OneClick.cmd
```

增加本地会话永久删除按钮：

```text
CodexRebuild-EnableTrueDelete-OneClick.cmd
```

Store 应用更新后，建议先重新运行 `CodexRebuild-OneClick.cmd`，再按需重新应用这些补丁。

## 清理生成文件

双击：

```text
CodexRebuild-Remove-OneClick.cmd
```

它只清理已知生成物，例如：

- `.\Codex`
- `.\Core`
- `.\UserData`
- staging 目录
- 备份目录
- 生成的启动脚本和快捷方式

脚本文件、README、计划文档和你自己放进来的 release 包会保留。

## 工作原理

CodexRebuild 先动态发现当前 Store 包。优先使用 `Get-AppxPackage -Name OpenAI.Codex`，失败后扫描 `%ProgramFiles%\WindowsApps\OpenAI.Codex_*`。

随后脚本把 Store 应用完整复制到临时 staging 目录，验证关键运行文件，例如 `better-sqlite3`、`node-pty` 和内置 Browser Use 插件。

验证通过后，脚本把 staging 目录切换为 `.\Codex`。旧的 `.\Codex` 不会被合并，会归档到 `.\archive`。

启动时会使用独立用户数据目录：

```text
.\UserData
```

这可以避免和 Store 版 Codex 的 Electron 单实例状态混在一起。

启动前还会运行版本守卫。它会比较当前 Store 版主版本和重建副本记录的主版本。如果版本不一致，启动会被阻止，避免新旧状态混用。

## 目录说明

```text
CodexRebuild-*.ps1     主脚本
CodexRebuild-*.cmd     双击入口
.\Codex                重建后的可写应用
.\Core                 可选的新 Codex 核心文件
.\UserData             重建版专用用户数据
.\archive              旧重建副本归档
GPT-README.md          更完整的维护说明
```

## 注意

- 这个项目只适用于 Windows。
- 原始 Microsoft Store 应用不会被修改。
- `.\Codex` 不是安装好的 AppX 包，只是一个可写副本。
- 如果运行校验失败，脚本会拒绝切换到新的副本。
- 更完整的维护细节放在 `GPT-README.md`。
