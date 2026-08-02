# PowerShell 会话集成

## 1. 设计目标

会话集成把版本解析结果应用到当前 PowerShell 7 进程，同时满足：

- 切换立即影响之后启动的 `java`、`javac`、Maven、Gradle 和其他子进程。
- 重复切换不产生重复 `PATH` 项。
- 不覆盖其他工具在 jenv 初始化后对 `PATH` 的无关修改。
- system 状态尽可能恢复初始化前的 Java 环境。
- 自动切换不依赖覆盖 `Set-Location`、`Push-Location` 或 `Pop-Location`。
- 初始化、刷新和卸载均幂等。

## 2. 为什么必须使用 PowerShell 模块

Windows `.exe` 或新启动的 `pwsh` 进程只能继承父进程环境，无法反向修改已经运行的父 PowerShell。因此：

- `jenv shell`、`jenv local`、`jenv global` 和 `jenv refresh` 必须最终在当前进程调用环境同步函数。
- 用户入口 `jenv` 必须是当前会话中的 PowerShell 函数。
- 不能把“输出一段 PowerShell 后让用户 `Invoke-Expression`”作为主要接口。

模块清单最低要求：

```powershell
@{
    RootModule           = 'JEnv.psm1'
    ModuleVersion        = '0.1.0'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
}
```

模块加载时还必须检查 `$IsWindows`，因为 `PSEdition = Core` 本身不限制操作系统。

## 3. 初始化生命周期

### 3.1 `Import-Module JEnv`

导入只执行：

- 加载公有和私有函数。
- 注册模块移除回调。
- 校验基础运行时要求。

导入不得：

- 创建 `$JENV_ROOT`。
- 读取或修改 PowerShell Profile。
- 修改 `JAVA_HOME`、`JDK_HOME` 或 `PATH`。
- 安装 prompt hook。

### 3.2 `Initialize-Jenv` / `jenv init`

第一次初始化：

1. 捕获 `JAVA_HOME` 和 `JDK_HOME` 是否存在及原始值。
2. 创建模块会话状态。
3. 忽略缓存执行一次完整解析。
4. 将解析结果应用到当前进程。
5. 在交互式会话安装 prompt hook。
6. 标记为已初始化。

重复初始化：

- 不重新捕获已经被 jenv 修改后的环境作为“原始环境”。
- 不重复包装 prompt。
- 执行一次 `refresh`，然后成功返回。

如果第 3 或第 4 步失败，不安装 prompt hook，初始化状态保持为 false，并恢复已经发生的局部环境修改。

### 3.3 模块移除

模块 `OnRemove` 回调：

1. 如果当前全局 `prompt` 仍是 jenv 安装的 hook，恢复初始化时保存的 prompt。
2. 如果 prompt 已被其他工具替换，不覆盖它。
3. 从 `PATH` 删除 managed bin。
4. 采用所有权规则恢复 `JAVA_HOME` 和 `JDK_HOME`。
5. 清除模块会话状态。

移除模块不修改 Profile；Profile 托管块只能通过 `jenv init --uninstall` 删除。

## 4. 环境所有权模型

PowerShell 环境变量属于进程，不具有模块作用域。jenv 因此记录自己最后写入的值，避免在恢复时覆盖用户或其他工具的后续修改。

初始化时记录：

```text
OriginalJavaHome.Exists
OriginalJavaHome.Value
OriginalJdkHome.Exists
OriginalJdkHome.Value
```

每次同步记录：

```text
ManagedJavaHome
ManagedJdkHome
ManagedBin
```

恢复规则：

- 当前 `JAVA_HOME` 仍等于 `ManagedJavaHome` 时，恢复原值或删除变量。
- 当前值已经不同，视为调用者主动接管，不修改。
- `JDK_HOME` 使用相同规则。
- `PATH` 只移除与 `ManagedBin` 规范化后相等的项，不恢复整条初始化前的 PATH。

不能通过保存并整体恢复旧 PATH 实现 system，因为这会删除模块初始化后由 Node、Python、虚拟环境或用户添加的路径。

