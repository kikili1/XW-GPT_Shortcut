---
name: gpt-sc
description: 在 Windows 上初始化或自定义 ChatGPT 桌面快捷键，自动解绑冲突、刷新并实测桌面启动热键，完成后简短提示手动重启。不用于网页或终端 Codex。
---

# GPT-SC

使用 `scripts/Set-GptShortcuts.ps1` 操作采用 `.codex/keybindings.json` 的 Windows ChatGPT 桌面应用。脚本兼容 PowerShell 5.1；版本不兼容时停止。仅在用户要求实际设置时执行 `Apply`，安装或修改技能不应用设置。

## 调用

将 `<skill>` 替换为技能绝对路径：

```powershell
$runner = '<skill>\scripts\Set-GptShortcuts.ps1'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner                    # Preview，只读预览
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -ListCommands      # 本机命令及名称翻译键
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Mode Apply        # 应用并实测桌面热键
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Mode Verify       # 只读检查文件与属性
```

默认识别安装位置和当前用户桌面，配置目录使用 `CODEX_HOME`，否则使用用户的 `.codex`。安装不唯一时报告候选；可用 `-AppPath` 指定 `ChatGPT.exe`、`-ConfigRoot` 指定配置目录，不写死版本或其他用户路径。

## 初始化与自定义

首次 `Apply` 应用以下预设，用户同批指定的值优先：

| 功能 | 命令 | 快捷键 |
| --- | --- | --- |
| 从输入框启动语音模式 | `composer.startVoiceMode` | `Alt+Shift+I` |
| 按住进行全局听写 | `globalDictationHold` | `Alt+Shift+U` |
| 实时语音入口快捷键 | `realtimeVoice` | `null`（显式禁用） |
| 语音通话麦克风静音／取消静音 | `realtimeVoice.toggleMicrophoneMute` | `Alt+Shift+P` |
| 桌面启动 | `ChatGPT.lnk` | `Alt+Shift+O` |

聚焦主聊天输入框沿用程序默认 `Alt+L`，不写入预设；不再将 `Alt+Shift+I` 绑定到 `hotkeyWindow`。`realtimeVoice` 的禁用项仅禁用该命令的快捷键，不禁用语音功能或 `composer.startVoiceMode` 入口。

成功后写入 `gpt-sc.initialized.json`。后续只修改指定的应用内绑定，不重设预设或删除初始化记录。每次 `Apply` 都刷新并检查桌面热键：未指定时沿用现有值，快捷方式缺失时重建，热键为空时保留禁用状态。

自定义前用 `-ListCommands` 核实功能与命令标识，必要时通过 `TitleIntlId` 对照界面或语言资源；命令已注册不代表当前账号可用。将请求保存为 UTF-8 JSON 数组：

```json
[
  { "command": "newTask", "key": "Alt+N" },
  { "command": "realtimeVoice", "key": null }
]
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Mode Apply -BindingsFile '<request.json>'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Mode Verify -BindingsFile '<request.json>'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Mode Apply -DesktopHotkey 'Alt+Shift+K'
```

`key: null` 禁用快捷键，不是恢复默认；未知命令、重复命令和空字符串会被拒绝。`-DesktopHotkey None` 取消桌面热键并保留快捷方式。`Verify` 检查指定修改时须携带相同参数；无参数时仅展示当前设置，不断言等于首次预设。退出码 0 表示文件与属性匹配，1 表示不匹配或错误。

## 冲突处理

目标快捷键优先。脚本合并本机应用注册命令的 Windows 默认绑定与用户配置，自动将占用目标按键的其他应用内命令设为 `key: null`，包括桌面热键的占用项，无需再确认。不能删除配置项代替禁用，否则默认值可能恢复；多组默认按键会随该命令一起禁用。

保留未知字段、不冲突的绑定及已有禁用项。回读须确认目标值匹配且相关冲突已清除，成功结果通过 `RemovedConflicts` 记录自动解绑项。用户主动禁用的项目不计入冲突。

同批目标之间冲突（含桌面热键），或现有 `ChatGPT.lnk` 指向其他应用时，停止写入并报告。不修改其他程序或系统热键，也不声称已清除未知的系统级占用。

## 桌面热键验证

脚本在最终 `ChatGPT.lnk` 路径上执行“清空热键并保存 → 通知 Shell → 短暂等待 → 恢复目标热键并保存 → 再通知”。保持现有权限，不用临时带热键的快捷方式替换原文件，不通过提权或重启 Explorer 修复。

启用桌面热键时，`scripts/GptDesktopInterop.cs` 必须实测唤起：先让独立验证窗口获得前台焦点，确认修饰键已松开，再模拟目标热键；8 秒内所选 `ChatGPT.exe` 的可见窗口成为前台才通过。文件属性正确、进程存在或 GPT 原本就在前台均不足以通过。

实测失败或无法判断时，最多重新刷新并测试一次，仍未通过则整次事务失败并回滚。锁屏、无交互桌面、焦点或输入受阻时不能跳过检查或自动提权。桌面热键被主动禁用时仅检查禁用属性。

测试允许通过目标按键唤起或打开 GPT，不直接启动程序来代替按键验证，不退出、结束进程或自动重启 GPT。已运行状态下通过只证明当前会话能唤起，不证明完全退出后的冷启动，也不代表听写等应用内功能已经生效。`Preview`、`Verify` 不触发热键。

## 事务与结果

`Apply` 同步完成备份、写入、回读、桌面实测及初始化记录。任一步失败时恢复涉及文件并通知 Shell；恢复失败报告 `RestoreError`，保留备份。运行记录默认存于 `%LOCALAPPDATA%\GPT-SC\runs\<运行编号>`，包含 `status.json`、`execution.log` 和 `before-write` 备份，日志不保存完整用户配置。

仅在 `Succeeded` 且 `RestartRequired: true` 时使用以下回复，不列出已设置的快捷键、按键组合、命令标识、路径或测试过程：

> 初始化完毕。已移除“<冲突功能名称>”的快捷键。请完全退出 GPT（包括托盘进程），再手动重新打开以生效。

按 `RemovedConflicts` 列出全部实际解绑项，依据当前界面或语言资源使用中文功能名称；无冲突时省略第二句。失败或回滚时简短报告原因，不套用成功回复。

## 隔离测试

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '<skill>\scripts\Test-GptShortcuts.ps1'
```

测试覆盖初始化、自定义、冲突清理、原路径热键刷新、原生检查器编译、实测门槛、一次重试及回滚。真实 COM 快捷方式位于临时目录，唤起结果由隔离适配器模拟，不操作本机 GPT 或真实桌面，不能作为实际唤起证明。
