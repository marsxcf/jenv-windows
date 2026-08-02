# Testing and Acceptance

## 1. Test Goals

Tests prove that registration and alias resolution are correct and deterministic; shell > local > global > system precedence is exact; `JAVA_HOME`, `JDK_HOME`, and `PATH` switch and restore correctly; prompt/profile/concurrency/corrupt configuration cannot damage the session; paths and arguments are never executed as PowerShell; and the PowerShell 7-only boundary is explicit.

## 2. Test Levels

```text
Unit          Pure functions and individual I/O boundaries
Integration   Module components with temporary filesystems/child pwsh
Acceptance    Complete scenarios from user command entry points
Static        PSScriptAnalyzer, manifest, links, and formatting
```

## 3. Isolation

Each test uses separate temporary `root`, `project`, `jdks`, and `profile` directories. Save and restore `JENV_ROOT`, `JENV_VERSION`, `JAVA_HOME`, `JDK_HOME`, `Path`, current location, and global prompt in `finally`/`AfterEach`.

Environment and prompt tests do not run in parallel. Pure resolution tests may run concurrently only with separate roots. Tests never read or write the developer's real `%USERPROFILE%\.jenv` or PowerShell profile.

## 4. Fixtures

### 4.1 Fake JDK

```text
fake-jdk\
├─ release
└─ bin\
   ├─ java.exe
   ├─ javac.exe
   └─ env-probe.cmd
```

Most release tests require only valid files, not an executable Java runtime. Integration tests may copy a harmless system executable as a placeholder; never commit copyrighted JDK binaries. `env-probe.cmd` reports both homes and the first `PATH` entry for `exec` verification. Mock `Invoke-JenvJavaProbe` except in dedicated process-adapter tests.

### 4.2 Registry Builder

Provide `New-TestJenvRegistry` and `New-TestJdk` and create normal fixtures through production JSON writers. Write raw text directly only for corruption tests.

### 4.3 Profile Path Injection

Private profile I/O accepts explicit `-Path`; only Public commands obtain `$PROFILE.CurrentUserAllHosts`. Tests invoke the private boundary or mock path lookup so the real profile is untouched.

## 5. Unit Test Matrix

### 5.1 Path Normalization

Cover absolute paths, spaces, Unicode, `#`, `&`, parentheses, apostrophes, case differences, trailing separators, drive roots, relative-path policy, non-filesystem providers, and rejection of `;`, CR, or LF in JDK homes.

### 5.2 Release Parsing

Cover Java 8/11/17/21, build/vendor suffixes, x86/x64/ARM64, all supported vendors, quoted/unquoted/basic escaped values, duplicate or malformed lines, missing fields, and PowerShell-looking text treated only as data.

### 5.3 IDs and Aliases

Verify Java 8 aliases `8` and `1.8`, full/major aliases for modern Java, stable canonical IDs, warning/skip behavior for automatic conflicts, failure for explicit conflicts, the limited effect of `--force`, rejection of `system`, whitespace, oversized and illegal aliases, and case-insensitive collisions.

### 5.4 Version Files

Cover LF/CRLF, BOM/no BOM, one final newline, trimming, rejection of empty/multiline/commented/quoted/invalid files, nearest-parent local discovery through the volume root, and switching to a parent after deleting the current directory's file.

### 5.5 Precedence

| Shell | Local | Global | Expected origin |
| --- | --- | --- | --- |
| Set | Set | Set | Shell |
| Unset | Set | Set | Local |
| Unset | Unset | Set | Global |
| Unset | Unset | Unset | System |
| `system` | Set | Set | System |

An invalid/unregistered higher layer must fail without falling through.

### 5.6 PATH Algorithm

Test first insertion; repeated 8 → 17 → 8 switching; moving an existing target bin to the front without duplication; case/trailing-separator matching; preservation of unrelated duplicates and empty entries; preservation of later external additions; removal of a managed path after its directory disappears; and transactional restoration when synchronization fails.

### 5.7 Ownership Restoration

Test restoring original homes, deleting originally absent variables, preserving manual changes after jenv writes, independent `JDK_HOME` ownership, and identical behavior for `Remove-Module` and uninstall.

### 5.8 Registry

Test missing-as-empty, complete schema 1, preservation of unknown optional fields, rejection of unknown schemas/dangling aliases/case duplicates/invalid homes, revision increments, backups and atomic replacement, write-failure preservation, stable mutex timeout IDs, and concurrent adds without lost updates.

