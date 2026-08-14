# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Error IDs (`FullyQualifiedErrorId`), Public API names, and `versions.json`
field names are part of the compatibility contract: they only change in a
major version.

## [Unreleased]

### Changed

- Distribution moved to PowerShell Gallery (`Install-Module JEnv`) after the
  winget submission was rejected under the noScripts policy: the package is a
  PowerShell module with no compiled binary, which winget-pkgs does not accept.
  The per-user Inno Setup installer remains available on GitHub Releases as a
  convenience. Release CI now publishes to PowerShell Gallery (gated on the
  `PSGALLERY_API_KEY` secret) and no longer renders/submits a winget manifest.

## [0.1.0] - 2026-08-03

### Added

- JDK registry with canonical IDs and aliases (`add`, `remove`, `versions`).
- Three-scope version selection: `shell` > `local` (`.java-version`) > `global` > `system`.
- In-process `JAVA_HOME` / `JDK_HOME` / `PATH` management with an ownership model
  that survives PATH edits made by other tools after initialization.
- `jenv exec` for deterministic, prompt-hook-free command execution.
- `prompt` hook with resolution fingerprinting for automatic directory switching.
- Profile integration (`jenv init --install` / `--uninstall`).
- `doctor`, `current`, `home`, `which`, `refresh`, `root`, `help`.
- `--json` / `--bare` machine-readable output.
- Per-user Inno Setup installer (convenience installer for GitHub Releases).

### Fixed

- Aligned registry validation, session cleanup, version removal, `exec`, prompt,
  Profile, build, installer, and CI behavior with the documented 0.1 contract.
