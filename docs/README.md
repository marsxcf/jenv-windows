# jenv-windows 技术文档

本文档集定义 `jenv-windows` 的产品边界、技术架构、命令行为、持久化格式、实现约束和验收标准。它是 0.1 版本开发与评审的基准。

## 文档导航

- [总体架构](./architecture.md)：目标、边界、组件、关键流程和技术决策。
- [命令行规范](./command-reference.md)：完整命令、参数、输出和错误行为。
- [配置、存储与版本解析](./storage-and-resolution.md)：目录布局、JSON 模式、优先级和原子写入。
- [PowerShell 会话集成](./powershell-integration.md)：环境变量、PATH、Profile 和自动切换。
- [开发规范与实施计划](./development.md)：代码布局、模块 API、安全约束和开发阶段。
- [测试与验收](./testing.md)：测试矩阵、关键用例、CI 和发布门槛。

## 产品定位

`jenv-windows` 是面向 Windows PowerShell 7 的 JDK 版本选择器。它管理已经安装在本机上的 JDK，但不下载、不安装也不升级 JDK。

它提供三层版本选择：

```text
shell（当前 pwsh 会话）
        > local（当前目录或父目录的 .java-version）
        > global（当前用户默认版本）
        > system（jenv 初始化前的环境）
```

选择某个 JDK 后，工具在当前 PowerShell 进程中设置：

```powershell
$env:JAVA_HOME = $SelectedJdkHome
$env:JDK_HOME = $SelectedJdkHome
$env:Path = "$SelectedJdkHome\bin;$env:Path"
```

实际实现必须安全移除上一次由 jenv 注入的 `bin` 路径，不能让 `PATH` 随切换次数增长。

## 支持范围

0.1 版本支持：

- Windows 10/11 和 Windows Server 上的 PowerShell 7.4 或更高版本。
- PowerShell Core（`PSEdition = Core`）。
- x64、ARM64 PowerShell；被注册 JDK 的架构只记录和展示，不限制宿主架构。
- 当前 PowerShell 进程级环境变量。
- `.java-version` 项目文件。
- 用户级全局配置，默认位于 `%USERPROFILE%\.jenv`。
- 路径中包含空格、Unicode 字符和不同大小写。

0.1 版本不支持：

- Windows PowerShell 5.1。
- `cmd.exe`、Git Bash、WSL、Cygwin 或其他 shell。
- 修改 User 或 Machine 级 `JAVA_HOME`/`PATH`。
- JDK 下载、安装和自动升级。
- macOS、Linux。
- Java 命令 shim 或代理可执行文件。
- 上游 jenv 插件系统。

Windows Terminal 是终端宿主而不是 shell；当其 Profile 使用 PowerShell 7 时即受支持。

## 快速使用场景

```powershell
# 导入并初始化当前会话
Import-Module JEnv
jenv init

# 注册已经安装的 JDK
jenv add 'D:\SDKs\amazon-corretto-8' --alias corretto8
jenv add 'D:\SDKs\temurin-17' --alias temurin17

# 设置默认版本
jenv global temurin17

# 在项目目录固定 Java 8
Set-Location D:\Work\legacy-app
jenv local corretto8

# 仅在当前 pwsh 会话临时覆盖
jenv shell temurin17
jenv shell --unset

# 查看选择结果
jenv current
$env:JAVA_HOME
java -version
```

## 术语

| 术语 | 定义 |
| --- | --- |
| JDK home | 同时包含 `bin\java.exe` 和 `bin\javac.exe` 的目录。 |
| 注册 | 记录已有 JDK 的绝对路径及其版本、厂商、架构和别名。 |
| 版本表达式 | 可解析到某个已注册 JDK 的 ID 或别名，例如 `17`、`temurin17`。 |
| canonical ID | 注册记录的稳定唯一标识，例如 `corretto64-1.8.0.442`。 |
| origin | 当前版本选择来自 shell、某个 `.java-version`、global 文件或 system。 |
| managed bin | 当前由 jenv 添加到 `PATH` 首位的 JDK `bin` 目录。 |
| system | 不选择已注册 JDK，并尽可能恢复 jenv 初始化前的 Java 环境。 |

## 规范优先级

文档之间出现冲突时，优先级如下：

1. [命令行规范](./command-reference.md)定义用户可观察行为。
2. [配置、存储与版本解析](./storage-and-resolution.md)定义持久化与解析行为。
3. [PowerShell 会话集成](./powershell-integration.md)定义会话修改行为。
4. [总体架构](./architecture.md)和其他文档提供设计背景。

实现改变任何对外行为或持久化格式时，必须在同一变更中更新相应文档。
