Set-StrictMode -Version Latest

# JEnv module loader.
#
# Per docs/development.md section 2, files are dot-sourced in a fixed, explicit order
# (NOT via Get-ChildItem implicit ordering) so that dependencies between private
# helpers are always satisfied. Private first, then Public, then a single
# Export-ModuleMember call.

$script:__JEnvModuleRoot = $PSScriptRoot

# Load the error factory first so runtime guard failures use the documented,
# stable FullyQualifiedErrorId values.
$script:__JEnvErrorsPath = Join-Path $script:__JEnvModuleRoot 'Private\Errors.ps1'
. $script:__JEnvErrorsPath
Remove-Variable -Name __JEnvErrorsPath -ErrorAction SilentlyContinue

if (-not $IsWindows -or $PSEdition -ne 'Core') {
    throw (New-JenvErrorRecord -Id 'JEnv.Platform.Unsupported' `
        -Message 'jenv-windows requires Windows PowerShell Core.' `
        -Category NotImplemented -TargetObject $PSVersionTable.Platform)
}
if ($PSVersionTable.PSVersion -lt [version]'7.4.0') {
    throw (New-JenvErrorRecord -Id 'JEnv.PowerShellVersion.Unsupported' `
        -Message "jenv-windows requires PowerShell 7.4 or newer (current: $($PSVersionTable.PSVersion))." `
        -Category NotImplemented -TargetObject $PSVersionTable.PSVersion)
}

$script:__JEnvPrivateFiles = @(
    'Paths',
    'Json',
    'Registry',
    'JdkProbe',
    'VersionResolver',
    'Environment',
    'Session',
    'Profile',
    'Prompt'
)

$script:__JEnvPublicFiles = @(
    'JdkCommands',
    'VersionCommands',
    'Invoke-JenvCommand',
    'Sync-JenvEnvironment',
    'Test-JenvInstallation',
    'Initialize-Jenv',
    'Invoke-JenvFacade'
)

foreach ($__file in $script:__JEnvPrivateFiles) {
    $__path = Join-Path $script:__JEnvModuleRoot (Join-Path 'Private' "$__file.ps1")
    if (Test-Path -LiteralPath $__path) {
        . $__path
    }
}
Remove-Variable -Name __file, __path -ErrorAction SilentlyContinue

foreach ($__file in $script:__JEnvPublicFiles) {
    $__path = Join-Path $script:__JEnvModuleRoot (Join-Path 'Public' "$__file.ps1")
    if (Test-Path -LiteralPath $__path) {
        . $__path
    }
}
Remove-Variable -Name __file, __path -ErrorAction SilentlyContinue

# Restore only state still owned by this module instance. This callback also
# makes Import-Module -Force safe: the old instance restores its managed
# environment before the replacement captures a new baseline.
$ExecutionContext.SessionState.Module.OnRemove = {
    if ($null -ne $script:JEnvSession) {
        try {
            Disable-JenvPromptHook
        } finally {
            Reset-JenvSessionState
        }
    }
}

Export-ModuleMember -Function @(
    'jenv',
    'Initialize-Jenv',
    'Register-JenvJdk',
    'Unregister-JenvJdk',
    'Get-JenvJdk',
    'Get-JenvCurrent',
    'Set-JenvGlobal',
    'Set-JenvLocal',
    'Set-JenvShell',
    'Sync-JenvEnvironment',
    'Invoke-JenvCommand',
    'Test-JenvInstallation'
)
