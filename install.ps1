#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter()][switch]$Force
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Dev / local installer: copies the module to the current user's PowerShell 7
# module path so `Import-Module JEnv` (and module auto-loading) work. It does NOT
# modify the PowerShell Profile — run `jenv init --install` afterwards to hook it
# in. Never modifies User/Machine PATH or environment variables.

$src = Join-Path $PSScriptRoot 'src\JEnv'
$manifestPath = Join-Path $src 'JEnv.psd1'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Module manifest not found at '$manifestPath'." }
$ver = (Test-ModuleManifest -Path $manifestPath).Version.ToString()

# CurrentUser module base. Prefer the first PSModulePath entry under $HOME so a
# redirected Documents folder (e.g. OneDrive) is handled.
$cuBase = $null
foreach ($p in ($env:PSModulePath -split ';')) {
    if ($p -and ($p -like "$HOME*")) { $cuBase = $p; break }
}
if (-not $cuBase) { $cuBase = Join-Path $HOME 'Documents\PowerShell\Modules' }
$dest = Join-Path $cuBase "JEnv\$ver"

if (Test-Path -LiteralPath $dest) {
    if (-not $Force) {
        throw "JEnv $ver is already installed at '$dest'. Use -Force to overwrite."
    }
}
if (-not $PSCmdlet.ShouldProcess($dest, "Install JEnv $ver")) { return }

if (Test-Path -LiteralPath $dest) { Remove-Item -Recurse -Force $dest }
New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
Copy-Item -Path (Join-Path $src '*') -Destination $dest -Recurse -Force
Test-ModuleManifest -Path (Join-Path $dest 'JEnv.psd1') | Out-Null

Write-Host "Installed JEnv $ver to $dest" -ForegroundColor Green
Write-Host "Open a new PowerShell 7 session (or run 'Import-Module JEnv'), then:" -ForegroundColor Cyan
Write-Host "    jenv init --install" -ForegroundColor Cyan
Write-Host "(That patches `$PROFILE.CurrentUserAllHosts; restart your terminal afterwards.)"
