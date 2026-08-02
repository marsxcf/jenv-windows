# Command Reference

## 1. General Syntax

```text
jenv <command> [arguments] [options]
jenv help [command]
jenv --version
```

Command names and long options are case-insensitive. Version expressions and aliases are compared with `OrdinalIgnoreCase`, while displayed canonical IDs retain their stored case. Unknown options, missing values, and mutually exclusive options produce terminating errors. State-changing commands support `-WhatIf` and `-Confirm` through their underlying advanced functions.

## 2. Command Summary

| Command | Purpose | Changes configuration | Changes session |
| --- | --- | --- | --- |
| `add` | Register an existing JDK | Yes | Sometimes |
| `remove` | Remove a registration, never JDK files | Yes | Sometimes |
| `versions` | List registered JDKs | No | No |
| `current` | Show the effective JDK and origin | No | No |
| `global` | Read, set, or unset the user default | Optional | Yes |
| `local` | Read, set, or unset `.java-version` | Optional | Yes |
| `shell` | Read, set, or unset the session override | No | Yes |
| `home` | Print a resolved JDK home | No | No |
| `which` | Locate a command for a selected JDK | No | No |
| `exec` | Run a command in a temporary JDK environment | No | Temporarily |
| `refresh` | Re-resolve and synchronize the session | No | Yes |
| `doctor` | Diagnose configuration and session state | No | No |
| `init` | Initialize the session or manage the profile | Optional | Yes |
| `root` | Print the effective JENV root | No | No |
| `help` | Show offline help | No | No |

## 3. `jenv add`

### Syntax

```text
jenv add <jdk-home> [--alias <name>]... [--force]
```

### Behavior

1. Resolve `<jdk-home>` to a normalized absolute path.
2. Validate `bin\java.exe` and `bin\javac.exe`.
3. Probe the version, vendor, and architecture.
4. Generate a canonical ID and automatic aliases.
5. Add zero or more explicit `--alias` values.
6. Update the registry atomically.

Candidate automatic aliases include the canonical ID, normalized full version, a compatible short version such as `1.8`, and the major version such as `8` or `21`. If an automatic alias belongs to another JDK, skip it with a warning. An explicit alias conflict fails; `--force` may rebind only explicitly supplied aliases or update the same canonical ID. It never rebinds an automatic alias that was not explicitly requested.

Registering the same path with unchanged metadata succeeds with `Unchanged`; changed probe metadata updates the record.

### Examples

```powershell
jenv add 'D:\SDKs\amazon-corretto-8'
jenv add 'D:\SDKs\jdk-21' --alias work21 --alias latest
jenv add 'D:\SDKs\jdk-21.0.5' --alias latest --force
```

### Result

Interactive output includes at least the canonical ID, home, and new aliases. `Register-JenvJdk` returns:

```text
Action       Added | Updated | Unchanged
CanonicalId string
Home        string
Aliases     string[]
Warnings    string[]
```

## 4. `jenv remove`

### Syntax

```text
jenv remove <version> [--force]
```

`<version>` may be a canonical ID or alias. The command removes the canonical record and all aliases pointing to it, but never deletes the JDK directory.

Removal fails by default if the target is selected by the current shell, local, or global configuration. `--force` permits removal but does not modify `.java-version` or the global file; the command immediately resolves again and reports dangling references.

```powershell
jenv remove corretto8
jenv remove corretto8 --force
```

## 5. `jenv versions`

### Syntax

```text
jenv versions [--bare] [--json]
```

Default output contains one canonical JDK per line and marks the current selection with `*`:

```text
  corretto64-1.8.0.442  (aliases: 8, 1.8, corretto8)
* temurin64-17.0.12     (set by D:\Work\app\.java-version)
```

- `--bare` prints canonical IDs only, suitable for completion and scripts.
- `--json` emits UTF-8 JSON and cannot be combined with `--bare`.

Sort by Java major version, full version, then canonical ID in ascending order. Do not rely on JSON object-property order.

## 6. `jenv current`

### Syntax

```text
jenv current [--json]
```

Default output:

```text
temurin64-17.0.12 (set by D:\Work\app\.java-version)
```

JSON output:

```json
{
  "requestedVersion": "17",
  "canonicalId": "temurin64-17.0.12",
  "home": "D:\\SDKs\\temurin-17",
  "originKind": "Local",
  "originPath": "D:\\Work\\app\\.java-version"
}
```

For system, `canonicalId`, `home`, and `originPath` are `null`.

## 7. `jenv global`

### Syntax

```text
jenv global
jenv global <version>
jenv global --unset
```

- With no argument, print the raw version expression in the global file, or `system` if the file does not exist.
- `<version>` must resolve before it is written to `$JENV_ROOT\version`.
- `--unset` deletes the global file and succeeds idempotently if it is absent.

After a write or deletion, perform full resolution and synchronize the session because shell or local configuration may still take precedence.

## 8. `jenv local`

### Syntax

```text
jenv local
jenv local <version>
jenv local --unset
```

- With no argument, show the nearest effective local version and its file path. If none exists, explicitly report that local is not configured; do not display the global value.
- `<version>` is validated and written to `.java-version` in the current directory.
- `--unset` removes only `.java-version` in the current directory, never a parent file.

