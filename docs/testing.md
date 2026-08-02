# 测试与验收

## 1. 测试目标

测试必须证明：

- 版本注册和别名解析正确、确定且不依赖用户机器状态。
- shell、local、global、system 优先级严格一致。
- `JAVA_HOME`、`JDK_HOME`、`PATH` 在当前 PowerShell 进程中正确切换和恢复。
- prompt、Profile、并发和损坏配置不会破坏用户会话。
- 路径与参数不会被当作 PowerShell 代码执行。
- 仅支持 PowerShell 7 的边界得到明确验证。

## 2. 测试层次

```text
Unit          纯函数和单个 I/O 边界，速度快
Integration   模块组件与临时文件系统/子 pwsh 协作
Acceptance    从用户命令入口验证完整场景
Static        PSScriptAnalyzer、清单、文档链接和格式
```

## 3. 测试隔离

每个测试使用独立临时目录：

```text
<temp>\root       临时 JENV_ROOT
<temp>\project    项目目录
<temp>\jdks       假 JDK 目录
<temp>\profile    Profile 测试文件
```

测试开始前保存，结束后在 `finally`/`AfterEach` 恢复：

```text
JENV_ROOT
JENV_VERSION
JAVA_HOME
JDK_HOME
Path
当前位置
全局 prompt ScriptBlock
```

环境和 prompt 测试不得并行运行。纯解析测试可以并行，但不得共享 JENV_ROOT。

测试不得读取或写入开发者真实的 `%USERPROFILE%\.jenv` 和 PowerShell Profile。

## 4. 测试夹具

### 4.1 假 JDK

创建最小结构：

```text
fake-jdk\
├─ release
└─ bin\
   ├─ java.exe
   ├─ javac.exe
   └─ env-probe.cmd
```

完整 `release` 测试不需要运行 `java.exe`，只需存在有效文件。集成测试可以把系统中的无副作用测试可执行文件复制到临时路径作为占位；不能向仓库提交受版权约束的 JDK 二进制。

`env-probe.cmd` 用于输出 `JAVA_HOME`、`JDK_HOME` 和首个 PATH 项，验证 `jenv exec`。涉及 Java 探测回退时 mock `Invoke-JenvJavaProbe`；单独的进程适配器测试使用可控测试进程。

### 4.2 注册表构建器

测试提供 `New-TestJenvRegistry` 和 `New-TestJdk`，通过生产 JSON 写入函数创建配置。损坏 JSON 测试才直接写原始文本。

### 4.3 Profile 路径注入

Profile 文件操作的私有实现接受显式 `-Path`，Public 命令才从 `$PROFILE.CurrentUserAllHosts` 获取路径。测试调用私有边界或 mock 路径获取函数，避免修改真实 Profile。

## 5. 单元测试矩阵

### 5.1 路径规范化

- 普通绝对路径。
- 含空格、中文、`#`、`&`、括号和单引号。
- 大小写不同但指向同一路径。
- 尾部反斜杠。
- 盘符根目录。
- 相对路径拒绝或按命令规范转为基于当前目录的绝对路径；JENV_ROOT 明确拒绝相对路径。
- 包含 `;`、CR、LF 的 JDK home 被拒绝。
- 非 FileSystem Provider 被拒绝。

### 5.2 release 解析

- Java 8 `1.8.0_442`。
- Java 11、17、21 版本。
- 带 `+build` 和厂商后缀。
- x86、x64、ARM64。
- Corretto、Temurin、Oracle、Zulu、Microsoft、Liberica、GraalVM。
- 无引号值、带引号值和基本转义。
- 重复字段、非法行、缺失必要字段。
- 文件内容包含看似 PowerShell 的表达式时只作为文本处理。

### 5.3 ID 和别名

- Java 8 生成 major `8` 和 `1.8`。
- Java 17 生成 `17` 和完整版本。
- canonical ID 稳定。
- 自动别名冲突时跳过并警告。
- 显式别名冲突时失败。
- `--force` 只重绑定显式别名。
- `system`、空白、超长和非法字符别名被拒绝。
- 仅大小写不同的别名视为冲突。

