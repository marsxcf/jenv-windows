# Development Guide and Implementation Plan

## 1. Runtime and Toolchain

Runtime requirements are Windows, PowerShell 7.4 or later, and `PSEdition = Core`. Runtime behavior must not depend on third-party PowerShell modules or the network. Development uses Pester 5, PSScriptAnalyzer, and Git.

## 2. Recommended Repository Layout

```text
jenv-windows\
├─ docs\
├─ src\JEnv\
│  ├─ JEnv.psd1
│  ├─ JEnv.psm1
│  ├─ Public\
│  │  ├─ Initialize-Jenv.ps1
│  │  ├─ Invoke-JenvFacade.ps1
│  │  ├─ Invoke-JenvCommand.ps1
│  │  ├─ Register-JenvJdk.ps1
│  │  ├─ Sync-JenvEnvironment.ps1
│  │  ├─ Test-JenvInstallation.ps1
│  │  └─ VersionCommands.ps1
│  └─ Private\
│     ├─ Environment.ps1
│     ├─ Errors.ps1
│     ├─ JdkProbe.ps1
│     ├─ Json.ps1
│     ├─ Paths.ps1
│     ├─ Profile.ps1
│     ├─ Registry.ps1
│     ├─ Session.ps1
│     └─ VersionResolver.ps1
├─ tests\{Fixtures,Unit,Integration,Acceptance}\
├─ build.ps1
├─ install.ps1
├─ CHANGELOG.md
├─ LICENSE
└─ README.md
```

`JEnv.psm1` dot-sources Private files in a deterministic order, then Public files, and finally calls `Export-ModuleMember` explicitly. Never depend on implicit `Get-ChildItem` ordering.

## 3. Module Boundaries

### 3.1 Public

Compatibility-governed PowerShell API:

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

`JEnv.psd1` is the sole authoritative export list. Every new export requires documentation, tests, and a changelog entry.

### 3.2 Private

Private functions may change in minor releases. They handle normalization, validated/locked/atomic registry I/O, JDK probing, version resolution, environment snapshots, prompt/profile management, and `ErrorRecord` construction.

### 3.3 Data Objects

Prefer `PSCustomObject` with `PSTypeNames`:

```powershell
$result.PSObject.TypeNames.Insert(0, 'JEnv.ResolvedVersion')
```

Avoid PowerShell classes as cross-file public models in 0.1 because class reloading complicates `Import-Module -Force`. Key types are `JEnv.Jdk`, `JEnv.ResolvedVersion`, `JEnv.RegistrationResult`, `JEnv.DiagnosticResult`, and `JEnv.EnvironmentSnapshot`.

Object properties use PascalCase. Persistent and `--json` fields use camelCase and explicit mappings; never serialize all internal properties directly.

## 4. Coding Standards

Each script uses `Set-StrictMode -Version Latest`. Functions use `[CmdletBinding()]`, explicit parameter types, and `SupportsShouldProcess` for mutations. Do not change caller preference variables, use aliases, call `Invoke-Expression`, construct external commands by string concatenation, call `exit`, or depend on current culture for identifiers and comparisons.

Use local `-ErrorAction Stop`, `-LiteralPath` or exact .NET path APIs, and no wildcards for deletion. Dispose resources in `finally`, and place finite timeouts on mutexes, processes, and file handles.

## 5. Error Implementation

Use a centralized factory:

```powershell
New-JenvErrorRecord `
    -Id 'JEnv.Version.NotInstalled' `
    -Message "Java version '$Version' is not registered (set by $Origin)." `
    -Category ObjectNotFound `
    -TargetObject $Version
```

Error IDs are automation contracts; message wording is not. Tests assert `FullyQualifiedErrorId` and important target data, not the complete sentence. User messages are English. Localization must never change IDs, object properties, or JSON fields.

An error should state what failed, which path/version/file caused it, where the configuration came from, and an actionable next command.

## 6. Registry Implementation Layers

```text
Read-JenvRegistry(path)              parse and validate schema
Test-JenvRegistry(registry)          validate logical references
Invoke-WithJenvRegistryLock(root)    serialize concurrent writers
Write-JenvRegistryAtomic(registry)   encode, back up, atomically replace
Update-JenvRegistry(mutation)        reread under lock, mutate, increment revision
```

