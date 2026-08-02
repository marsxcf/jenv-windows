# 命令行规范

## 1. 通用语法

```text
jenv <command> [arguments] [options]
jenv help [command]
jenv --version
```

命令和选项名不区分大小写，版本 ID、别名和路径值按原样处理。示例统一使用小写命令。

路径或别名包含 PowerShell 特殊字符时，调用者必须正确引用：

```powershell
jenv add 'D:\Program Files\Java\jdk-21'
```

`jenv` 是 PowerShell 函数而不是独立可执行文件。失败时抛出终止错误，使 `$?` 为 `$false`；模块函数不得调用 `exit` 终止宿主 PowerShell。

## 2. 命令总览

| 命令 | 用途 | 是否修改持久化状态 | 是否同步当前环境 |
| --- | --- | --- | --- |
| `add` | 注册已有 JDK | 是 | 仅当当前未解析版本因此变为可用时 |
| `remove` | 删除注册记录 | 是 | 是 |
| `versions` | 列出 JDK 和当前选择 | 否 | 否 |
| `current` | 显示当前解析结果 | 否 | 否 |
| `global` | 查看或设置用户默认版本 | 是 | 是 |
| `local` | 查看或设置目录版本 | 是 | 是 |
| `shell` | 查看或设置会话版本 | 否 | 是 |
| `home` | 输出 JDK home | 否 | 否 |
| `which` | 输出目标 JDK 中的命令路径 | 否 | 否 |
| `exec` | 使用解析后的 JDK 执行命令 | 否 | 只修改命令调用子作用域 |
| `refresh` | 重新解析并同步环境 | 否 | 是 |
| `doctor` | 诊断安装和环境 | 否 | 否 |
| `init` | 初始化当前会话或管理 Profile | 可选 | 是 |
| `root` | 输出生效的 JENV 根目录 | 否 | 否 |
| `help` | 显示帮助 | 否 | 否 |

## 3. `jenv add`

### 语法

```text
jenv add <jdk-home> [--alias <name>]... [--force]
```

### 行为

1. 将 `<jdk-home>` 解析为规范化绝对路径。
2. 验证 `bin\java.exe` 和 `bin\javac.exe`。
3. 探测版本、厂商和架构。
4. 生成 canonical ID 和自动别名。
5. 添加零个或多个显式 `--alias`。
6. 原子更新注册表。

候选自动别名包括：

- canonical ID，例如 `corretto64-1.8.0.442`。
- 完整规范化版本，例如 `1.8.0.442`。
- 兼容短版本，例如 `1.8`。
- 主版本，例如 `8` 或 `21`。

自动别名已经被其他 JDK 使用时跳过并产生警告，不静默改写。显式别名冲突时失败；`--force` 只允许重绑定显式别名或相同 canonical ID，不重绑定未显式指定的自动别名。

同一路径重复注册且元数据未变化时命令成功并返回 `Unchanged`。路径相同但探测元数据变化时更新记录。

### 示例

```powershell
jenv add 'D:\SDKs\amazon-corretto-8'
jenv add 'D:\SDKs\jdk-21' --alias work21 --alias latest
jenv add 'D:\SDKs\jdk-21.0.5' --alias latest --force
```

### 结果

交互输出至少包含 canonical ID、home 和新增别名。底层 `Register-JenvJdk` 返回结构化对象：

```text
Action       Added | Updated | Unchanged
CanonicalId string
Home        string
Aliases     string[]
Warnings    string[]
```

## 4. `jenv remove`

### 语法

```text
jenv remove <version> [--force]
```

`<version>` 可以是 canonical ID 或别名。命令删除 canonical 记录及所有指向它的别名，但绝不删除 JDK 目录。

如果目标是当前 shell、当前 local 或 global 解析结果，默认失败。`--force` 允许删除，但不会自动修改 `.java-version` 或 global 文件；删除后立即重新解析并报告任何悬空版本引用。

```powershell
jenv remove corretto8
jenv remove corretto8 --force
```

## 5. `jenv versions`

### 语法

