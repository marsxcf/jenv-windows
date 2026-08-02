# PowerShell Session Integration

## 1. Design Goals

Session integration applies a resolution result to the current PowerShell 7 process while ensuring that:

- switches immediately affect subsequently launched Java, Maven, Gradle, and other child processes;
- repeated switches do not duplicate `PATH` entries;
- unrelated `PATH` changes made after initialization are preserved;
- system restores the pre-initialization Java environment whenever possible;
- automatic switching does not override location cmdlets; and
- initialization, refresh, and uninstall are idempotent.

## 2. Why a PowerShell Module Is Required

A Windows executable or newly launched `pwsh` can inherit its parent's environment but cannot modify the already running parent. Therefore, commands that change selections must synchronize inside the current process, `jenv` must be a PowerShell function, and emitting code for the user to run through `Invoke-Expression` is not an acceptable primary interface.

Minimum manifest requirements:

```powershell
@{
    RootModule           = 'JEnv.psm1'
    ModuleVersion        = '0.1.0'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
}
```

Module loading must also check `$IsWindows` because `PSEdition = Core` does not restrict the operating system.

## 3. Initialization Lifecycle

### 3.1 `Import-Module JEnv`

Import loads public/private functions, registers an `OnRemove` callback, and validates runtime requirements. It must not create `$JENV_ROOT`, read or edit the PowerShell profile, modify Java environment variables, or install a prompt hook.

### 3.2 `Initialize-Jenv` / `jenv init`

On first initialization:

1. Capture whether `JAVA_HOME` and `JDK_HOME` exist and their values.
2. Create module session state.
3. Perform uncached full resolution.
4. Apply the result to the current process.
5. Install the prompt hook in interactive sessions.
6. Mark the module initialized.

Repeated initialization does not recapture a jenv-managed environment as the original or wrap the prompt again; it performs one refresh and succeeds. If resolution or application fails, do not install the hook, keep initialization false, and roll back partial changes.

### 3.3 Module Removal

The module's `OnRemove` callback restores the saved prompt only if the global prompt is still jenv's hook, removes the managed bin, restores `JAVA_HOME` and `JDK_HOME` under the ownership rules, and clears session state. It never modifies the profile; only `jenv init --uninstall` removes the managed block.

## 4. Environment Ownership Model

Process environment variables have no module scope. To avoid overwriting later changes by a user or another tool, jenv records:

```text
OriginalJavaHome.Exists / .Value
OriginalJdkHome.Exists  / .Value
ManagedJavaHome
ManagedJdkHome
ManagedBin
```

Restore `JAVA_HOME` only when its current value still equals `ManagedJavaHome`; then restore the original value or delete the variable if it was originally absent. Otherwise, treat the current value as externally owned. Apply the same rule independently to `JDK_HOME`.

For `PATH`, remove only entries that normalize equal to `ManagedBin`; never restore the complete old `PATH`, which would discard later additions from Node, Python, virtual environments, or users.

## 5. PATH Management Algorithm

### 5.1 Path Normalization

For comparisons, preserve empty values without matching them, normalize nonempty values with `[IO.Path]::GetFullPath()`, remove trailing separators not required for a root, and compare with `StringComparer.OrdinalIgnoreCase`. Do not rely exclusively on `Resolve-Path`, because an old managed bin may no longer exist.

### 5.2 Switching to a Managed JDK

For `$targetBin = Join-Path $jdk.Home 'bin'`:

```text
read current Path
  → split on [IO.Path]::PathSeparator
  → remove every entry matching old ManagedBin
  → remove every entry matching targetBin
  → preserve all other values and their order
  → prepend targetBin
  → join with PathSeparator
```

Then set `JAVA_HOME`, `JDK_HOME`, and `Path`. Update module `Managed*` state only after all assignments succeed. On failure, restore all three variables to their values at call entry.

Empty `PATH` entries may represent the current directory and must remain. Do not globally deduplicate, sort, or existence-filter entries other than the managed bin.

### 5.3 Switching to System

Remove `ManagedBin` from the current path, restore the two home variables using the ownership rules, then clear `Managed*` state. System means the Java environment inherited before initialization; do not infer `JAVA_HOME` from the registry or `Get-Command java`.

### 5.4 Idempotency

If both the target canonical ID and environment are unchanged, do not rewrite `PATH`. Repeating `jenv refresh` or `Initialize-Jenv` must not alter the final result.

## 6. Prompt Hook

### 6.1 Responsibilities

PowerShell calls global `prompt` before displaying each prompt. jenv wraps it:

