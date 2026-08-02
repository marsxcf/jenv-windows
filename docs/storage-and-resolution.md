# Configuration, Storage, and Version Resolution

## 1. JENV Root

Use nonempty `$env:JENV_ROOT` when set; otherwise use `Join-Path $HOME '.jenv'`. The root must normalize to an absolute filesystem path. Reject relative paths, non-filesystem providers, and CR/LF. Remove trailing separators not required for a root without changing on-disk case.

Read-only commands treat a missing root as an empty registry with no global version. Mutating commands create directories as needed. Module import itself creates nothing.

## 2. Directory Layout

```text
%USERPROFILE%\.jenv\
├─ versions.json          # JDK registry and aliases
├─ version                # global version expression
├─ backups\               # most recent replacement backups
└─ tmp\                   # same-volume temporary files, always cleaned
```

Version 0.1 does not create upstream jenv `versions` symlinks or a `shims` directory. Projects may contain `<project>\.java-version`.

## 3. Environment Variables

| Variable | User-settable | Lifetime | Meaning |
| --- | --- | --- | --- |
| `JENV_ROOT` | Yes | Caller-defined | Overrides the default root. |
| `JENV_VERSION` | Yes | Process and children | Shell-layer expression. |
| `JAVA_HOME` | Yes | Process | Managed after initialization with ownership protection. |
| `JDK_HOME` | Yes | Process | Matches the selected JDK home. |
| `PATH`/`Path` | Yes | Process | jenv manages only its single inserted `bin` entry. |

Environment-variable names are case-insensitive on Windows. Internally use `$env:Path` without assuming external display casing.

## 4. `versions.json` Schema

UTF-8 without BOM, using LF:

```json
{
  "schemaVersion": 1,
  "revision": 3,
  "jdks": {
    "corretto64-1.8.0.442": {
      "home": "D:\\SDKs\\amazon-corretto-8",
      "version": "1.8.0_442",
      "normalizedVersion": "1.8.0.442",
      "major": 8,
      "vendor": "Amazon.com Inc.",
      "vendorId": "corretto",
      "architecture": "x64",
      "registeredAt": "2026-08-02T03:20:00Z",
      "updatedAt": "2026-08-02T03:20:00Z"
    },
    "temurin64-17.0.12": {
      "home": "D:\\SDKs\\temurin-17",
      "version": "17.0.12+7",
      "normalizedVersion": "17.0.12",
      "major": 17,
      "vendor": "Eclipse Adoptium",
      "vendorId": "temurin",
      "architecture": "x64",
      "registeredAt": "2026-08-02T03:22:00Z",
      "updatedAt": "2026-08-02T03:22:00Z"
    }
  },
  "aliases": {
    "8": "corretto64-1.8.0.442",
    "1.8": "corretto64-1.8.0.442",
    "corretto8": "corretto64-1.8.0.442",
    "17": "temurin64-17.0.12",
    "temurin17": "temurin64-17.0.12"
  }
}
```

### 4.1 Field Constraints

| Field | Constraint |
| --- | --- |
| `schemaVersion` | Integer `1`; reject unknown major schema versions. |
| `revision` | Nonnegative integer incremented after each successful write; diagnostic only. |
| `jdks` | Mapping from canonical ID to JDK record. |
| `home` | Normalized absolute path compared with `OrdinalIgnoreCase`. |
| `version` | Raw Java version from JDK metadata. |
| `normalizedVersion` | Version used for IDs, aliases, and sorting. |
| `major` | Positive integer; Java `1.8.x` maps to `8`. |
| `vendor` | Detected display name. |
| `vendorId` | Stable lowercase vendor identifier. |
| `architecture` | `x86`, `x64`, `arm64`, or `unknown`. |
| `registeredAt` | UTC ISO 8601 time of first registration. |
| `updatedAt` | UTC ISO 8601 time of last update. |
| `aliases` | Alias-to-canonical-ID mapping; every target must exist in `jdks`. |

Canonical IDs resolve directly and need not be repeated in `aliases`. Compare all IDs and aliases with `OrdinalIgnoreCase`; case-only duplicates indicate corruption.

### 4.2 Forward Compatibility

Schema 1 readers allow unknown object properties and preserve them on write so older 0.1.x tools do not destroy newer optional data. Unknown `schemaVersion` values fail and are never downgraded.

## 5. Version Expressions

Expressions used in `$env:JENV_VERSION`, `version`, and `.java-version` match:

```regex
^[A-Za-z0-9][A-Za-z0-9._+\-]{0,127}$
```

Reserved `system` selects no registered JDK and cannot be an ID or alias. Version files are UTF-8 with optional BOM. Remove trailing CR/LF, then trim surrounding whitespace once. The remaining content must be exactly one valid expression. Comments, multiple versions, quoting, PowerShell expressions, empty files, and multiline content fail with `JEnv.VersionFile.Invalid`.

