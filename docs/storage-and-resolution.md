# 配置、存储与版本解析

## 1. JENV 根目录

根目录按以下顺序确定：

1. 如果 `$env:JENV_ROOT` 存在且非空，使用其值。
2. 否则使用 `Join-Path $HOME '.jenv'`。

`JENV_ROOT` 必须能转换为绝对文件系统路径。相对路径、非 FileSystem Provider 路径、包含 CR/LF 的路径均视为非法。规范化后移除非根目录所必需的尾部分隔符，但不改变磁盘上的大小写。

只读命令遇到根目录不存在时，将其视为空注册表和未配置 global；写命令按需创建目录。模块导入本身不得创建文件。

## 2. 目录布局

```text
%USERPROFILE%\.jenv\
├─ versions.json          # JDK 注册表和别名
├─ version                # global 版本表达式
├─ backups\               # 配置替换产生的最近备份
└─ tmp\                   # 同卷临时文件；成功或失败后清理
```

0.1 版本不创建上游 jenv 的 `versions` 符号链接目录和 `shims` 目录。

项目目录中可存在：

```text
<project>\.java-version   # local 版本表达式
```

## 3. 环境变量

| 变量 | 用户可设置 | 持久化 | 说明 |
| --- | --- | --- | --- |
| `JENV_ROOT` | 是 | 由调用者决定 | 覆盖默认根目录。 |
| `JENV_VERSION` | 是 | 当前进程及子进程 | shell 层版本表达式。 |
| `JAVA_HOME` | 可手动设置 | 当前进程 | 初始化后由 jenv 管理，但采用所有权保护。 |
| `JDK_HOME` | 可手动设置 | 当前进程 | 与选中 JDK home 一致。 |
| `PATH`/`Path` | 可手动设置 | 当前进程 | jenv 只管理自己插入的一个 `bin` 项。 |

PowerShell 在 Windows 上以不区分大小写的方式访问环境变量。实现内部统一使用 `$env:Path`，但不能假设外部展示的名称大小写。

## 4. `versions.json` 模式

文件编码为无 BOM UTF-8，使用 LF。顶层模式：

```json
{
  "schemaVersion": 1,
  "revision": 3,
  "jdks": {
    "corretto64-1.8.0.442": {
      "home": "D:\\SDKs\\amazon-corretto-8",
      "version": "1.8.0_442",
      "normalizedVersion": "1.8.0.442",
      "major": 8,
      "vendor": "Amazon.com Inc.",
      "vendorId": "corretto",
      "architecture": "x64",
      "registeredAt": "2026-08-02T03:20:00Z",
      "updatedAt": "2026-08-02T03:20:00Z"
    },
    "temurin64-17.0.12": {
      "home": "D:\\SDKs\\temurin-17",
      "version": "17.0.12+7",
      "normalizedVersion": "17.0.12",
      "major": 17,
      "vendor": "Eclipse Adoptium",
      "vendorId": "temurin",
      "architecture": "x64",
      "registeredAt": "2026-08-02T03:22:00Z",
      "updatedAt": "2026-08-02T03:22:00Z"
    }
  },
  "aliases": {
    "8": "corretto64-1.8.0.442",
    "1.8": "corretto64-1.8.0.442",
    "1.8.0.442": "corretto64-1.8.0.442",
    "corretto8": "corretto64-1.8.0.442",
    "17": "temurin64-17.0.12",
    "17.0.12": "temurin64-17.0.12",
    "temurin17": "temurin64-17.0.12"
  }
}
```

### 4.1 字段约束