```text
jenv prompt hook
  → silently check the resolution fingerprint
  → call Sync-JenvEnvironment when it changes
  → invoke the prompt saved at initialization
  → return its output unchanged
```

The hook must not write to the success stream.

### 6.2 Installation Safety

- Save the current `Function:\global:prompt` ScriptBlock, not its function-name string.
- The hook must access internal synchronization without depending on temporary variables in the user's scope.
- Identify the hook by reference identity or a module-generated unique marker.
- Reuse an existing hook during repeated initialization.
- Propagate errors from the original prompt and never recurse into itself.

### 6.3 Theme Tools

Oh My Posh, Starship, and similar tools may replace `prompt`. Recommended profile order:

```powershell
# Initialize the prompt theme first
oh-my-posh init pwsh --config $Theme | Invoke-Expression

# Then let jenv wrap the final prompt
Import-Module JEnv
Initialize-Jenv
```

Here `Invoke-Expression` belongs to the theme's own initialization and is not used by jenv to process configuration or arguments.

If a theme replaces the prompt after jenv, the current environment remains, automatic directory switching stops, `jenv refresh` still works, and `jenv doctor` reports a PromptHook warning with a suggestion to rerun `Initialize-Jenv`.

### 6.4 Why Location Commands Are Not Wrapped

Version 0.1 does not proxy `Set-Location`, `cd`, `Push-Location`, or `Pop-Location`; faithfully reproducing all parameter sets, providers, pipeline behavior, and errors is risky. The prompt hook covers normal interactive use. Scripts use `jenv exec` or an explicit `jenv refresh`.

## 7. Profile Integration

### 7.1 Target Profile

Operate only on `$PROFILE.CurrentUserAllHosts`. Never hardcode `Documents\PowerShell`, because Documents may be redirected and the host supplies the correct path.

### 7.2 Installation Algorithm

`jenv init --install`:

1. Obtain the actual profile path.
2. If it exists, detect encoding, newlines, and Authenticode signature.
3. Make no change when exactly one complete managed block exists.
4. Fail on an unmatched marker or multiple blocks.
5. Refuse to edit a valid signed profile by default; instruct the user to edit and re-sign it manually.
6. Create a missing parent directory.
7. Append a newline and the managed block.
8. Atomically replace through a same-directory temporary file and create a backup.
9. Initialize the current session.

New files use UTF-8 without BOM. Existing files retain their BOM and CRLF/LF style whenever possible.

### 7.3 Uninstallation Algorithm

`jenv init --uninstall` removes exactly the marked block and one adjacent blank line added during installation. It preserves all other bytes and newline style, succeeds idempotently when the block is absent, and fails without fuzzy deletion when markers are malformed. It also removes the current prompt hook and restores the Java environment. It does not call `Remove-Module`, allowing the command to report its result.

## 8. `exec` Environment Isolation

Assignments to `$env:*` remain process-wide even in a child scope, so `jenv exec` explicitly saves and restores state:

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

The snapshot records existence and value for `JAVA_HOME`, `JDK_HOME`, and `Path`. Restoration in `finally` also covers exceptions and interruption. Temporary execution must not update interactive `Managed*` state or the resolution cache. Nested calls restore naturally through stacked snapshots.

## 9. Non-interactive Use

CI and scripts may skip initialization:

```powershell
Import-Module JEnv
jenv exec --version 17 -- .\gradlew.bat test
```

For several commands sharing one environment:

```powershell
Import-Module JEnv
jenv shell 17
java -version
.\mvnw.cmd verify
```

If `jenv shell` runs before `init`, create session state and capture the original environment implicitly, but do not install a prompt hook. Only `Initialize-Jenv` installs it.

## 10. PowerShell API Design

Recommended exports:

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

Advanced functions use `[CmdletBinding()]` and support `-Verbose`; configuration mutations support `-WhatIf` and `-Confirm`. The facade maps double-dash arguments to these functions, while internal functions never reparse raw command strings.

## 11. Session Acceptance Example

```powershell
Import-Module JEnv
jenv init

jenv shell 8
$env:JAVA_HOME                         # D:\SDKs\amazon-corretto-8
(Get-Command java).Source              # D:\SDKs\amazon-corretto-8\bin\java.exe

jenv shell 17
$env:JAVA_HOME                         # D:\SDKs\temurin-17
($env:Path -split ';')[0]              # D:\SDKs\temurin-17\bin

jenv shell --unset                     # Resolve local/global/system again
jenv refresh
```

No previous managed bin may remain in `PATH`, regardless of the number of switches.
