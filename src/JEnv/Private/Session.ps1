Set-StrictMode -Version Latest

# Module session state. A single object holds the values captured at
# initialization plus the values jenv last wrote, enabling the ownership model
# and idempotent sync. See docs/powershell-integration.md section 6 and architecture.md section 6.

$script:JEnvSession = $null

# Lazily create the session the first time a command needs it (e.g. `jenv shell`
# without a prior `jenv init`). Implicit creation captures the original
# environment but does NOT install the prompt hook - only Initialize-Jenv does.
function Get-JenvSessionState {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    if ($null -eq $script:JEnvSession) {
        $null = New-JenvSessionState
    }
    return $script:JEnvSession
}

# Create (or reset) the session, capturing the current JAVA_HOME/JDK_HOME as the
# originals. Idempotent re-init must NOT re-capture an already-managed env as the
# "original" (docs/powershell-integration.md section 3.2).
function New-JenvSessionState {
    [CmdletBinding()]
    param()

    $originalJavaExists = (-not [string]::IsNullOrEmpty($env:JAVA_HOME))
    $originalJdkExists = (-not [string]::IsNullOrEmpty($env:JDK_HOME))

    # If a previous session existed, preserve its captured originals.
    $priorJava = @{ Exists = $originalJavaExists; Value = $env:JAVA_HOME }
    $priorJdk = @{ Exists = $originalJdkExists; Value = $env:JDK_HOME }
    if ($script:JEnvSession) {
        $priorJava = $script:JEnvSession.OriginalJavaHome
        $priorJdk = $script:JEnvSession.OriginalJdkHome
    }

    $script:JEnvSession = @{
        Initialized         = $false
        OriginalJavaHome    = $priorJava
        OriginalJdkHome     = $priorJdk
        ManagedJavaHome     = $null
        ManagedJdkHome      = $null
        ManagedBin          = $null
        LastSyncedCanonical = $null
        LastFingerprint     = $null
        PreviousPrompt      = $null
        PromptHook          = $null
        PromptInstalled     = $false
    }
    return $script:JEnvSession
}

# Tear down the session (used by Remove-Module / uninstall): restore the env via
# the ownership rules and clear state.
function Reset-JenvSessionState {
    [CmdletBinding()]
    param()
    if ($null -eq $script:JEnvSession) { return }
    Sync-JenvSystemState -State $script:JEnvSession
    $script:JEnvSession = $null
}
