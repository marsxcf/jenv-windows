; jenv-windows Inno Setup installer (per-user, no admin).
;
; Build:
;   iscc /DAppVersion=0.1.0 /DSourceDir=..\artifacts\JEnv packaging\installer.iss
;
; Behaviour:
;   - copies the JEnv module to the current user's PowerShell 7 module path
;   - runs `jenv init --install` to patch $PROFILE.CurrentUserAllHosts idempotently
;   - uninstall runs `jenv init --uninstall` (restores the profile) then deletes
;     the module files; the user's versions.json registry is preserved.

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

#ifndef SourceDir
  ; build.ps1 stages the module at artifacts\JEnv\<version>\ (the manifest and
  ; .psm1 live directly here). Point at that so [Files] copies the module files
  ; themselves, not a wrapping <version> folder.
  #define SourceDir "..\artifacts\JEnv\" + AppVersion
#endif

[Setup]
AppId={{585CEFF5-B3E1-4F24-AD94-412EB1073E5E}
AppName=jenv-windows
AppVersion={#AppVersion}
AppPublisher=jenv-windows contributors
AppPublisherURL=https://github.com/jenv-windows/jenv-windows
AppLicenseFile=..\LICENSE
DefaultDirName={localappdata}\Programs\jenv-windows
DefaultGroupName=jenv-windows
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible arm64
ArchitecturesInstallIn64BitMode=x64compatible arm64
OutputBaseFilename=jenv-windows-{#AppVersion}-setup
OutputDir=Output
UninstallDisplayName=jenv-windows {#AppVersion}
; WinGet recognizes Inno Setup installers and applies /VERYSILENT /SUPPRESSMSGBOXES
; /NORESTART automatically, so `winget install` / `winget upgrade` are silent.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Stage the built module into the install directory; the post-install step moves
; it into the user's PowerShell module path so Import-Module / auto-load work.
Source: "{#SourceDir}\*"; DestDir: "{app}\JEnv"; Flags: recursesubdirs ignoreversion

[Run]
; Install the module into the CurrentUser module path and hook the profile.
; -ExecutionPolicy Bypass so the one-shot installer line can run unsigned.
Filename: "pwsh.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""$ErrorActionPreference='Stop'; $base=($env:PSModulePath -split ';' | Where-Object { $_ -and [IO.Path]::GetFullPath($_).StartsWith([IO.Path]::GetFullPath($HOME), [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1); if(-not $base){$base=Join-Path $HOME 'Documents\PowerShell\Modules'}; $dest=Join-Path $base ('JEnv\{#AppVersion}'); if(Test-Path -LiteralPath $dest){Remove-Item -Recurse -Force -LiteralPath $dest}; New-Item -ItemType Directory -Force -Path $dest | Out-Null; Get-ChildItem -LiteralPath '{app}\JEnv' -Force | Copy-Item -Destination $dest -Recurse -Force; Import-Module JEnv -Force; jenv init --install"""; \
  StatusMsg: "Installing JEnv module and hooking your PowerShell profile..."; \
  Flags: runhidden

[UninstallRun]
; Remove the profile hook first (restores the original prompt/env), then delete
; the module. versions.json under %USERPROFILE%\.jenv is intentionally preserved.
Filename: "pwsh.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""try { Import-Module JEnv -ErrorAction Stop; jenv init --uninstall } catch { }; $base=($env:PSModulePath -split ';' | Where-Object { $_ -and [IO.Path]::GetFullPath($_).StartsWith([IO.Path]::GetFullPath($HOME), [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1); if($base){ Remove-Item -Recurse -Force -LiteralPath (Join-Path $base 'JEnv\{#AppVersion}') -ErrorAction SilentlyContinue }"""; \
  Flags: runhidden

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