```text
jenv versions [--bare] [--json]
```

默认输出一行一个 canonical JDK，当前选择以 `*` 标记：

```text
  corretto64-1.8.0.442  (aliases: 8, 1.8, corretto8)
* temurin64-17.0.12     (set by D:\Work\app\.java-version)
```

- `--bare`：仅输出 canonical ID，不含标记、别名和来源，便于补全或脚本读取。
- `--json`：输出 UTF-8 JSON；不能与 `--bare` 同时使用。

输出顺序按 Java 主版本、完整版本、canonical ID 升序排列；不能依赖 JSON 对象属性顺序。

## 6. `jenv current`

### 语法

```text
jenv current [--json]
```

默认输出：

```text
temurin64-17.0.12 (set by D:\Work\app\.java-version)
```

JSON 结果：

```json
{
  "requestedVersion": "17",
  "canonicalId": "temurin64-17.0.12",
  "home": "D:\\SDKs\\temurin-17",
  "originKind": "Local",
  "originPath": "D:\\Work\\app\\.java-version"
}
```

system 状态下 `canonicalId`、`home` 和 `originPath` 为 `null`。

## 7. `jenv global`

### 语法

```text
jenv global
jenv global <version>
jenv global --unset
```

- 无参数：显示 global 文件中的原始版本表达式；文件不存在时显示 `system`。
- `<version>`：验证版本可解析后写入 `$JENV_ROOT\version`。
- `--unset`：删除 global 文件；文件不存在时幂等成功。

写入或删除后必须完整重新解析并同步当前会话，因为 shell 或 local 仍可能覆盖 global。

## 8. `jenv local`

### 语法

```text
jenv local
jenv local <version>
jenv local --unset
```

- 无参数：显示当前目录向上搜索后实际命中的 local 版本及其文件路径；未命中时显示明确的“未配置”，不能显示 global 值。
- `<version>`：验证版本后在当前目录写入 `.java-version`。
- `--unset`：只删除当前目录下的 `.java-version`，不得删除父目录文件。

`local` 只接受文件系统目录。在注册表、证书等 PowerShell Provider 中调用时，以 `JEnv.Location.NotFileSystem` 失败。

写入文件格式固定为版本表达式加单个 LF：

```text
17\n
```

## 9. `jenv shell`

### 语法

```text
jenv shell
jenv shell <version>
jenv shell --unset
```

- 无参数：显示 `$env:JENV_VERSION`；未设置时报告“未配置 shell 覆盖”。
- `<version>`：验证版本并设置 `$env:JENV_VERSION`。
- `--unset`：删除 `$env:JENV_VERSION`，不存在时幂等成功。

设置后立即同步当前 PowerShell 环境。子 `pwsh` 会继承 `JENV_VERSION`，这是 Process 环境变量的正常继承行为。

## 10. `jenv home`

### 语法

```text
jenv home [<version>]
```

有参数时解析指定版本；无参数时使用完整优先级解析。成功时只输出规范化 JDK home，便于命令替换：

```powershell
$home = jenv home 17
```

system 状态没有受管理的 JDK home，以 `JEnv.Version.SystemHasNoHome` 失败，不能猜测当前系统 Java 的 home。

## 11. `jenv which`

### 语法

```text
jenv which <command> [--version <version>]
```

对受管理版本，只在目标 JDK 的 `bin` 目录中查找：

1. 原始命令名。
2. 命令名加 `.exe`。
3. 命令名加 `.cmd`。
4. 命令名加 `.bat`。

找到后输出完整路径。命令名不得包含目录分隔符或盘符，防止绕过目标 `bin`。system 状态使用 `Get-Command -CommandType Application` 查找当前系统命令。

## 12. `jenv exec`

### 语法

```text
jenv exec [--version <version>] -- <command> [arguments...]
```

`--` 是必需分隔符，确保目标命令参数不会被 jenv 解析。

```powershell
jenv exec -- java -version
jenv exec --version 8 -- javac -encoding UTF-8 Main.java
jenv exec --version 21 -- .\mvnw.cmd test '-Dmessage=a b'
```

