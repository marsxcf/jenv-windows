# 总体架构

## 1. 目标

`jenv-windows` 需要在 PowerShell 7 中完成以下工作：

1. 注册本机已有 JDK，不复制 JDK 文件。
2. 通过 global、local、shell 三层配置选择 JDK。
3. 在当前 PowerShell 进程中同步 `JAVA_HOME`、`JDK_HOME` 和 `PATH`。
4. 进入带有 `.java-version` 的项目后自动切换。
5. 为脚本提供不依赖交互式提示符的确定性执行入口。
6. 提供可诊断、可测试、可安全恢复的行为。

## 2. 非目标

- 不成为 JDK 包管理器。
- 不永久修改 Windows 用户或系统环境变量。
- 不替换 PowerShell 的命令解析器。
- 不追求与上游 jenv 的内部目录和插件实现完全一致。
- 不在 0.1 版本实现 `java.exe`、`javac.exe` shim。
- 不为其他 shell 提供兼容层。

## 3. 核心约束

### 3.1 必须运行在当前 PowerShell 进程

独立子进程不能修改父 PowerShell 的环境，因此用户入口必须是 PowerShell 函数。`jenv` 函数由 `JEnv` 模块导出，并在函数内部直接修改 `$env:*`。

### 3.2 只修改 Process 环境

所有 Java 环境修改仅作用于当前 `pwsh` 进程及其之后启动的子进程。不得调用以下 API 写入 `User` 或 `Machine` 目标：

```powershell
[Environment]::SetEnvironmentVariable($Name, $Value, 'User')
[Environment]::SetEnvironmentVariable($Name, $Value, 'Machine')
```

### 3.3 持久化配置与会话状态分离

- 注册表、global 版本和 `.java-version` 是持久化状态。
- shell 版本通过 `$env:JENV_VERSION` 保存，只存在于当前进程及其子进程。
- 原始环境、managed bin、prompt hook 等属于模块会话状态，不写入配置文件。

### 3.4 不执行配置文件内容

`versions.json`、`version`、`.java-version` 和 JDK `release` 文件都只能解析，不能通过 `Invoke-Expression`、点调用或动态 PowerShell 代码执行。

## 4. 逻辑架构

```text
┌─────────────────────────────────────────────────────────────┐
│ PowerShell 7                                                │
│                                                             │
│  jenv facade / exported cmdlets                             │
│                │                                            │
│                ▼                                            │
│  Command services                                           │
│  add, remove, global, local, shell, exec, doctor, init       │
│        │                │                 │                  │
│        ▼                ▼                 ▼                  │
│  JDK registry      Version resolver    Session integration  │
│  metadata/aliases  shell/local/global  env/PATH/prompt      │
│        │                │                 │                  │
│        └────────────────┼─────────────────┘                  │
│                         ▼                                    │
│  Infrastructure: filesystem, JSON, mutex, process execution │
└─────────────────────────────────────────────────────────────┘
```

### 4.1 用户接口层

提供两类入口：

- `jenv <subcommand>`：与上游 jenv 相近的交互式入口。
- PowerShell 高级函数：供测试、脚本和未来扩展使用。

`jenv` 只负责参数分派和展示，不应包含版本解析或文件写入逻辑。

### 4.2 命令服务层

每个子命令对应一个明确用例。服务层负责：

- 验证参数。
- 调用注册表或解析器。
- 执行持久化变更。
- 在需要时调用会话同步。
- 返回结构化结果或抛出带稳定错误 ID 的错误。

### 4.3 JDK 注册表

注册表维护 JDK 元数据和别名映射。它不以符号链接表达版本，原因是 Windows 上符号链接可能受权限或开发者模式影响。

注册流程：

```text
输入路径
  → 规范化绝对路径
  → 验证 java.exe / javac.exe
  → 读取 release 文件
  → 必要时执行 java -XshowSettings:properties -version
  → 生成 canonical ID 与候选别名
  → 检查冲突
  → 原子写入 versions.json
```

### 4.4 版本解析器

解析器是无副作用组件。输入为当前目录、`JENV_VERSION`、JENV 根目录和注册表快照；输出为：

```text
RequestedVersion  用户或配置文件中的原始字符串
CanonicalId       解析后的唯一 ID；system 时为空
Home              JDK 绝对路径；system 时为空
OriginKind        Shell | Local | Global | System
OriginPath        .java-version 或 global 文件路径；其他情况为空
```

完整规则见[配置、存储与版本解析](./storage-and-resolution.md)。

### 4.5 会话集成

会话集成负责在不覆盖其他工具运行期修改的前提下：

- 移除上一个 managed bin。
- 将目标 JDK `bin` 添加到 `PATH` 首位。
- 设置 `JAVA_HOME` 和 `JDK_HOME`。
- 在 system 状态下恢复初始化前的值。
- 安装、调用和移除 prompt hook。

完整规则见[PowerShell 会话集成](./powershell-integration.md)。

## 5. 关键流程

### 5.1 模块初始化

```text
Import-Module JEnv
  → 校验 PowerShell 版本与 Windows 平台
  → 计算 JENV_ROOT
  → 加载函数，但不修改 Profile

jenv init
  → 捕获当前 JAVA_HOME/JDK_HOME
  → 解析当前版本
  → 同步当前进程环境
  → 安装幂等 prompt hook
```

