# jenv-windows Technical Documentation

This documentation set defines the product boundaries, technical architecture, command behavior, persistence formats, implementation constraints, and acceptance criteria for `jenv-windows`. It is the baseline for developing and reviewing version 0.1.

## Documentation

- [Overall Architecture](./architecture.md): Goals, boundaries, components, key flows, and technical decisions.
- [Command Reference](./command-reference.md): Complete command, argument, output, and error behavior.
- [Configuration, Storage, and Version Resolution](./storage-and-resolution.md): Directory layout, JSON schema, precedence, and atomic writes.
- [PowerShell Session Integration](./powershell-integration.md): Environment variables, `PATH`, profiles, and automatic switching.
- [Development Guide and Implementation Plan](./development.md): Code layout, module API, security constraints, and development phases.
- [Testing and Acceptance](./testing.md): Test matrix, critical cases, CI, and release gates.

## Product Scope

`jenv-windows` is a JDK version selector for Windows PowerShell 7. It manages JDKs that are already installed on the local machine; it does not download, install, or upgrade them.

It provides three configuration layers:

```text
shell (current pwsh session)
        > local (.java-version in the current or a parent directory)
        > global (current user's default version)
        > system (environment before jenv initialization)
```

After selecting a JDK, the tool sets the following values in the current PowerShell process:

```powershell
$env:JAVA_HOME = $SelectedJdkHome
$env:JDK_HOME = $SelectedJdkHome
$env:Path = "$SelectedJdkHome\bin;$env:Path"
```

The implementation must safely remove the `bin` path previously inserted by jenv so that `PATH` does not grow after repeated switches.

## Supported Environments

Version 0.1 supports:

- PowerShell 7.4 or later on Windows 10/11 and Windows Server.
- PowerShell Core (`PSEdition = Core`).
- x64 and ARM64 PowerShell. A registered JDK's architecture is recorded and displayed but is not restricted to the host architecture.
- Process-level environment variables in the current PowerShell session.
- Project-level `.java-version` files.
- Per-user global configuration, stored in `%USERPROFILE%\.jenv` by default.
- Paths containing spaces, Unicode characters, and mixed case.

Version 0.1 does not support:

- Windows PowerShell 5.1.
- `cmd.exe`, Git Bash, WSL, Cygwin, or other shells.
- Modifying `JAVA_HOME` or `PATH` at User or Machine scope.
- Downloading, installing, or automatically upgrading JDKs.
- macOS or Linux.
- Java command shims or proxy executables.
- The upstream jenv plugin system.

Windows Terminal is a terminal host, not a shell. It is supported when its profile runs PowerShell 7.

## Quick Start

```powershell
# Import the module and initialize the current session
Import-Module JEnv
jenv init

# Register JDKs that are already installed
jenv add 'D:\SDKs\amazon-corretto-8' --alias corretto8
jenv add 'D:\SDKs\temurin-17' --alias temurin17

# Set the default version
jenv global temurin17

# Pin Java 8 in a project directory
Set-Location D:\Work\legacy-app
jenv local corretto8

# Temporarily override the version in the current pwsh session only
jenv shell temurin17
jenv shell --unset

# Inspect the selection
jenv current
$env:JAVA_HOME
java -version
```

## Terminology

| Term | Definition |
| --- | --- |
| JDK home | A directory containing both `bin\java.exe` and `bin\javac.exe`. |
| Registration | Recording an existing JDK's absolute path, version, vendor, architecture, and aliases. |
| Version expression | An ID or alias that resolves to a registered JDK, such as `17` or `temurin17`. |
| Canonical ID | The stable, unique identifier of a registration, such as `corretto64-1.8.0.442`. |
| Origin | The source of the current selection: shell, a `.java-version` file, the global file, or system. |
| Managed bin | The JDK `bin` directory currently placed at the beginning of `PATH` by jenv. |
| System | No registered JDK is selected, and jenv restores the Java environment that existed before initialization whenever possible. |

## Specification Precedence

If documents conflict, use this order of precedence:

1. The [Command Reference](./command-reference.md) defines user-observable behavior.
2. [Configuration, Storage, and Version Resolution](./storage-and-resolution.md) defines persistence and resolution behavior.
3. [PowerShell Session Integration](./powershell-integration.md) defines session mutation behavior.
4. [Overall Architecture](./architecture.md) and the remaining documents provide design context.

Any implementation change that affects public behavior or a persistence format must update the corresponding documentation in the same change.