Business code must not overwrite a file directly after `ConvertFrom-Json`. All writes go through `Update-JenvRegistry`. Specify JSON depth explicitly and construct objects in stable order to reduce meaningless diffs.

## 7. JDK Probe Implementation

Separate pure parsing from I/O:

```text
Read-JenvReleaseFile
Invoke-JenvJavaProbe
ConvertTo-JenvJdkMetadata
Get-JenvCanonicalId
Get-JenvCandidateAliases
```

This lets unit tests supply text without a real JDK. If the release file and Java process disagree, prefer the runtime process for `version`; prefer recognized release values for `vendor` and `architecture`; log differences to Verbose.

## 8. Version Resolver Implementation

```powershell
Resolve-JenvVersion `
    -Registry $registry `
    -Root $root `
    -CurrentDirectory $directory `
    -ShellVersion $env:JENV_VERSION
```

The resolver is deterministic and read-only. It never creates files, changes the environment, repairs aliases, or chooses a “closest” version. Every result includes its origin, and callers reuse one result so display, `JAVA_HOME`, and `exec` cannot disagree.

## 9. Session Implementation

Keep one session-state object in module script scope. All changes pass through:

```text
Get-JenvSessionState
Initialize-JenvSessionState
Set-JenvProcessEnvironment
Restore-JenvProcessEnvironment
Enable-JenvPromptHook
Disable-JenvPromptHook
```

Commands must not concatenate `$env:Path` themselves. Follow [PowerShell Session Integration](./powershell-integration.md).

## 10. Facade Argument Dispatch

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

Each subcommand has its own parser mapping GNU-style options to advanced-function parameters. Parsers support `--`, reject unknown/missing options, never split strings already parsed by PowerShell, and preserve the order, types, and boundaries of `exec` arguments.

## 11. Help and Comments

Every Public function has comment-based help. Generate `jenv help <command>` from the same command metadata to avoid duplicate syntax definitions. Keep the root README focused on installation and quick use, link details to `docs`, and make examples directly runnable in PowerShell 7.

## 12. Build and Installation

`build.ps1` cleans only a dedicated output directory, runs PSScriptAnalyzer and Pester, copies the module to `artifacts\JEnv\<version>`, runs `Test-ModuleManifest`, and creates a release archive plus checksum.

`install.ps1` installs to the current user's PowerShell 7 module path, supports `-WhatIf`, requires `-Force` to replace the same version, does not edit the profile automatically, and never changes User/Machine `PATH`. After Gallery publication, recommend `Install-PSResource`; retain the local installer for repository development.

## 13. Versioning and Compatibility

Use Semantic Versioning: patch releases fix bugs without changing command/schema contracts; minor releases add backward-compatible commands, options, or schema-1 optional fields; major releases may break commands, Public API, or persistence formats.

`schemaVersion` is independent from the module version. Back up before an explicit schema migration and leave the original untouched if migration fails.

## 14. Implementation Phases

### Phase A: Core Data and Resolution

Build the module skeleton, error factory, root/path handling, registry schema and atomic concurrency, metadata probing, registration commands, and all resolution layers. Completion: stable registration/resolution without session mutation.

### Phase B: PowerShell Session

Implement snapshots, ownership restoration, `PATH` switching, selection/query commands, and isolated `exec`. Completion: all environment scenarios pass with no `PATH` leakage.

### Phase C: Interactive Experience

Implement initialization, the prompt hook, profile install/uninstall, diagnostics, help, facade output, and JSON output. Completion: a new PowerShell 7 session automatically applies global/local configuration.

### Phase D: Release Quality

Resolve required analyzer findings; complete the Pester matrix, build/install/uninstall/package flows, README, changelog, and license.

## 15. Definition of Done

A feature is complete only when observable behavior matches the docs; normal, boundary, and failure tests exist; session restoration and `PATH` idempotency remain intact; new errors have stable IDs; persistence fields document schema compatibility; Public APIs have help; analysis, tests, and manifest validation pass; and technical docs plus changelog are updated.
