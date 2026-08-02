# Overall Architecture

## 1. Goals

`jenv-windows` must perform the following tasks in PowerShell 7:

1. Register locally installed JDKs without copying their files.
2. Select a JDK through global, local, and shell configuration layers.
3. Synchronize `JAVA_HOME`, `JDK_HOME`, and `PATH` in the current PowerShell process.
4. Switch automatically after entering a project containing `.java-version`.
5. Provide scripts with a deterministic execution entry point that does not depend on an interactive prompt.
6. Provide behavior that is diagnosable, testable, and safely reversible.

## 2. Non-goals

- Acting as a JDK package manager.
- Permanently modifying Windows user or system environment variables.
- Replacing PowerShell's command resolver.
- Exactly reproducing the upstream jenv directory layout or plugin implementation.
- Implementing `java.exe` or `javac.exe` shims in version 0.1.
- Providing compatibility layers for other shells.

## 3. Core Constraints

### 3.1 Run in the Current PowerShell Process

A separate child process cannot modify its parent PowerShell environment, so the user entry point must be a PowerShell function. The `JEnv` module exports `jenv`, which modifies `$env:*` directly.

### 3.2 Modify Only the Process Environment

All Java environment changes apply only to the current `pwsh` process and child processes launched afterward. The implementation must not call these APIs with a `User` or `Machine` target:

```powershell
[Environment]::SetEnvironmentVariable($Name, $Value, 'User')
[Environment]::SetEnvironmentVariable($Name, $Value, 'Machine')
```

### 3.3 Separate Persistent Configuration from Session State

- The registry, global version, and `.java-version` are persistent state.
- The shell version is stored in `$env:JENV_VERSION` and exists only in the current process and its children.
- The original environment, managed bin, and prompt hook are module session state and are not written to configuration files.

### 3.4 Never Execute Configuration Contents

`versions.json`, `version`, `.java-version`, and the JDK `release` file are data. They must never be executed through `Invoke-Expression`, dot-sourcing, or dynamically generated PowerShell.

## 4. Logical Architecture

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

### 4.1 User Interface Layer

The module provides two kinds of entry points:

- `jenv <subcommand>`: an interactive interface similar to upstream jenv.
- Advanced PowerShell functions for tests, scripts, and future extension.

`jenv` handles only argument dispatch and presentation. It must not contain version-resolution or file-writing logic.

### 4.2 Command Service Layer

Each subcommand represents one explicit use case. The service layer:

- validates arguments;
- calls the registry or resolver;
- performs persistent changes;
- invokes session synchronization when required; and
- returns structured results or throws errors with stable error IDs.

### 4.3 JDK Registry

The registry stores JDK metadata and alias mappings. It does not represent versions with symbolic links because Windows symbolic links may depend on privileges or Developer Mode.

Registration flow:

```text
Input path
  → normalize to an absolute path
  → validate java.exe / javac.exe
  → read the release file
  → run java -XshowSettings:properties -version if needed
  → generate a canonical ID and candidate aliases
  → check conflicts
  → atomically write versions.json
```

### 4.4 Version Resolver

The resolver has no side effects. Its inputs are the current directory, `JENV_VERSION`, the JENV root, and a registry snapshot. It returns:

```text
RequestedVersion  Original value supplied by the user or configuration file
CanonicalId       Resolved unique ID; empty for system
Home              Absolute JDK path; empty for system
OriginKind        Shell | Local | Global | System
OriginPath        Path to .java-version or the global file; otherwise empty
```

See [Configuration, Storage, and Version Resolution](./storage-and-resolution.md) for the complete rules.

### 4.5 Session Integration

Without overwriting changes made by other tools at runtime, session integration:

- removes the previous managed bin;
- puts the selected JDK's `bin` first in `PATH`;
- sets `JAVA_HOME` and `JDK_HOME`;
- restores pre-initialization values in the system state; and
- installs, invokes, and removes the prompt hook.

See [PowerShell Session Integration](./powershell-integration.md) for the complete rules.

## 5. Key Flows

### 5.1 Module Initialization

```text
Import-Module JEnv
  → validate the PowerShell version and Windows platform
  → calculate JENV_ROOT
  → load functions without modifying the profile

jenv init
  → capture current JAVA_HOME/JDK_HOME
  → resolve the current version
  → synchronize the current process environment
  → install an idempotent prompt hook
```

Keeping import separate from initialization lets CI, unit tests, and non-interactive scripts import functions without automatically changing their environment.

### 5.2 Registering a JDK

After `jenv add <home>` registers a JDK, it does not automatically change the global, local, or shell selection. If the current resolution already refers to an alias added by this operation, the session may be synchronized once; otherwise, its environment remains unchanged.