| 字段 | 约束 |
| --- | --- |
| `schemaVersion` | 必须为整数 `1`。未知主模式版本必须拒绝读取。 |
| `revision` | 非负整数，每次成功写入加一。用于诊断，不用于并发控制。 |
| `jdks` | canonical ID 到 JDK 记录的映射。 |
| `home` | 规范化绝对路径；比较时使用 `OrdinalIgnoreCase`。 |
| `version` | 从 JDK 元数据获得的原始 Java 版本。 |
| `normalizedVersion` | 用于 ID、别名和排序的规范化版本。 |
| `major` | 正整数；Java `1.8.x` 对应 `8`。 |
| `vendor` | 探测到的展示名称。 |
| `vendorId` | 稳定的小写厂商标识。 |
| `architecture` | `x86`、`x64`、`arm64` 或 `unknown`。 |
| `registeredAt` | 首次注册时的 UTC ISO 8601 时间。 |
| `updatedAt` | 最近更新时的 UTC ISO 8601 时间。 |
| `aliases` | 别名到 canonical ID 的映射。目标必须存在于 `jdks`。 |

canonical ID 本身也必须能直接解析，因此不要求在 `aliases` 中重复保存 canonical ID。

所有 ID 和别名按 `OrdinalIgnoreCase` 比较。文件中出现仅大小写不同的重复 ID 或别名属于注册表损坏。

### 4.2 前向兼容

读取 schema 1 时允许对象中存在未知属性。写入已读取的注册表时应保留未知属性，避免较旧的 0.1.x 工具破坏同一 schema 内新增的可选数据。未知 `schemaVersion` 必须失败，不能尝试降级写回。

## 5. 版本表达式

版本表达式用于 `$env:JENV_VERSION`、`version` 和 `.java-version`。格式为：

```regex
^[A-Za-z0-9][A-Za-z0-9._+\-]{0,127}$
```

保留值 `system` 表示不使用注册 JDK。它不允许作为 JDK ID 或别名。

版本文件规则：

- UTF-8，可有或没有 BOM。
- 读取时移除文件末尾的 CR/LF，再对整体执行一次空白 Trim。
- Trim 后必须只有一个符合格式的版本表达式。
- 不支持注释、多版本、引号或 PowerShell 表达式。
- 空文件和多行内容均为 `JEnv.VersionFile.Invalid`。

## 6. JDK 元数据探测

### 6.1 路径验证

注册前必须验证：

```text
<home>\bin\java.exe
<home>\bin\javac.exe
```

两者都必须是文件。0.1 只注册 JDK，不注册只有 `java.exe` 的 JRE。

JDK home 规范化使用 `[IO.Path]::GetFullPath()` 和文件系统存在性检查。路径包含 `;`、CR 或 LF 时拒绝注册，因为该路径无法安全作为 Windows `PATH` 单项表达。

### 6.2 `release` 文件

优先读取 `<home>\release`。常用字段包括：

```text
JAVA_VERSION="17.0.12"
IMPLEMENTOR="Eclipse Adoptium"
OS_ARCH="x86_64"
```

解析器只接受 `KEY=VALUE`，去除包围整个值的一对双引号并解码 release 文件规定的基本转义。不得将文件作为 PowerShell 脚本执行。

### 6.3 Java 进程回退

当 `release` 缺少版本、厂商或架构时运行：

```text
<home>\bin\java.exe -XshowSettings:properties -version
```

使用 `ProcessStartInfo`：

- `UseShellExecute = false`。
- 参数通过 `ArgumentList` 添加。
- 同时异步读取 stdout 和 stderr，避免管道死锁。
- 默认超时 10 秒；超时后终止进程树。
- 非零退出码可以接受，但必须成功解析到必要属性；否则探测失败。

### 6.4 版本规范化

- Java 8 及更早形式 `1.8.0_442`：major 为第二段 `8`，规范化版本为 `1.8.0.442`。
- Java 9 及以后：major 为第一段，例如 `17.0.12+7` 的 major 为 `17`，canonical 版本部分为去构建元数据后的 `17.0.12`。
- 无法可靠解析正整数 major 时注册失败。

初始厂商映射：

| 检测文本 | `vendorId` |
| --- | --- |
| `Amazon Corretto`、`Amazon.com` | `corretto` |
| `Eclipse Adoptium`、`Temurin` | `temurin` |
| `Oracle` | `oracle` |
| `Azul`、`Zulu` | `zulu` |
| `Microsoft` | `microsoft` |
| `BellSoft`、`Liberica` | `liberica` |
| `SAP`、`SapMachine` | `sapmachine` |
| `GraalVM` | `graalvm` |
| 其他 | `openjdk` 或 `other`，根据运行时文本判断 |