## 5. PATH 管理算法

### 5.1 路径规范化

用于比较的路径键：

1. 如果值为空，保留为空且永不匹配 managed bin。
2. 使用 `[IO.Path]::GetFullPath()` 规范化。
3. 移除非根目录所必需的尾部 `\` 或 `/`。
4. 使用 `StringComparer.OrdinalIgnoreCase` 比较。

不要使用 `Resolve-Path` 作为唯一规范化手段，因为旧 managed bin 在 JDK 被移动后可能已经不存在。

### 5.2 切换到受管理 JDK

设目标目录为 `$targetBin = Join-Path $jdk.Home 'bin'`：

```text
读取当前 Path
  → 按 [IO.Path]::PathSeparator 拆分
  → 删除所有等于旧 ManagedBin 的项
  → 删除所有等于 targetBin 的项
  → 保持其他项的原顺序和值
  → 将 targetBin 放到首位
  → 使用 PathSeparator 连接
```

随后设置：

```powershell
$env:JAVA_HOME = $jdk.Home
$env:JDK_HOME  = $jdk.Home
$env:Path      = $newPath
```

最后才更新模块中的 `Managed*` 状态。任何一步失败时应恢复本次调用开始时的三个环境变量。

空 PATH 项可能代表当前目录语义，模块不负责清理；除 managed bin 外不做全局去重、排序或存在性过滤。

### 5.3 切换到 system

```text
从当前 Path 删除 ManagedBin
  → 按所有权规则恢复 JAVA_HOME
  → 按所有权规则恢复 JDK_HOME
  → 清空 Managed* 状态
```

system 表示恢复初始化时继承的 Java 环境，不尝试从注册表或 `Get-Command java` 推断 `JAVA_HOME`。

### 5.4 幂等性

目标 canonical ID 和环境均未变化时，同步不重写 PATH。以下操作必须不改变最终结果：

```powershell
jenv refresh
jenv refresh
Initialize-Jenv
Initialize-Jenv
```

## 6. prompt hook

### 6.1 职责

PowerShell 在显示下一次提示符前调用全局 `prompt` 函数。jenv 包装当前 prompt：

```text
jenv prompt hook
  → 静默检查解析指纹
  → 指纹变化时 Sync-JenvEnvironment
  → 调用初始化时保存的原 prompt
  → 原样返回原 prompt 的输出
```

hook 不得向成功输出流写入任何内容，否则会污染提示符。

### 6.2 安装安全

- 保存的是当前 `Function:\global:prompt` 的 ScriptBlock，不保存函数名称字符串。
- hook ScriptBlock 必须能访问模块内部同步函数，但不能依赖用户当前作用域中的临时变量。
- 用引用身份或模块生成的唯一标记判断当前 prompt 是否仍是自己的 hook。
- 重复初始化检测到 hook 已安装时直接复用。
- 原 prompt 抛错时不吞掉错误，也不能递归调用自身。

### 6.3 与主题工具的关系

Oh My Posh、Starship 或其他主题也可能替换 `prompt`。推荐 Profile 顺序：

```powershell
# 先初始化提示符主题
oh-my-posh init pwsh --config $Theme | Invoke-Expression