### 5.4 版本文件

- LF、CRLF、有 BOM 和无 BOM。
- 末尾单个换行。
- 前后空白按规范 Trim。
- 空文件、多行、注释、引号和非法字符失败。
- local 从当前目录向父目录查找。
- 最近文件优先。
- 到卷根停止。
- 当前目录 `.java-version` 删除后采用父目录版本。

### 5.5 优先级

完整组合验证：

| Shell | Local | Global | 预期来源 |
| --- | --- | --- | --- |
| 有 | 有 | 有 | Shell |
| 无 | 有 | 有 | Local |
| 无 | 无 | 有 | Global |
| 无 | 无 | 无 | System |
| `system` | 有 | 有 | System |

另需验证高优先级值非法或未注册时失败，不回退到下一层。

### 5.6 PATH 算法

- 第一次添加到 PATH 首位。
- 8 → 17 → 8 连续切换无残留。
- 目标 bin 原本已在 PATH 中间时移动到首位且只保留一份。
- managed bin 的大小写或尾部分隔符变化仍能删除。
- 其他重复 PATH 项保持不变。
- 空 PATH 项保持不变。
- 初始化后其他工具增加的路径在切换和 system 后保留。
- managed JDK 目录被删除后仍能清除旧 PATH 项。
- 同步中途失败时三个环境变量恢复调用前快照。

### 5.7 所有权恢复

- 初始 JAVA_HOME/JDK_HOME 存在时 system 恢复原值。
- 初始不存在时 system 删除变量。
- 用户在 jenv 设置后手工修改 JAVA_HOME，system 不覆盖该修改。
- JDK_HOME 独立遵循所有权规则。
- `Remove-Module` 与 `jenv init --uninstall` 使用相同恢复规则。

### 5.8 Registry

- 文件不存在视为空。
- schema 1 完整读取。
- 未知可选字段写回时保留。
- 未知 schema 拒绝。
- dangling alias、重复大小写键和非法 home 拒绝。
- 写入 revision 加一。
- 原子替换保留备份。
- 写入失败不损坏原文件。
- mutex 超时返回稳定错误 ID。
- 两个进程并发 add 不丢失更新。

## 6. 集成测试

