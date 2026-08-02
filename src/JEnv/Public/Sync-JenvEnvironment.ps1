Set-StrictMode -Version Latest

# Apply the resolved version to the current process. Implements the PATH
# ownership model (docs/powershell-integration.md section 5): remove the old managed bin
# and the target bin, prepend the target, preserve everything else. Idempotent
# when the resolved version has not changed.
function Sync-JenvEnvironment {
    [CmdletBinding()]
    param(
        [Parameter()][string]$Root = (Get-JenvRoot),
        [Parameter()][switch]$Force
    )

    $state = Get-JenvSessionState
    $resolved = Resolve-JenvVersion -Root $Root

    if ($resolved.OriginKind -eq 'System') {
        Sync-JenvSystemState -State $state
        return
    }

    $targetBin = Join-Path $resolved.Home 'bin'
    $oldManagedBin = if ($state.ManagedBin) { [string]$state.ManagedBin } else { [string]::Empty }

    # Idempotency: nothing to do if the resolved canonical is unchanged and the
    # process already reflects it.
    if (-not $Force) {
        $firstEntry = if (-not [string]::IsNullOrEmpty($env:PATH)) { ($env:PATH -split [System.IO.Path]::PathSeparator)[0] } else { '' }
        $pathOk = Test-JenvPathsEqual -ReferencePath $firstEntry -DifferencePath $targetBin
        $javaOk = Test-JenvPathsEqual -ReferencePath $env:JAVA_HOME -DifferencePath $resolved.Home
        if ([string]::Equals($state.LastSyncedCanonical, $resolved.CanonicalId, [System.StringComparison]::OrdinalIgnoreCase) -and $pathOk -and $javaOk) {
            return
        }
    }

    # Snapshot for rollback on partial failure.
    $snapPath = $env:PATH
    $snapJava = $env:JAVA_HOME
    $snapJdk = $env:JDK_HOME
    try {
        $env:PATH = Build-JenvManagedPath -CurrentPath $env:PATH -OldManagedBin $oldManagedBin -TargetBin $targetBin
        $env:JAVA_HOME = $resolved.Home
        $env:JDK_HOME = $resolved.Home
        $state.ManagedBin = $targetBin
        $state.ManagedJavaHome = $resolved.Home
        $state.ManagedJdkHome = $resolved.Home
        $state.LastSyncedCanonical = $resolved.CanonicalId
    } catch {
        $env:PATH = $snapPath
        $env:JAVA_HOME = $snapJava
        $env:JDK_HOME = $snapJdk
        throw
    }
}
