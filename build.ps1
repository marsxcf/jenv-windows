#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter()][string]$Version,
    [Parameter()][switch]$SkipTests,
    [Parameter()][switch]$SkipAnalyze
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = $PSScriptRoot
$src = Join-Path $repoRoot 'src\JEnv'
$manifestPath = Join-Path $src 'JEnv.psd1'
$artifacts = Join-Path $repoRoot 'artifacts'

if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Module manifest not found at '$manifestPath'." }
$manifestVersion = (Test-ModuleManifest -Path $manifestPath).Version.ToString()
if ([string]::IsNullOrEmpty($Version)) {
    $Version = $manifestVersion
} elseif ($Version -ne $manifestVersion) {
    throw "Requested build version '$Version' does not match manifest ModuleVersion '$manifestVersion'. Update JEnv.psd1 first."
}
Write-Host "Building jenv-windows $Version" -ForegroundColor Cyan

# 1. Static analysis
if (-not $SkipAnalyze) {
    if (Get-Module -ListAvailable PSScriptAnalyzer) {
        Write-Host '-> PSScriptAnalyzer' -ForegroundColor Cyan
        $results = Invoke-ScriptAnalyzer -Path $src -Severity Error, Warning, Information
        $errors = @($results | Where-Object { $_.Severity -eq 'Error' })
        if ($errors.Count -gt 0) {
            $errors | Format-Table -AutoSize
            throw "PSScriptAnalyzer reported $($errors.Count) error(s)."
        }
        $warnCount = @($results | Where-Object { $_.Severity -eq 'Warning' }).Count
        Write-Host "   $(@($results).Count) rule hit(s), $($warnCount) warning(s), 0 errors."
    } else {
        Write-Warning 'PSScriptAnalyzer not installed; skipping static analysis.'
    }
}

# 2. Tests
if (-not $SkipTests) {
    Write-Host '-> Pester' -ForegroundColor Cyan
    $testFiles = @(Get-ChildItem -Path (Join-Path $repoRoot 'tests') -Filter 'JEnv.*.ps1' -File)
    $r = Invoke-Pester -Path $testFiles.FullName -PassThru -Output Minimal
    $failedCount = if ($null -ne $r.PSObject.Properties['FailedCount']) { $r.FailedCount } else { $r.Failed }
    $passedCount = if ($null -ne $r.PSObject.Properties['PassedCount']) { $r.PassedCount } else { $r.Passed }
    if ($failedCount -gt 0) { throw "Pester: $failedCount test(s) failed." }
    Write-Host "   $passedCount passed, $failedCount failed."
}

# 3. Assemble staging copy
$staging = Join-Path $artifacts "JEnv\$Version"
if (Test-Path -LiteralPath $staging) { Remove-Item -Recurse -Force $staging }
New-Item -ItemType Directory -Force -Path $staging | Out-Null
Get-ChildItem -LiteralPath $src -Force | Copy-Item -Destination $staging -Recurse -Force

# 4. Validate the staged manifest
Test-ModuleManifest -Path (Join-Path $staging 'JEnv.psd1') | Out-Null

# 5. Zip + hash
$zip = Join-Path $artifacts "JEnv.$Version.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip
$hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash

Write-Host "Done." -ForegroundColor Green
Write-Host "  Module: $staging"
Write-Host "  Zip:    $zip"
Write-Host "  SHA256: $hash"
