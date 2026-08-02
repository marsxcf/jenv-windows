#
# Module manifest for JEnv (jenv-windows)
#
@{
    RootModule           = 'JEnv.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '585CEFF5-B3E1-4F24-AD94-412EB1073E5E'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    HelpInfoURI          = ''

    Author               = 'jenv-windows contributors'
    CompanyName          = 'jenv-windows'
    Copyright            = '(c) 2026 jenv-windows contributors. MIT license.'
    Description          = @'
JDK version selector for Windows PowerShell 7. Registers already-installed
JDKs and switches the active JDK in the current session across shell/local/
global/system scopes. A Windows-native reimagining of jenv.
'@

    # Only the documented Public surface is exported. See docs/development.md section 3.
    FunctionsToExport    = @(
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
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    DscResourcesToExport = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Java', 'JDK', 'jenv', 'PowerShell', 'Windows', 'JavaVersion')
            LicenseUri   = 'https://github.com/marsxcf/jenv-windows/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/marsxcf/jenv-windows'
            ReleaseNotes = 'See CHANGELOG.md.'
            Prerelease   = ''
        }
    }
}