JDK metadata is probed in this order:

1. Parse `<home>\release`.
2. If required fields are missing, run `<home>\bin\java.exe -XshowSettings:properties -version`.
3. If the version is still unavailable, fail registration.

External programs are launched with `System.Diagnostics.ProcessStartInfo.ArgumentList`; executable command strings are never concatenated.

### 5.3 Setting a Version

- `global` writes user configuration and synchronizes the session.
- `local` writes `.java-version` in the current directory and synchronizes the session.
- `shell` sets `$env:JENV_VERSION` and synchronizes the session.
- `--unset` removes the relevant layer and performs full resolution again; it must not simply fall back to system.

### 5.4 Automatic Directory Switching

In interactive sessions, a prompt hook resolves the current directory before each prompt. The environment is updated only when the resolution fingerprint changes.

The fingerprint includes at least:

- `$env:JENV_VERSION`;
- the current filesystem directory;
- the effective version file's full path, length, and last-write time; and
- the last-write time of `versions.json`.

Correctness must not depend on the cache. If cache validation or fingerprint calculation fails, resolution must run again.

### 5.5 Deterministic Command Execution

The interactive prompt hook does not run between `Set-Location` and another command in the same PowerShell statement:

```powershell
Set-Location D:\Work\app; java -version
```

Scripts and compound commands should use:

```powershell
jenv exec -- java -version
```

`exec` resolves the current directory in a child scope, applies the environment, invokes the target, and restores the caller's environment afterward. It does not depend on the prompt hook.

## 6. Module State Model

The module maintains a session state object:

```text
Initialized             Whether initialization has completed
OriginalJavaHome        Whether JAVA_HOME existed before initialization and its value
OriginalJdkHome         Whether JDK_HOME existed before initialization and its value
ManagedJavaHome         Most recent JAVA_HOME value written by jenv
ManagedJdkHome          Most recent JDK_HOME value written by jenv
ManagedBin              Most recent PATH entry inserted by jenv
PreviousPrompt          prompt ScriptBlock captured during initialization
PromptHook              prompt ScriptBlock installed by jenv
LastResolutionFingerprint
```

This state exists only in the current module instance. When `Remove-Module JEnv` runs, the module should remove its prompt hook. It may restore the old prompt only if the current prompt is still jenv's hook; it must not overwrite a new prompt installed by another tool after initialization.

## 7. Error Model

Internal functions report failures with terminating errors and never call `exit`. Errors have stable `FullyQualifiedErrorId` values:

| Error ID | Meaning |
| --- | --- |
| `JEnv.Platform.Unsupported` | The host is not Windows or PowerShell Core. |
| `JEnv.PowerShellVersion.Unsupported` | PowerShell is older than the minimum supported version. |
| `JEnv.Jdk.InvalidHome` | The path is not a valid JDK home. |
| `JEnv.Jdk.ProbeFailed` | Version metadata could not be obtained. |
| `JEnv.Version.NotInstalled` | The version or alias does not exist. |
| `JEnv.Version.InUse` | A shell, local, or global configuration still refers to the version. |
| `JEnv.VersionFile.Invalid` | A version file has an invalid format. |
| `JEnv.Alias.Conflict` | An explicit alias belongs to another JDK. |
| `JEnv.Registry.Invalid` | `versions.json` cannot be parsed or violates its schema. |
| `JEnv.Registry.LockTimeout` | The write lock could not be acquired in time. |
| `JEnv.Profile.UpdateFailed` | The PowerShell profile could not be updated safely. |
| `JEnv.Command.NotFound` | `exec` or `which` cannot find the target command. |

User-facing errors must identify the failed object, its source, and an actionable remedy.

## 8. Security and Reliability Decisions

- Treat every configuration file as data; never execute its contents.
- Require absolute filesystem paths for JDKs and reject paths containing `;`, CR, or LF.
- Write configuration through a temporary file in the same directory followed by atomic replacement.
- Acquire a named mutex based on normalized `JENV_ROOT` before modifying `versions.json`.
- Never use `Invoke-Expression` to launch external processes.
- Install profile integration in an explicit managed block without replacing other user content.
- `doctor` may report problems but must not modify configuration without an explicit repair option.
- Logs and errors must not expose credentials or the complete environment.

## 9. Future Evolution

The following features are outside the 0.1 contract but may be added without breaking current storage compatibility:

- `jenv discover` for common JDK installation paths and registry entries.
- PowerShell argument completion.
- Publishing to PowerShell Gallery, Scoop, and WinGet.
- A self-contained .NET shim that resolves `.java-version` when `java.exe` runs.
- A separate CMD adapter.

Any shim must reuse the same `versions.json` and version-resolution rules; it must not introduce a second selection algorithm.
