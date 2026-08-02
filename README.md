# jenv-windows

A JDK version selector for Windows PowerShell 7. It manages JDKs that are
**already installed** on your machine (it does not download or install Java)
and switches the active JDK in the current `pwsh` session by setting
`JAVA_HOME`, `JDK_HOME`, and `PATH`.

```text
shell (current pwsh session)
    > local  (nearest .java-version in this or a parent directory)
    > global (user default)
    > system (whatever was inherited before jenv initialized)
```

This is a Windows / PowerShell-native reimagining of [jenv](https://github.com/jenv/jenv).
It targets **PowerShell 7.4+** on Windows and does **not** use Java command shims.

## Status

0.1 — under development. See [`docs/`](./docs) for the authoritative
specification, and [CHANGELOG.md](./CHANGELOG.md) for progress.

## Quick start

```powershell
# Register JDKs you already have installed
jenv add 'D:\SDKs\amazon-corretto-8'
jenv add 'D:\SDKs\temurin-17' --alias temurin17

# Choose a default, pin a project, or override just this session
jenv global temurin17
Set-Location D:\Work\legacy-app
jenv local corretto8      # writes D:\Work\legacy-app\.java-version
jenv shell temurin17      # this session only
jenv shell --unset

# Inspect
jenv current
$env:JAVA_HOME
java -version
```

When you `cd` into a directory that contains a `.java-version` file, the active
JDK switches automatically on the next prompt.

## Install

> The packaging pipeline is part of 0.1. Once the first release is published:

```powershell
winget install jenv-windows.jenv-windows
# Restart your terminal, then:
jenv doctor
```

For local development, see [docs/development.md](./docs/development.md) and run
`./build.ps1`.

## Documentation

The full product and technical specification lives in [`docs/`](./docs):

- [Architecture](./docs/architecture.md)
- [Command reference](./docs/command-reference.md)
- [Configuration, storage & version resolution](./docs/storage-and-resolution.md)
- [PowerShell session integration](./docs/powershell-integration.md)
- [Development & implementation plan](./docs/development.md)
- [Testing & acceptance](./docs/testing.md)

## License

MIT — see [LICENSE](./LICENSE).
