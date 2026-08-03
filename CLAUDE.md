# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`jenv-windows` is a **PowerShell 7.4+ module** (Windows-only, `PSEdition = Core`) that selects between JDKs **already installed** on the machine. It is a Windows-native reimagining of [jenv](https://github.com/jenv/jenv) — it does not download/install Java and does not use command shims. It switches the active JDK in the *current* `pwsh` process by setting `JAVA_HOME`, `JDK_HOME`, and `PATH`.

`docs/` is the authoritative product/technical spec. When documents conflict, precedence is: command-reference → storage-and-resolution → powershell-integration → architecture/development. **Any change that affects observable behavior or a persistence format must update the corresponding doc in the same change.**

## Commands

All commands run under `pwsh` (PowerShell 7). Pester 5+ and PSScriptAnalyzer are dev dependencies (`Install-Module Pester, PSScriptAnalyzer -Scope CurrentUser`).

```powershell
./build.ps1                     # static analysis + Pester tests + package to artifacts/ (CI runs this)
./build.ps1 -SkipTests          # analysis + package only
./build.ps1 -SkipAnalyze        # tests + package only
./build.ps1 -Version 0.1.0      # version must match JEnv.psd1 ModuleVersion exactly

# Run a single test file
Invoke-Pester -Path ./tests/JEnv.Unit.ps1 -Output Detailed
# Run one test by name (Pester 5 -TestName matches Describe/It names)
Invoke-Pester -Path ./tests/JEnv.Unit.ps1 -TestName 'Paths' -Output Detailed

# Install into the current user's module path for local dev (does NOT touch the profile)
./install.ps1
./install.ps1 -Force            # overwrite an existing same-version install
# Then hook into the profile and initialize the session:
jenv init --install
```

`build.ps1` version-pin: it derives the version from `JEnv.psd1` and throws if a `-Version` argument disagrees — bump the manifest first.

CI (`.github/workflows/ci.yml`) runs `./build.ps1` on `windows-latest` against both PowerShell 7.4 and the latest PowerShell 7. Both must pass.

## Architecture

### Why it's a module, not an executable
A child process cannot modify its parent's environment, so the user entry point is a PowerShell **function** (`jenv`) that writes `$env:*` directly. `jenv exec` exists for scripts because the prompt hook never runs between `Set-Location` and the next command in one statement.

### Layered design
```
jenv facade (Invoke-JenvFacade: argument dispatch + GNU-style parsing only)
  → Public command services (Register/Unregister/Get Jdk, Set/Get version, Sync, exec, doctor, init, Initialize)
    → Private core: Registry (versions.json I/O) · VersionResolver (read-only) · Session (env/PATH/prompt) · JdkProbe · Paths · Json · Errors · Profile
```
- The facade and Public functions contain **no** resolution or file-writing logic — that lives in Private.
- **VersionResolver is pure/read-only**: it takes (registry, root, current directory, `$env:JENV_VERSION`) and returns a `JEnv.ResolvedVersion` (requested, canonicalId, home, originKind, originPath). It never creates files, mutates env, or picks "closest" matches. An invalid higher-precedence layer **fails** rather than falling through.

### Version selection precedence
`shell` (`$env:JENV_VERSION`) > `local` (nearest `.java-version` walking parents to volume root) > `global` (`$JENV_ROOT\version`) > `system`. `system` is a reserved expression meaning "use whatever was inherited before init."

### Module loading (`JEnv.psm1`)
Dot-sources Private files then Public files in a **fixed explicit order** (Errors first so runtime guards get stable error IDs), never via `Get-ChildItem`. The manifest `JEnv.psd1` `FunctionsToExport` is the sole authoritative public-API list — every new export needs docs + tests + a changelog entry. `OnRemove` restores managed state (also makes `Import-Module -Force` safe). Import deliberately changes nothing — only `Initialize-Jenv`/`jenv init` captures baseline env and installs the prompt hook.

### Invariants you must not break (security & reliability)
- **Process-only env:** never call `[Environment]::SetEnvironmentVariable(...,'User'|'Machine')`.
- **Config is data, never code:** `versions.json`, `version`, `.java-version`, and the JDK `release` file must never pass through `Invoke-Expression`, dot-sourcing, or dynamic PowerShell. No `Invoke-Expression` to launch external programs either.
- **Registry writes go through `Update-JenvRegistry`** only — it rereads under a named mutex (`Local\JEnv-<sha256 root>`), mutates, increments `revision`, and atomically replaces via a same-directory temp file + backup. Never overwrite a file directly after `ConvertFrom-Json`. Read-only commands must never "repair" corruption.
- **PATH ownership model:** jenv removes only entries equal to its own `ManagedBin`, never restores the full old PATH (would discard later additions from Node/Python/venvs). `JAVA_HOME`/`JDK_HOME` are restored only if the current value still equals what jenv wrote (`ManagedJavaHome`/`ManagedJdkHome`); otherwise the value is treated as externally owned.
- **Errors:** route every failure through `New-JenvErrorRecord` / `ThrowJenvError` with a stable `FullyQualifiedErrorId` (listed at the top of `src/JEnv/Private/Errors.ps1`). IDs are a compatibility contract — tests assert the ID, never the prose message.

### Data shapes
Prefer `PSCustomObject` with `PSTypeNames` (e.g. `JEnv.ResolvedVersion`); avoid PowerShell classes as cross-file public models (reloading complicates `Import-Module -Force`). Object properties are PascalCase; persistence/`--json` fields are camelCase with explicit mappings.

## Conventions

- Every script: `Set-StrictMode -Version Latest`. Public functions: `[CmdletBinding()]`, explicit param types, `SupportsShouldProcess` on mutations, `-LiteralPath`, local `-ErrorAction Stop`. No aliases, no `exit`, no string-concatenated external commands, no culture-dependent comparisons (use `OrdinalIgnoreCase` for paths/IDs/aliases).
- External processes use `ProcessStartInfo.ArgumentList`, never concatenated command strings.
- Tests live in `tests/JEnv.*.ps1` (Unit / Profile / Session). Unit tests for Private functions use `InModuleScope JEnv`. Each test isolates its own temp root/project/jdks/profile dirs and restores `JENV_ROOT`, `JENV_VERSION`, `JAVA_HOME`, `JDK_HOME`, `Path`, and current location in `AfterAll`/`finally`. Tests **never** touch the developer's real `%USERPROFILE%\.jenv` or `$PROFILE`.
- Local development against the module: `Import-Module ./src/JEnv/JEnv.psd1 -Force`.