`local` requires a filesystem directory. Other PowerShell providers fail with `JEnv.Location.NotFileSystem`. The file contains the expression followed by one LF, for example `17\n`.

## 9. `jenv shell`

### Syntax

```text
jenv shell
jenv shell <version>
jenv shell --unset
```

- With no argument, show `$env:JENV_VERSION`, or report that no shell override is configured.
- `<version>` is validated and assigned to `$env:JENV_VERSION`.
- `--unset` removes the variable and succeeds idempotently if it is absent.

Synchronize the PowerShell environment immediately. Child `pwsh` processes inherit `JENV_VERSION` through normal process-environment inheritance.

## 10. `jenv home`

### Syntax

```text
jenv home [<version>]
```

Resolve the explicit version when supplied; otherwise use full precedence. Print only the normalized JDK home so command substitution is safe:

```powershell
$jdkHome = jenv home 17
```

The system state has no managed home and fails with `JEnv.Version.SystemHasNoHome`; the tool must not guess the system Java home.

## 11. `jenv which`

### Syntax

```text
jenv which <command> [--version <version>]
```

For a managed version, search only its `bin` directory in this order: the original name, `.exe`, `.cmd`, then `.bat`. Print the full path when found. Reject command names containing a directory separator or drive prefix. For system, use `Get-Command -CommandType Application`.

## 12. `jenv exec`

### Syntax

```text
jenv exec [--version <version>] -- <command> [arguments...]
```

The `--` delimiter is mandatory so target arguments are not parsed by jenv.

```powershell
jenv exec -- java -version
jenv exec --version 8 -- javac -encoding UTF-8 Main.java
jenv exec --version 21 -- .\mvnw.cmd test '-Dmessage=a b'
```

The command:

1. Resolves the explicit or current effective version.
2. Saves the caller's environment in a child scope.
3. Applies `JAVA_HOME`, `JDK_HOME`, and `PATH` for the target.
4. Invokes the command with PowerShell's call operator and an argument array, never string evaluation.
5. Passes through success and error output.
6. Restores the caller's environment in `finally`.

PowerShell functions, scripts, and external applications are allowed. Unlike `which`, `exec` permits explicit relative script paths. A missing target produces `JEnv.Command.NotFound`. `exec` never calls `exit`, and it preserves an external program's `$LASTEXITCODE`.

## 13. `jenv refresh`

### Syntax

```text
jenv refresh [--quiet]
```

Ignore the resolution cache, reread the current directory, version files, and registry, and synchronize the environment. The operation is idempotent. `--quiet` suppresses normal status output but not errors; the prompt hook uses equivalent quiet internal behavior.

## 14. `jenv doctor`

### Syntax

```text
jenv doctor [--json]
```

At minimum, check:

| Check | Passing condition |
| --- | --- |
| Platform | Windows, PowerShell Core, and a supported version. |
| Root | `JENV_ROOT` resolves and is readable/writable. |
| Registry | `versions.json` is valid and all references resolve. |
| RegisteredJdks | Every home contains `java.exe` and `javac.exe`. |
| Resolution | The current version expression resolves. |
| JavaHome | `JAVA_HOME` matches the resolution. |
| JdkHome | `JDK_HOME` matches the resolution. |
| Path | The managed bin is the first effective Java bin and is not duplicated. |
| JavaCommand | `Get-Command java` points to the selected JDK. |
| PromptHook | The hook remains installed after initialization. |

Default output marks each check `[OK]`, `[WARN]`, or `[ERROR]`. Any ERROR causes a terminating error; WARN does not. `doctor` is read-only and does not repair automatically.

## 15. `jenv init`

### Syntax

```text
jenv init
jenv init --install
jenv init --uninstall
```

- With no argument, initialize the current session, equivalent to `Initialize-Jenv`.
- `--install` adds a managed block to `$PROFILE.CurrentUserAllHosts` and initializes the session.
- `--uninstall` removes only that block and the current prompt hook; it does not uninstall module files or delete the JDK registry.

Managed block:

```powershell
# >>> jenv-windows initialize >>>
Import-Module JEnv
Initialize-Jenv
# <<< jenv-windows initialize <<<
```

Create missing parent directories and a UTF-8 profile. Installation is idempotent when one complete block already exists. Fail without changing the file if markers are incomplete or duplicated. Preserve all content outside the block. Before replacement, create a backup and temporary file in the same directory; retain and report the most recent backup after success.

## 16. `jenv root`, Help, and Version

```text
jenv root
jenv help
jenv help <command>
jenv --version
```

- `root` prints normalized effective `JENV_ROOT`.
- `help` uses bundled offline help.
- `--version` prints the module semantic version, such as `jenv-windows 0.1.0`.

Unknown commands fail with `JEnv.Command.Unknown` and suggest `jenv help`.

## 17. General Output Requirements

- Human-readable output may use color, but redirected or non-interactive output must not contain ANSI control sequences.
- Write errors to the PowerShell Error stream, warnings to Warning, and detailed diagnostics to Verbose.
- Display paths without unnecessary quotes; escape JSON according to the JSON standard.
- `--json` emits exactly one JSON document without surrounding messages.
- Normal query commands must not modify the environment or configuration.
