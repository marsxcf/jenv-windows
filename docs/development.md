# 开发规范与实施计划

## 1. 运行时与工具链

运行时要求：

- Windows。
- PowerShell 7.4 或更高版本。
- `PSEdition = Core`。
- 运行时不依赖第三方 PowerShell 模块。

开发依赖：

- Pester 5：测试。
- PSScriptAnalyzer：静态检查。
- Git：版本控制。

模块必须可以离线运行。JDK 注册、切换和诊断不得依赖网络。

## 2. 推荐仓库布局

```text
jenv-windows\
├─ docs\
│  ├─ README.md
│  ├─ architecture.md
│  ├─ command-reference.md
│  ├─ storage-and-resolution.md
│  ├─ powershell-integration.md
│  ├─ development.md
│  └─ testing.md
├─ src\
│  └─ JEnv\
│     ├─ JEnv.psd1
│     ├─ JEnv.psm1
│     ├─ Public\
│     │  ├─ Initialize-Jenv.ps1
│     │  ├─ Invoke-JenvFacade.ps1
│     │  ├─ Invoke-JenvCommand.ps1
│     │  ├─ Register-JenvJdk.ps1
│     │  ├─ Sync-JenvEnvironment.ps1
│     │  ├─ Test-JenvInstallation.ps1
│     │  └─ VersionCommands.ps1
│     └─ Private\
│        ├─ Environment.ps1
│        ├─ Errors.ps1
│        ├─ JdkProbe.ps1
│        ├─ Json.ps1
│        ├─ Paths.ps1
│        ├─ Profile.ps1
│        ├─ Registry.ps1
│        ├─ Session.ps1
│        └─ VersionResolver.ps1
├─ tests\
│  ├─ Fixtures\
│  ├─ Unit\
│  ├─ Integration\
│  └─ Acceptance\
├─ build.ps1
├─ install.ps1
├─ CHANGELOG.md
├─ LICENSE
└─ README.md
```

`JEnv.psm1` 按确定顺序点加载 Private，再加载 Public，最后显式调用 `Export-ModuleMember`。不能依赖 `Get-ChildItem` 的隐式文件排序。

## 3. 模块边界

### 3.1 Public

Public 函数是受兼容性约束的 PowerShell API：

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

具体导出列表以 `JEnv.psd1` 为唯一发布清单。新增导出函数需要文档、测试和 changelog。

### 3.2 Private

Private 函数不能被用户依赖，可以在 minor 版本重构。主要职责：

- 路径和字符串规范化。
- 注册表读取、验证、锁和原子写入。
- JDK 元数据探测。
- local/global/shell 解析。
- 环境快照、应用和恢复。
- prompt 与 Profile 管理。
- ErrorRecord 创建。

### 3.3 数据对象

优先使用带 `PSTypeNames` 的 `PSCustomObject`，例如：

```powershell
$result.PSObject.TypeNames.Insert(0, 'JEnv.ResolvedVersion')
```

0.1 不建议使用 PowerShell class 作为跨文件公共模型，因为 class 重载和模块 `-Force` 重载会增加开发会话复杂度。

关键对象：

```text
JEnv.Jdk
JEnv.ResolvedVersion
JEnv.RegistrationResult
JEnv.DiagnosticResult
JEnv.EnvironmentSnapshot
```

对象属性使用 PascalCase；JSON 持久化和 `--json` 输出使用 camelCase，并通过显式映射生成，不能直接序列化所有内部属性。

## 4. 编码规范

每个脚本文件：

```powershell
Set-StrictMode -Version Latest
```

约束：

- 使用 `[CmdletBinding()]` 和显式参数类型。
- 修改操作实现 `SupportsShouldProcess`。
- 不在模块作用域修改调用者的 `$ErrorActionPreference`、`$ProgressPreference` 或其他 preference 变量。
- 调用可能产生非终止错误的 cmdlet 时局部使用 `-ErrorAction Stop`。
- 不使用别名，如 `%`、`?`、`ls`、`cat`。
- 不使用 `Invoke-Expression` 处理参数、路径或配置。
- 不使用字符串拼接构造外部命令；使用调用运算符与数组，或 `ProcessStartInfo.ArgumentList`。
- 不使用 `exit`；失败抛出 ErrorRecord。
- 不依赖当前 Culture 进行 ID、版本和路径比较。
- 所有文件系统修改使用 `-LiteralPath` 或对应的 .NET 精确路径 API。
- 删除操作不使用通配符。
- 所有 disposable 对象在 `finally` 中释放。
- 对 mutex、进程和文件句柄设置有限等待时间。

## 5. 错误实现

集中通过私有工厂创建错误：

```powershell
New-JenvErrorRecord `
    -Id 'JEnv.Version.NotInstalled' `
    -Message "Java version '$Version' is not registered (set by $Origin)." `
    -Category ObjectNotFound `
    -TargetObject $Version
```

错误 ID 是自动化契约，消息不是。测试应断言 `FullyQualifiedErrorId` 和关键 TargetObject，而不是完整英文句子。

0.1 用户消息使用英文，技术文档可以提供中文说明。未来本地化不得改变错误 ID、对象属性或 JSON 字段。

错误信息应回答：

1. 什么操作失败。
2. 哪个路径、版本或文件导致失败。
3. 配置来自哪里。
4. 用户下一步可以执行什么命令。

## 6. 注册表实现分层

建议拆为：

```text
Read-JenvRegistry(path)              读取、解析、模式验证
Test-JenvRegistry(registry)          逻辑引用验证
Invoke-WithJenvRegistryLock(root)    并发互斥
Write-JenvRegistryAtomic(registry)   编码、备份、原子替换
Update-JenvRegistry(mutation)        锁内重读、修改、revision + 1
```