模块导入和初始化分离，使 CI、单元测试和非交互脚本可以导入函数而不自动修改环境。

### 5.2 注册 JDK

`jenv add <home>` 完成注册后不自动改变 global/local/shell 选择。如果当前解析结果已经引用此次新增的别名，可以执行一次同步；否则保持当前环境不变。

JDK 元数据探测顺序：

1. 解析 `<home>\release`。
2. 缺失必要字段时执行 `<home>\bin\java.exe -XshowSettings:properties -version`。
3. 仍无法获得版本时注册失败。

执行外部程序时使用 `System.Diagnostics.ProcessStartInfo.ArgumentList`，不拼接可执行命令字符串。

### 5.3 设置版本

- `global` 写入用户配置，然后同步当前会话。
- `local` 写入当前目录 `.java-version`，然后同步当前会话。
- `shell` 设置 `$env:JENV_VERSION`，然后同步当前会话。
- `--unset` 删除对应层级后重新执行完整解析，不能简单回退到 system。

### 5.4 自动目录切换

交互式会话通过 prompt hook 在每次显示提示符前解析当前目录。只有解析指纹变化时才更新环境。

解析指纹至少包括：

- `$env:JENV_VERSION`。
- 当前文件系统目录。
- 生效版本文件的完整路径、长度和最后写入时间。
- `versions.json` 的最后写入时间。

正确性不依赖缓存；缓存失效或计算失败时必须重新解析。

### 5.5 确定性命令执行

交互式 prompt hook 不会在同一条 PowerShell 语句的 `Set-Location` 与后续命令之间运行，例如：

```powershell
Set-Location D:\Work\app; java -version
```

脚本和连续命令应使用：

```powershell
jenv exec -- java -version
```

`exec` 在子作用域中解析当前目录、设置环境并调用目标命令，结束后恢复调用者会话环境。它不依赖 prompt hook。

## 6. 模块状态模型

模块内部维护一个会话状态对象：

```text
Initialized             是否完成初始化
OriginalJavaHome        初始化前是否存在及其值
OriginalJdkHome         初始化前是否存在及其值
ManagedJavaHome         最近一次由 jenv 写入的 JAVA_HOME
ManagedJdkHome          最近一次由 jenv 写入的 JDK_HOME
ManagedBin              最近一次由 jenv 注入的 PATH 项
PreviousPrompt          初始化时捕获的 prompt ScriptBlock
PromptHook              jenv 安装的 prompt ScriptBlock
LastResolutionFingerprint
```

状态只存在于当前模块实例。`Remove-Module JEnv` 时模块应尝试注销自身 prompt hook，但只能在当前 prompt 仍然是 jenv hook 时恢复旧 prompt，不能覆盖模块初始化之后由其他工具安装的新 prompt。

## 7. 错误模型

内部函数使用终止错误表达失败，不调用 `exit`。错误必须包含稳定的 `FullyQualifiedErrorId`，例如：

| 错误 ID | 含义 |
| --- | --- |
| `JEnv.Platform.Unsupported` | 非 Windows 或非 PowerShell Core。 |
| `JEnv.PowerShellVersion.Unsupported` | PowerShell 低于最低版本。 |
| `JEnv.Jdk.InvalidHome` | 路径不是有效 JDK home。 |
| `JEnv.Jdk.ProbeFailed` | 无法取得版本元数据。 |
| `JEnv.Version.NotInstalled` | 版本或别名不存在。 |
| `JEnv.VersionFile.Invalid` | 版本文件格式非法。 |
| `JEnv.Alias.Conflict` | 显式别名已由其他 JDK 使用。 |
| `JEnv.Registry.Invalid` | `versions.json` 无法解析或不符合模式。 |
| `JEnv.Registry.LockTimeout` | 规定时间内无法获得写锁。 |
| `JEnv.Profile.UpdateFailed` | 无法安全更新 PowerShell Profile。 |
| `JEnv.Command.NotFound` | `exec` 或 `which` 找不到目标命令。 |

面向用户的错误信息需要同时说明失败对象、来源以及可执行的修复动作。

## 8. 安全与可靠性决策

- 所有配置文件均按数据解析，不执行其中内容。
- JDK 路径必须是绝对文件系统路径，且不得包含 `;`、CR 或 LF。
- 所有配置写入使用同根目录临时文件加原子替换。
- 修改 `versions.json` 前获取基于规范化 `JENV_ROOT` 的命名互斥锁。
- 外部进程执行不经过 `Invoke-Expression`。
- Profile 安装使用明确的托管标记块，不替换用户其他内容。
- `doctor` 可以报告问题，但除显式修复参数外不得修改配置。
- 日志和错误不得输出凭据或完整环境变量集合。

## 9. 后续演进

以下能力不属于 0.1 契约，可在保持当前存储兼容的前提下增加：

- `jenv discover` 扫描常见 JDK 安装位置和注册表。
- PowerShell 参数补全。
- PowerShell Gallery、Scoop、WinGet 发布。
- 自包含 .NET shim，在执行 `java.exe` 时动态解析 `.java-version`。
- 独立的 CMD 适配器。

任何 shim 都应复用同一份 `versions.json` 和版本解析规则，不能形成第二套选择逻辑。