## 6. Integration Tests

Launch each test in an isolated process:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Command <script>
```

Pass the temporary root through an explicit environment variable. Prefer a temporary `.ps1` invoked with `-File` and positional arguments over concatenating untrusted script text.

### 6.1 Module Lifecycle

Verify that import changes no environment/files; initialization applies the correct environment; repeated initialization does not duplicate hooks or paths; removal restores state; and `Import-Module -Force` does not recapture managed values as original values.

### 6.2 Command Flow

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

After every step, verify `current`, origin, home, first `PATH` entry, and registry contents.

### 6.3 `exec`

Verify explicit version override without writing `JENV_VERSION`; exact preservation of arguments containing spaces, quotes, `$()`, semicolons, and Unicode; restoration after success, nonzero exit, exception, and interruption; nested stack behavior; target `$LASTEXITCODE`; and rejection when `--` is absent.

### 6.4 Prompt Hook

Call the installed ScriptBlock directly. Verify local switching after `Set-Location`, unchanged original prompt output, wrapping of an existing custom prompt, no extra success output, WARN when a theme replaces the hook, safe uninstall after replacement, visible errors from the original prompt, and no recursion.

### 6.5 Profile

Cover empty/missing files and parents, CRLF/LF, UTF-8 with/without BOM, idempotent installation, unmatched/duplicate markers with byte-for-byte preservation, default refusal for signed profiles, exact managed-block removal, and backups containing exact pre-replacement content.

## 7. Security Tests

Include hostile values such as aliases containing commands, paths containing `$()`, quoted arguments with semicolons, executable-looking release values, deeply nested JSON, oversized strings, and case-only duplicate keys.

Assert that nothing executes, no network access occurs, out-of-scope files are untouched, error targets/logs do not expand complete environments or sensitive file contents, and failed profile/configuration writes preserve every byte. Limit registry files to a reasonable size such as 10 MiB and version files to 4 KiB; fail explicitly above those limits.

## 8. Performance Tests

With 25 JDKs and 100 aliases on local NTFS:

| Operation | Target median |
| --- | --- |
| Unchanged cached prompt hook | < 10 ms |
| Cold version resolution | < 50 ms |
| `jenv current` | < 100 ms |
| `jenv versions` | < 200 ms |

Exclude Java process probing. These are normally nonblocking targets, but performance above twice the target requires explanation in release notes.

## 9. Static Checks

Enable at least `PSAvoidUsingInvokeExpression`, `PSAvoidUsingCmdletAliases`, `PSUseApprovedVerbs`, `PSAvoidUsingPositionalParameters`, `PSUseShouldProcessForStateChangingFunctions`, `PSReviewUnusedParameter`, and `PSUseDeclaredVarsMoreThanAssignments`.

Also verify the manifest, documented-only exports, complete Public function help, absence of developer-machine paths/JDK binaries, valid Markdown links, and parseable JSON examples.

## 10. CI Matrix

Every pull request runs on Windows with PowerShell 7.4 (minimum) and the latest supported PowerShell 7. Both run analyzer, unit/integration tests, `Test-ModuleManifest`, packaged-module import tests, and documentation link/example checks. Run acceptance tests at least on 7.4. Keep real-profile or interactive-host manual tests in the release checklist rather than changing the runner's actual profile.

## 11. Release Acceptance Checklist

- [ ] `add` recognizes Corretto 8, Temurin 17, and at least one Java 21 JDK.
- [ ] All shell > local > global > system cases pass.
- [ ] After 100 switches, `PATH` contains at most one managed bin.
- [ ] Paths with spaces/Unicode work for add, current, and exec.
- [ ] A new `pwsh` loads the correct local/global version from the profile.
- [ ] `exec` restores state after success, failure, and interruption.
- [ ] System restores pre-init state while retaining unrelated later `PATH` changes.
- [ ] Concurrent registry writes lose no data; corruption is never overwritten.
- [ ] Profile install, idempotency, uninstall, and malformed-marker protection pass.
- [ ] `doctor` locates missing JDKs, invalid versions, and replaced prompt hooks.
- [ ] CI passes on PowerShell 7.4 and the latest supported PowerShell 7.
- [ ] The release contains no temporary test files, user paths, or JDK binaries.