# 再让 jenv 包装最终 prompt
Import-Module JEnv
Initialize-Jenv
```

此处 `Invoke-Expression` 属于主题工具自己的官方初始化输出，不是 jenv 用来处理配置或参数的机制。

如果主题在 jenv 之后替换 prompt：

- 当前环境保持不变。
- 自动目录切换停止。
- `jenv refresh` 继续正常工作。
- `jenv doctor` 对 PromptHook 给出 WARN，并建议重新运行 `Initialize-Jenv`。

### 6.4 为什么不覆盖目录命令

0.1 不代理 `Set-Location`、`cd`、`Push-Location` 或 `Pop-Location`，原因是完整复制这些 cmdlet 的参数集、Provider 行为、管道语义和错误语义风险较高。prompt hook 覆盖标准交互式切换，脚本使用 `jenv exec` 或显式 `jenv refresh`。

## 7. Profile 集成

### 7.1 目标 Profile

只操作当前 PowerShell 7 提供的：

```powershell
$PROFILE.CurrentUserAllHosts
```

不能硬编码 `Documents\PowerShell`，因为 Documents 可能被重定向，且宿主负责提供正确路径。

### 7.2 安装算法

`jenv init --install`：

1. 读取 `$PROFILE.CurrentUserAllHosts` 的实际路径。
2. 如果文件存在，检测编码、换行和 Authenticode 签名。
3. 已有一个完整托管块时不修改文件。
4. 发现单侧标记或多个托管块时失败。
5. 有有效签名的 Profile 默认失败，避免使签名失效；提示用户手工添加并重新签名。
6. 不存在时创建父目录。
7. 在文件末尾追加一个换行和托管块。
8. 使用同目录临时文件原子替换，并生成备份。
9. 初始化当前会话。

写入新文件统一使用无 BOM UTF-8；修改已有文件时尽量保留其 BOM 和 CRLF/LF 风格。

### 7.3 卸载算法

`jenv init --uninstall`：

- 精确删除包含起止标记的整个托管块以及由安装产生的一个相邻空行。
- 保留文件其他字节和换行风格。
- 托管块不存在时幂等成功。
- 标记损坏时失败，不做模糊删除。
- 从当前会话移除 jenv prompt hook并恢复 Java 环境。
- 不执行 `Remove-Module`，以便命令可以输出卸载结果。

## 8. `exec` 的环境隔离

PowerShell 的 `$env:*` 是进程级状态，即使在子作用域赋值也不会自动恢复，因此 `jenv exec` 必须显式保存和恢复：

```powershell
$snapshot = Save-JenvProcessEnvironment
try {
    Set-JenvEnvironmentForExecution -Jdk $jdk
    & $command @arguments
}
finally {
    Restore-JenvProcessEnvironment -Snapshot $snapshot
}
```

快照至少记录 `JAVA_HOME`、`JDK_HOME`、`Path` 的存在性和值。恢复发生在 `finally` 中，包括命令抛错和用户中断场景。

`exec` 的临时环境不得更新交互会话的 `Managed*` 状态或解析缓存。嵌套 `jenv exec` 通过栈式快照自然恢复。

## 9. 非交互式使用

CI 或脚本可以不调用 `Initialize-Jenv`：

```powershell
Import-Module JEnv
jenv exec --version 17 -- .\gradlew.bat test
```

如果脚本希望后续多条命令共享环境，可以显式执行：

```powershell
Import-Module JEnv
jenv shell 17
java -version
.\mvnw.cmd verify
```

`jenv shell` 在未先调用 `init` 时应隐式创建会话状态并捕获原环境，但不安装 prompt hook；只有 `Initialize-Jenv` 安装 hook。

## 10. PowerShell API 设计

建议导出：

```text
jenv
Initialize-Jenv
Register-JenvJdk
Unregister-JenvJdk
Get-JenvJdk
Get-JenvCurrent
Set-JenvGlobal
Set-JenvLocal
Set-JenvShell
Sync-JenvEnvironment
Invoke-JenvCommand
Test-JenvInstallation
```

高级函数应使用 `[CmdletBinding()]`、支持 `-Verbose`，修改配置的函数支持 `-WhatIf` 和 `-Confirm`。`jenv` facade 将双连字符参数映射到这些高级函数，但内部函数不重新解析原始命令字符串。

## 11. 会话验收示例

```powershell
Import-Module JEnv
jenv init

jenv shell 8
$env:JAVA_HOME                         # D:\SDKs\amazon-corretto-8
(Get-Command java).Source              # D:\SDKs\amazon-corretto-8\bin\java.exe

jenv shell 17
$env:JAVA_HOME                         # D:\SDKs\temurin-17
($env:Path -split ';')[0]              # D:\SDKs\temurin-17\bin

jenv shell --unset                     # 重新采用 local/global/system
jenv refresh
```

任意次数切换后，之前的 managed bin 不得残留在 PATH 中。