业务代码不能直接调用 `ConvertFrom-Json` 后覆盖文件。所有写入统一经过 `Update-JenvRegistry`。

JSON 深度参数必须显式指定，避免 PowerShell 默认深度截断。序列化之前按稳定顺序构造对象，减少无意义 diff。

## 7. JDK 探测实现

探测分为纯解析和 I/O：

```text
Read-JenvReleaseFile       解析 release 文本
Invoke-JenvJavaProbe       执行 java 并捕获属性
ConvertTo-JenvJdkMetadata  合并、规范化和验证字段
Get-JenvCanonicalId        生成稳定 ID
Get-JenvCandidateAliases   生成候选别名
```

这样单元测试可以直接提供文本，不依赖本机真实 JDK。

如果 release 和 Java 进程对同一必要字段给出不同值：

- `version` 以运行时 Java 进程为准。
- `vendor` 和 `architecture` 优先使用 release，除非其值无法识别。
- 通过 Verbose stream 记录差异。

## 8. 版本解析实现

解析器保持只读和确定性：

```powershell
Resolve-JenvVersion `
    -Registry $registry `
    -Root $root `
    -CurrentDirectory $directory `
    -ShellVersion $env:JENV_VERSION
```

不得在解析器内部：

- 创建目录或文件。
- 修改环境变量。
- 自动修复别名。
- 静默选择“最接近”的版本。

解析结果必须带 origin，所有调用者复用同一结果，避免 `JAVA_HOME`、展示和 `exec` 分别解析出不同版本。

## 9. 会话实现

会话状态保存在模块 script scope 的单一对象中。所有修改必须通过以下边界：

```text
Get-JenvSessionState
Initialize-JenvSessionState
Set-JenvProcessEnvironment
Restore-JenvProcessEnvironment
Enable-JenvPromptHook
Disable-JenvPromptHook
```

不能让各命令直接拼接 `$env:Path`。环境算法以[PowerShell 会话集成](./powershell-integration.md)为准。

## 10. Facade 参数分派

`jenv` 接收第一个位置参数作为子命令，其余参数保持数组：

```powershell
function jenv {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string] $Command = 'help',

        [Parameter(ValueFromRemainingArguments)]
        [object[]] $Arguments
    )

    Invoke-JenvFacade -Command $Command -Arguments $Arguments
}
```

每个子命令使用独立解析器将 GNU 风格的 `--alias`、`--unset` 等转换成高级函数参数。解析器必须：

- 支持 `--` 终止选项解析。
- 拒绝未知选项和缺失值。
- 不重新拆分已经由 PowerShell 解析好的字符串。
- 保持 `exec` 参数的顺序、类型和边界。

## 11. 帮助和注释

- 每个 Public 函数提供 comment-based help。
- `jenv help <command>` 的内容从同一份命令元数据生成，避免维护两套语法。
- 仓库根 README 只放安装和快速使用；行为细节链接到 `docs`。
- 示例必须能在 PowerShell 7 中直接复制执行。

## 12. 构建与安装

`build.ps1` 负责：

1. 清理专用构建输出目录，不触碰源代码和用户目录。
2. 运行 PSScriptAnalyzer。
3. 运行 Pester。
4. 将模块复制到 `artifacts\JEnv\<version>`。
5. 执行 `Test-ModuleManifest`。
6. 生成发布压缩包和校验值。

`install.ps1` 是开发/本地安装器：

- 默认安装到当前 PowerShell 7 的 CurrentUser 模块路径。
- 支持 `-WhatIf`。
- 已有同版本时要求 `-Force`。
- 不自动编辑 Profile；用户显式执行 `jenv init --install`。
- 不修改 User/Machine PATH。

发布到 PowerShell Gallery 后推荐使用 `Install-PSResource`，本地安装器仍用于仓库开发。

## 13. 版本与兼容性

采用 Semantic Versioning：

- patch：bug 修复，不改变命令和 schema 契约。
- minor：向后兼容的新命令、选项或 schema 1 可选字段。
- major：破坏命令、Public API 或持久化格式的变化。

`schemaVersion` 与模块版本独立。模块升级需要显式迁移 schema 时，先创建备份；迁移失败不得改写原文件。

## 14. 实施阶段

### 阶段 A：核心数据与解析

- 模块骨架、清单和错误工厂。
- JENV_ROOT、路径规范化。
- registry schema、读取、验证、锁和原子写入。
- release/Java 元数据探测。
- add、remove、versions。
- shell/local/global/system 解析。

完成标准：不修改会话环境也能稳定注册和解析版本。

### 阶段 B：PowerShell 会话

- 环境快照和所有权恢复。
- PATH 切换算法。
- shell/local/global/current/home/which/refresh。
- `exec` 环境隔离。

完成标准：所有环境验收场景通过，重复切换无 PATH 泄漏。

### 阶段 C：交互体验

- Initialize-Jenv。
- prompt hook。
- Profile 安装/卸载。
- doctor 和帮助。
- facade 输出、JSON 输出。

完成标准：新 PowerShell 7 会话能自动采用 global/local 配置。

### 阶段 D：发布质量

- PSScriptAnalyzer 清零要求级问题。
- 完整 Pester 矩阵。
- 构建、安装、卸载和发布包。
- README、CHANGELOG、许可证。

## 15. Definition of Done

一个功能只有同时满足以下条件才算完成：

- 用户可观察行为符合文档。
- 有正常、边界和失败测试。
- 不破坏会话恢复和 PATH 幂等性。
- 新错误有稳定错误 ID。
- 新持久化字段有模式与兼容性说明。
- Public API 有帮助文本。
- PSScriptAnalyzer、Pester 和模块清单验证通过。
- 相关技术文档和 changelog 已更新。
