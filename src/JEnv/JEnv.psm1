Set-StrictMode -Version Latest

# JEnv module loader.
#
# Per docs/development.md section 2, files are dot-sourced in a fixed, explicit order
# (NOT via Get-ChildItem implicit ordering) so that dependencies between private
# helpers are always satisfied. Private first, then Public, then a single
# Export-ModuleMember call.

$script:__JEnvModuleRoot = $PSScriptRoot

$script:__JEnvPrivateFiles = @(
    'Errors',
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
