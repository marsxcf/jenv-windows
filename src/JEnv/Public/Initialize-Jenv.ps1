Set-StrictMode -Version Latest

# `jenv init` / Initialize-Jenv: capture the original environment, apply the
# current resolution, and (in interactive hosts) install the prompt hook.
# Importing the module does none of this - only Initialize-Jenv mutates the
# session. See docs/powershell-integration.md section 3.
function Initialize-Jenv {
    [CmdletBinding()]
    param(
        [Parameter()][switch]$Install,
        [Parameter()][switch]$Uninstall,
        [Parameter()][string]$Root = (Get-JenvRoot)
    )

    if ($Uninstall) {
        Remove-JenvProfileBootstrap | Out-Null
        Disable-JenvPromptHook
        return
    }

    if ($Install) {
        Add-JenvProfileBootstrap | Out-Null
    }

    # Get-JenvSessionState lazily captures the original JAVA_HOME/JDK_HOME the
    # first time; re-init never re-captures an already-managed env as "original".
    $state = Get-JenvSessionState

    # One full resolution + sync. Errors here (e.g. a dangling .java-version)
    # prevent hook installation and leave Initialized = $false.
    Sync-JenvEnvironment -Root $Root -Force
    $state.LastFingerprint = Get-JenvResolutionFingerprint -Root $Root

    if (Test-JenvIsInteractiveHost) {
        Enable-JenvPromptHook
    }

    $state.Initialized = $true
}