行为：

1. 解析显式版本或当前有效版本。
2. 在子作用域保存当前环境。
3. 为目标命令设置 `JAVA_HOME`、`JDK_HOME` 和 `PATH`。
4. 使用 PowerShell 调用运算符及参数数组执行命令，不通过字符串求值。
5. 原样输出目标命令的成功输出和错误输出。
6. 在 `finally` 中恢复调用者环境。

如果目标是 PowerShell 函数、脚本或外部应用，均允许执行；`which` 的限制不适用于 `exec` 的显式相对脚本路径。命令不存在时抛出 `JEnv.Command.NotFound`。

`exec` 不调用 `exit`。外部程序退出后，调用者可以读取 `$LASTEXITCODE`；模块不得用自身文件操作覆盖该值。

## 13. `jenv refresh`

### 语法

```text
jenv refresh [--quiet]
```

忽略解析缓存，重新读取当前目录、版本文件和注册表并同步环境。

- 环境已经正确时幂等成功。
- `--quiet` 抑制正常状态输出，不抑制错误。
- prompt hook 必须使用 `--quiet` 等价的内部调用。

## 14. `jenv doctor`

### 语法

```text
jenv doctor [--json]
```

检查项至少包括：

| 检查项 | 通过条件 |
| --- | --- |
| Platform | Windows、PowerShell Core、版本满足要求。 |
| Root | `JENV_ROOT` 可解析且目录可读写。 |
| Registry | `versions.json` 格式和引用有效。 |
| RegisteredJdks | 每个 home 的 `java.exe` 和 `javac.exe` 存在。 |
| Resolution | 当前版本表达式可以解析。 |
| JavaHome | `JAVA_HOME` 与解析结果一致。 |
| JdkHome | `JDK_HOME` 与解析结果一致。 |
| Path | managed bin 是 PATH 中第一个有效 Java bin 且不重复。 |
| JavaCommand | `Get-Command java` 指向选择的 JDK。 |
| PromptHook | 初始化后 hook 仍然安装。 |

默认输出每项的 `[OK]`、`[WARN]` 或 `[ERROR]`。只要存在 ERROR，命令以终止错误结束；WARN 不导致失败。`doctor` 默认只读，不自动修复。

## 15. `jenv init`

### 语法

```text
jenv init
jenv init --install
jenv init --uninstall
```

- 无参数：初始化当前会话，等价于 `Initialize-Jenv`。
- `--install`：在 `$PROFILE.CurrentUserAllHosts` 安装托管块，再初始化当前会话。
- `--uninstall`：只删除托管块并从当前会话移除 prompt hook；不卸载模块文件，也不删除 JDK 注册表。

托管块固定为：

```powershell
# >>> jenv-windows initialize >>>
Import-Module JEnv
Initialize-Jenv
# <<< jenv-windows initialize <<<
```

安装规则：

- Profile 不存在时创建父目录和 UTF-8 文件。
- 完整托管块已存在时幂等成功。
- 标记不完整或重复时失败，不猜测用户意图。
- 不修改托管块之外的内容。
- 更新前在相同目录创建备份和临时文件；成功替换后保留最近一次备份路径并告知用户。

## 16. `jenv root`、帮助和版本

```text
jenv root
jenv help
jenv help <command>
jenv --version
```

- `root` 输出规范化的生效 `JENV_ROOT`。
- `help` 输出模块自带帮助，不依赖网络。
- `--version` 输出模块语义化版本，例如 `jenv-windows 0.1.0`。

未知命令以 `JEnv.Command.Unknown` 失败，并建议执行 `jenv help`。

## 17. 通用输出约束

- 人类可读输出允许颜色，但检测到重定向或非交互宿主时不得输出 ANSI 控制序列。
- 错误写入 PowerShell Error stream，警告写入 Warning stream，详细诊断写入 Verbose stream。
- 路径展示不得添加多余引号；JSON 中按 JSON 标准转义。
- `--json` 输出只包含一个 JSON 文档，不能混入提示语。
- 正常查询命令不得修改环境或配置。