架构映射：`amd64`/`x86_64` → `x64`，`aarch64` → `arm64`，`x86`/`i386` → `x86`。

canonical ID 格式：

```text
<vendorId><architecture-bits>-<normalizedVersion>
```

其中 `x64` 映射为 `64`、`x86` 映射为 `32`、`arm64` 映射为 `arm64`、unknown 省略架构。例如：

```text
corretto64-1.8.0.442
temurin64-17.0.12
microsoftarm64-21.0.4
```

## 7. local 文件发现

仅当当前位置属于 `FileSystem` Provider 时执行 local 搜索：

1. 检查当前目录的 `.java-version`。
2. 若不存在，检查父目录。
3. 持续到当前卷的文件系统根目录。
4. 第一个命中的文件生效。

搜索使用用户看到的逻辑路径。遇到目录 junction 时不主动展开到目标物理路径，避免 local 来源显示与当前工作路径不一致。

0.1 不读取 `.jenv-version`，也不读取 Maven、Gradle 或 IDE 专用配置。

## 8. 完整解析算法

```text
Resolve-JenvVersion(currentDirectory):
    if JENV_VERSION exists and is not empty:
        requested = validate(JENV_VERSION)
        origin = Shell
    else if nearest .java-version exists:
        requested = readVersionFile(localFile)
        origin = Local(localFile)
    else if JENV_ROOT\version exists:
        requested = readVersionFile(globalFile)
        origin = Global(globalFile)
    else:
        requested = system
        origin = System

    if requested equals system, OrdinalIgnoreCase:
        return System result

    if requested matches canonical ID:
        id = matching canonical ID
    else if requested matches alias:
        id = aliases[requested]
    else:
        throw JEnv.Version.NotInstalled with origin

    validate registry record and current JDK files
    return resolved JDK and origin
```

高优先级配置存在但非法或未注册时必须失败，不得静默回退到低优先级。这能及时暴露项目配置错误。

## 9. 读取一致性和并发写入

### 9.1 命名互斥锁

注册表和 global 配置写入使用当前用户会话范围的命名互斥锁：

```text
Local\JEnv-<SHA256(normalized JENV_ROOT) 前 32 个十六进制字符>
```

默认等待 5 秒。超时抛出 `JEnv.Registry.LockTimeout`。获得锁后必须重新读取目标文件，避免基于旧快照覆盖其他进程的更新。

### 9.2 原子替换

写入步骤：

1. 在目标文件同一目录创建随机临时文件。
2. 使用无 BOM UTF-8 完整写入。
3. Flush 文件内容并关闭句柄。
4. 目标存在时使用 `[IO.File]::Replace()`，并将旧文件保存到 `backups`。
5. 目标不存在时使用同卷 `[IO.File]::Move()`。
6. 在 `finally` 中清理残留临时文件并释放 mutex。

`.java-version` 位于项目目录，不使用 JENV 根锁，但仍采用同目录临时文件加替换。删除 `--unset` 时使用精确文件路径，不使用通配符。

### 9.3 损坏处理

- JSON 无法解析、schema 不支持或引用不一致时，所有注册表写命令失败。
- 不得把损坏文件当作空注册表覆盖。
- `doctor` 报告具体问题和最近备份路径。
- 0.1 不提供自动恢复；用户确认后可从备份手工恢复。

## 10. 排序和比较

- 路径、ID、别名：`StringComparer.OrdinalIgnoreCase`。
- JSON 属性名：模式字段区分大小写；ID/别名映射键不区分大小写验证唯一性。
- 版本排序：按 major 数值，再按可解析版本段数值，最后按 canonical ID OrdinalIgnoreCase。
- 展示别名：OrdinalIgnoreCase 排序，canonical ID 不重复展示为别名。

不得使用当前系统 Culture 执行 ID、别名和路径比较，避免不同区域设置产生不同行为。