## 6. JDK Metadata Probing

### 6.1 Path Validation

Registration requires both `<home>\bin\java.exe` and `<home>\bin\javac.exe` as files; version 0.1 does not register a JRE. Normalize with `[IO.Path]::GetFullPath()` and filesystem existence checks. Reject `;`, CR, and LF because the home cannot safely form one Windows `PATH` entry.

### 6.2 `release` File

Prefer `<home>\release`, commonly containing:

```text
JAVA_VERSION="17.0.12"
IMPLEMENTOR="Eclipse Adoptium"
OS_ARCH="x86_64"
```

Accept only `KEY=VALUE`, remove one pair of surrounding double quotes, and decode only the release format's basic escapes. Never execute the file.

### 6.3 Java Process Fallback

If version, vendor, or architecture is missing, run `<home>\bin\java.exe -XshowSettings:properties -version` with `UseShellExecute = false` and `ArgumentList`. Read stdout/stderr asynchronously, use a 10-second default timeout, and kill the process tree on timeout. A nonzero exit is acceptable only if all required properties parse successfully.

### 6.4 Version Normalization

- For Java 8 and earlier `1.8.0_442`, major is `8` and normalized version is `1.8.0.442`.
- For Java 9+, major is the first component; remove build metadata, so `17.0.12+7` becomes `17.0.12`.
- Registration fails if a positive integer major cannot be determined.

Vendor mappings include Amazon/Corretto → `corretto`, Adoptium/Temurin → `temurin`, Oracle → `oracle`, Azul/Zulu → `zulu`, Microsoft → `microsoft`, BellSoft/Liberica → `liberica`, SAP/SapMachine → `sapmachine`, and GraalVM → `graalvm`; otherwise choose `openjdk` or `other` from runtime text.

Architecture mappings are `amd64`/`x86_64` → `x64`, `aarch64` → `arm64`, and `x86`/`i386` → `x86`.

Canonical IDs use `<vendorId><architecture-bits>-<normalizedVersion>`, where `x64` maps to `64`, `x86` to `32`, `arm64` remains `arm64`, and unknown is omitted:

```text
corretto64-1.8.0.442
temurin64-17.0.12
microsoftarm64-21.0.4
```

## 7. Local File Discovery

Only search when the current location uses the FileSystem provider. Check `.java-version` in the current directory and then each parent through the volume root; the nearest match wins. Follow the logical path visible to the user rather than expanding directory junctions. Version 0.1 ignores `.jenv-version` and Maven, Gradle, or IDE-specific configuration.

## 8. Complete Resolution Algorithm

```text
Resolve-JenvVersion(currentDirectory):
    if JENV_VERSION exists and is not empty:
        requested = validate(JENV_VERSION); origin = Shell
    else if nearest .java-version exists:
        requested = readVersionFile(localFile); origin = Local(localFile)
    else if JENV_ROOT\version exists:
        requested = readVersionFile(globalFile); origin = Global(globalFile)
    else:
        requested = system; origin = System

    if requested equals system, OrdinalIgnoreCase:
        return System result
    if requested matches canonical ID:
        id = matching canonical ID
    else if requested matches alias:
        id = aliases[requested]
    else:
        throw JEnv.Version.NotInstalled with origin

    validate the registry record and current JDK files
    return the resolved JDK and origin
```

An invalid or unregistered higher-precedence value must fail instead of silently falling through, exposing project configuration errors immediately.

## 9. Read Consistency and Concurrent Writes

### 9.1 Named Mutex

Registry and global writes use a current-user-session mutex:

```text
Local\JEnv-<first 32 hexadecimal characters of SHA256(normalized JENV_ROOT)>
```

Wait five seconds by default, then throw `JEnv.Registry.LockTimeout`. After acquiring the lock, reread the target to avoid overwriting another process's update.

### 9.2 Atomic Replacement

Create a randomly named temporary file in the target directory, write and flush complete UTF-8 data, validate by rereading, preserve the previous file as a backup, atomically replace or rename, and clean temporary files in `finally`. Same-directory temporary files keep the operation on one volume. Increment `revision` only in the successfully committed content.

### 9.3 Corruption Handling

Malformed JSON, unsupported schema, dangling aliases, case-only duplicate keys, invalid paths, and missing required fields produce `JEnv.Registry.Invalid`. Read-only commands never overwrite corruption. Mutations fail and preserve the original bytes; recovery requires an explicit backup restore or user repair.

## 10. Sorting and Comparison

Use ordinal case-insensitive comparison for Windows paths, IDs, aliases, and reserved words. Use invariant numeric/version-aware comparison for Java versions, with lexical canonical ID as a stable tiebreaker. Never use current UI culture for persistence, identifiers, or ordering.