每个集成测试启动隔离的：

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Command <script>
```

通过显式环境变量传入临时 JENV_ROOT，不拼接不受信任的脚本文本；测试脚本写到临时 `.ps1` 后用 `-File` 和位置参数调用更安全。

### 6.1 模块生命周期

1. 导入模块不修改环境和文件系统。
2. 初始化设置正确环境。
3. 重复初始化不重复 prompt hook 和 PATH。
4. `Remove-Module` 恢复环境。
5. `Import-Module -Force` 不把 managed 环境误当成原始环境。

### 6.2 命令流

```powershell
jenv add <jdk8> --alias corretto8
jenv add <jdk17> --alias temurin17
jenv global temurin17
jenv local corretto8
jenv shell temurin17
jenv shell --unset
jenv local --unset
jenv global --unset
```

每一步验证 `current`、origin、JAVA_HOME、PATH 首项和注册表内容。

### 6.3 `exec`

- 显式版本覆盖当前解析但不写入 JENV_VERSION。
- 参数包含空格、引号、`$()`、分号和 Unicode 时保持为单个参数，不被执行。
- 目标命令成功、非零退出、抛错和中断后都恢复环境。
- 嵌套 exec 按栈恢复。
- `$LASTEXITCODE` 保留目标外部程序结果。
- `--` 缺失时拒绝执行。

### 6.4 prompt hook

prompt 逻辑通过直接调用安装后的 prompt ScriptBlock 测试：

- `Set-Location` 后调用 prompt，local 版本切换。
- 原 prompt 返回值不变。
- 初始化时已有自定义 prompt 能被调用。
- hook 不产生额外成功输出。
- 主题覆盖 prompt 后 `doctor` 给 WARN，卸载不覆盖主题的新 prompt。
- 原 prompt 抛错时错误可见且不发生递归。

### 6.5 Profile

- 空文件安装。
- 不存在文件和父目录安装。
- CRLF、LF、UTF-8 BOM 和无 BOM 文件。
- 已安装时幂等。
- 单侧标记、重复块失败且原文件不变。
- 已签名 Profile 默认拒绝修改。
- 卸载只删除托管块。
- 备份包含替换前的精确内容。

## 7. 安全测试

至少覆盖以下恶意或异常输入：

```text
别名:      x; Remove-Item ...
路径:      D:\SDKs\$(Get-Content secret)
参数:      '; Write-Output injected; '
release:   JAVA_VERSION=$(Invoke-WebRequest ...)
JSON:      超深嵌套、超大字符串、重复大小写键
```

断言：

- 内容不被执行。
- 不发生网络访问。
- 不访问输入范围外的文件。
- 错误 TargetObject 和日志不会展开全部环境或敏感文件内容。
- Profile 和配置文件在失败时逐字节不变。

为防止资源消耗，注册表文件设置合理最大尺寸，例如 10 MiB；版本文件设置 4 KiB 上限。超过上限以明确错误失败。

## 8. 性能测试

使用包含 25 个 JDK 和 100 个别名的注册表，在本地 NTFS 上记录：

| 操作 | 目标 |
| --- | --- |
| 缓存未变化的 prompt hook | 中位数小于 10 ms |
| 冷版本解析 | 中位数小于 50 ms |
| `jenv current` | 中位数小于 100 ms |
| `jenv versions` | 中位数小于 200 ms |

JDK 探测涉及启动 Java 进程，不纳入上述延迟。性能测试默认不作为不稳定硬门槛，但超过目标两倍需要在发布说明中解释。

## 9. 静态检查

PSScriptAnalyzer 至少启用：

- `PSAvoidUsingInvokeExpression`
- `PSAvoidUsingCmdletAliases`
- `PSUseApprovedVerbs`
- `PSAvoidUsingPositionalParameters`
- `PSUseShouldProcessForStateChangingFunctions`
- `PSReviewUnusedParameter`
- `PSUseDeclaredVarsMoreThanAssignments`

另外验证：

- `Test-ModuleManifest` 成功。
- Manifest 只导出文档列出的函数。
- 所有 Public 函数有 synopsis、description、参数和示例帮助。
- 仓库没有绝对开发机路径和 JDK 二进制。
- Markdown 内部链接有效。
- JSON 示例可解析。

## 10. CI 矩阵

每次 pull request：

```text
Windows runner
├─ PowerShell 7.4（最低支持版本）
└─ 当前受支持的最新 PowerShell 7
```

两个版本都运行：

1. PSScriptAnalyzer。
2. Unit tests。
3. Integration tests。
4. `Test-ModuleManifest`。
5. 构建包导入测试。
6. 文档链接和示例 JSON 检查。

Acceptance 测试至少在 PowerShell 7.4 运行。需要真实 Profile 或交互宿主的手工测试列入发布清单，不在 CI 中修改 runner 的真实用户 Profile。

## 11. 发布验收清单

- [ ] `jenv add` 正确识别 Corretto 8、Temurin 17 和至少一个 Java 21 JDK。
- [ ] shell > local > global > system 全部通过。
- [ ] 连续切换 100 次后 PATH 中最多一个 managed bin。
- [ ] 路径含空格和 Unicode 时 add、current、exec 正常。
- [ ] 新 `pwsh` 加载 Profile 后自动采用正确 local/global 版本。
- [ ] `exec` 结束、失败和中断后环境均恢复。
- [ ] system 恢复初始化前环境且保留后续无关 PATH 修改。
- [ ] 注册表并发写入不丢数据，损坏文件不被覆盖。
- [ ] Profile 安装、幂等执行、卸载和损坏标记保护通过。
- [ ] doctor 能定位缺失 JDK、无效版本和被替换的 prompt hook。
- [ ] PowerShell 7.4 与当前最新 PowerShell 7 的 CI 全绿。
- [ ] 发布包不包含测试临时文件、用户路径或 JDK 二进制。
