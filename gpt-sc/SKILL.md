---
name: gpt-sc
description: 在 Windows 上用外置 PowerShell 脚本初始化或自定义 ChatGPT 内置快捷键、修改桌面启动热键，完成后提示用户手动重启。首次应用设置 GPT-SC 的四组预设，后续按用户要求修改其他快捷键或禁用绑定，保留未指定的设置。不用于网页或终端 Codex 的按键配置。
---

# GPT-SC

使用本技能目录中的 `scripts/Set-GptShortcuts.ps1`，不要临时拼装配置写入命令。面向使用 `.codex/keybindings.json` 的 Windows ChatGPT 桌面应用；旧版配置不兼容时停止并报告。

## 首次初始化

技能安装后首次执行 `Apply` 时设置下列预设。脚本在所选配置目录中记录 `gpt-sc.initialized.json`；此记录在配置写入及回读校验成功后创建；事务失败时随配置一起回滚。安装技能文件本身不修改 GPT。

| 功能 | 命令标识 | 快捷键 |
| --- | --- | --- |
| 听写快捷键 | `globalDictationHold` | `Alt+Shift+P` |
| 聚焦主聊天输入框 | `focusMainChat` | `Alt+L` |
| 弹出窗口快捷键 | `hotkeyWindow` | `Alt+Shift+I` |
| 桌面 ChatGPT.lnk | Windows 快捷方式 | `Alt+Shift+O` |

此后不再自动重设这四项，包括用户在 GPT 设置中自行修改的值。已初始化后，无参数 `Apply` 返回 `NoChanges`，不退出或重启 GPT。不删除初始化记录来修改其他快捷键，也不重新套用全部预设；若用户要求恢复某项预设，像普通自定义修改一样显式指定它。

## 调用

用技能实际绝对路径替换下面的 `<skill>`。脚本兼容 Windows PowerShell 5.1，无需 Python、Node 或常驻热键工具。

```powershell
# 只读预览，默认模式；不创建日志、备份或快捷方式
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Set-GptShortcuts.ps1"

# 首次应用预设；已初始化后无参数调用不会重设快捷键
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Set-GptShortcuts.ps1" -Mode Apply

# 只读列出本机应用注册的命令标识及名称翻译键
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Set-GptShortcuts.ps1" -ListCommands

# 只读检查当前设置；携带自定义参数时检查该批修改是否已生效
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Set-GptShortcuts.ps1" -Mode Verify
```

## 自定义任意受支持快捷键

用户可用自然语言要求修改 GPT 的其他快捷键，也可修改这四项预设。先用 `-ListCommands` 对照本机当前版本的注册命令，确定用户所指功能；`TitleIntlId` 是应用的翻译键，可结合当前版本的界面或语言资源核实名称。不要凭猜测创建命令标识。注册列表并不保证账号或当前界面具有对应功能权限。

将用户要求转换为 UTF-8 JSON 数组，保存在当前工作目录或临时目录，并用 `-BindingsFile` 交给脚本。例如，把新建任务改为 `Alt+N` 并禁用实时语音快捷键：

```json
[
  { "command": "newTask", "key": "Alt+N" },
  { "command": "realtimeVoice", "key": null }
]
```

```powershell
# 预览自定义请求
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Set-GptShortcuts.ps1" -BindingsFile "<request.json>"

# 应用指定修改，完成后提示手动重启
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Set-GptShortcuts.ps1" -Mode Apply -BindingsFile "<request.json>"

# 校验同一批自定义修改
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Set-GptShortcuts.ps1" -Mode Verify -BindingsFile "<request.json>"

# 单独修改桌面启动热键；None 表示取消桌面热键，保留快捷方式
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Set-GptShortcuts.ps1" -Mode Apply -DesktopHotkey "Alt+Shift+K"
```

`key` 使用 GPT 支持的快捷键写法，例如 `Ctrl+Shift+N`；`null` 显式禁用该命令的快捷键，不代表恢复默认。脚本拒绝未知命令、重复命令和自定义空字符串。首次应用也可以携带自定义参数：用户指定值优先于同一项预设，其他首次预设仍应用。后续只修改 JSON 中明确指定的命令；未传 `-DesktopHotkey` 时不修改、校验或恢复桌面快捷方式。

用户要求实际设置或恢复快捷键时使用 `Apply`；仅要求检查、预览或生成技能时不要应用。设置成功后明确提示用户：**请完全退出 GPT（包括托盘中的进程），然后手动重新打开，使快捷键生效。** 不替用户退出、结束进程、启动或重启 GPT，也不创建后台重启任务。仅预览、检查、无修改或执行失败时，不声称设置已生效。

默认自动识别安装和当前用户实际桌面（包括重定向桌面），配置目录使用 `CODEX_HOME`，未设置时使用用户的 `.codex`。若发现多个安装而无法唯一确定，报告候选；可通过 `-AppPath` 指定 `ChatGPT.exe`、`-ConfigRoot` 指定配置目录。不能靠写死包版本或其他用户的路径解决。

## 执行和结果

`Apply` 在当前 PowerShell 中同步完成：读取最新配置、备份、合并指定修改、写入、回读校验并记录初始化状态。它不要求 GPT 先退出，不进行进程等待或自动重启。调用返回最终结果，不再生成后台执行者或异步运行请求。

运行目录默认是 `%LOCALAPPDATA%\GPT-SC\runs\<运行编号>`，内含 `status.json`、`execution.log` 和 `before-write` 备份。返回 `Succeeded`、`RestartRequired: true` 以及手动重启提示时，表示设置已保存并通过文件校验；必须在答复用户时转述手动重启提示。首次预设和后续自定义修改都遵循此规则。

仅合并本次计划中的命令，保留未知字段、其他绑定及 `null` 禁用项。写入、回读校验或初始化记录失败时，恢复本次涉及文件的备份并报告错误，不操作 GPT 进程。恢复失败时报告 `RestoreError` 并保留备份。修改完成后避免再在 GPT 的快捷键设置界面同时编辑这些项目；用户手动重启后，可携带同一批自定义参数执行 `Verify` 检查持久化结果。

默认保留现有应用内 `Alt+Shift+O` 绑定，包括“显示工作区标签页”，并在设置对应桌面热键时列明冲突；只有用户明确要求时才通过自定义请求修改或禁用它。其他冲突也只报告，不自动解绑。涉及桌面修改时，若已有 `ChatGPT.lnk` 指向其他应用则停止覆盖；只修改内置快捷键时保留该桌面入口。系统可能有其他程序占用热键，脚本只报告可从当前配置和桌面快捷方式读出的冲突。

`Verify` 的退出码为 0 表示本次计划的文件和属性匹配，1 表示不匹配或错误。初始化后，无参数 `Verify` 展示当前设置，不再断言它们等于首次预设；验证具体修改需携带相同的自定义参数。正式应用的同步返回和 `status.json` 包含 `Succeeded` 或 `Failed`、`RestartRequired`、恢复结果及错误信息；它们不包含自动重启结果。日志不包含完整用户配置。

文件回读只证明设置已保存。桌面可见性、全局按键注册、听写、输入焦点和弹出窗口的实际效果，需要在桌面操作中分别确认；不应报告为已经验证。

## 隔离验证

运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Test-GptShortcuts.ps1"`，在随机临时目录中验证首次初始化、后续自定义、不重复预设、禁用绑定、手动重启提示、失败恢复和真实 `.lnk` 属性。测试断言配置流程不会调用退出或启动操作；测试不会操作本机 GPT 或真实桌面。保留的临时目录路径会出现在测试结果中。
