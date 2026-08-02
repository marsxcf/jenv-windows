Set-StrictMode -Version Latest

# Process-environment primitives: snapshot/restore (for `jenv exec` isolation),
# the PATH ownership rebuild, and ownership-based restore for the `system` state.
# See docs/powershell-integration.md section 4-5.

# Capture existence + value of the process variables jenv manages, for later
# exact restoration (used by `jenv exec`).
function Get-JenvProcessEnvironmentSnapshot {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    return [pscustomobject]@{
        PSTypeName = 'JEnv.EnvironmentSnapshot'
        JavaHome = @{ Exists = (-not [string]::IsNullOrEmpty($env:JAVA_HOME)); Value = $env:JAVA_HOME }
        JdkHome  = @{ Exists = (-not [string]::IsNullOrEmpty($env:JDK_HOME));  Value = $env:JDK_HOME }
        Path     = @{ Exists = (-not [string]::IsNullOrEmpty($env:PATH));     Value = $env:PATH }
    }
}

# Restore the three managed variables to a snapshot exactly.
function Restore-JenvProcessEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Snapshot)

    if ($Snapshot.JavaHome.Exists) {
        [Environment]::SetEnvironmentVariable('JAVA_HOME', $Snapshot.JavaHome.Value, 'Process')
    } else {
        [Environment]::SetEnvironmentVariable('JAVA_HOME', $null, 'Process')
    }
    if ($Snapshot.JdkHome.Exists) {
        [Environment]::SetEnvironmentVariable('JDK_HOME', $Snapshot.JdkHome.Value, 'Process')
    } else {
        [Environment]::SetEnvironmentVariable('JDK_HOME', $null, 'Process')
    }
    if ($Snapshot.Path.Exists) {
        [Environment]::SetEnvironmentVariable('PATH', $Snapshot.Path.Value, 'Process')
    } else {
        [Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
    }
}

# Rebuild PATH for a managed switch: remove entries equal to the previous
# managed bin and to the target bin (case-insensitive, normalization-aware),
# then prepend the target bin. All other entries (including empty ones and paths
# added by other tools after init) are preserved in order.
function Build-JenvManagedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowEmptyString()][string]$CurrentPath,
        [Parameter()][AllowEmptyString()][string]$OldManagedBin,
        [Parameter(Mandatory)][string]$TargetBin
    )

    $sep = [System.IO.Path]::PathSeparator
    if ([string]::IsNullOrEmpty($CurrentPath)) {
        $entries = @()
    } else {
        $entries = $CurrentPath -split $sep
    }

    $hasOld = -not [string]::IsNullOrEmpty($OldManagedBin)
    $filtered = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $entries) {
        $drop = $false
        if ($hasOld -and (Test-JenvPathsEqual -ReferencePath $e -DifferencePath $OldManagedBin)) { $drop = $true }
        if (-not $drop -and (Test-JenvPathsEqual -ReferencePath $e -DifferencePath $TargetBin)) { $drop = $true }
        if (-not $drop) { [void]$filtered.Add($e) }
    }

    $result = [System.Collections.Generic.List[string]]::new()
    [void]$result.Add($TargetBin)
    foreach ($e in $filtered) { [void]$result.Add($e) }
    return ($result -join $sep)
}

# Remove all entries equal to $ManagedBin from PATH (for the system state).
function Remove-JenvManagedPathEntry {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure string transformation; it does not modify process state.')]
    [OutputType([string])]
    param(
        [Parameter()][AllowEmptyString()][string]$CurrentPath,
        [Parameter()][AllowEmptyString()][string]$ManagedBin
    )
    if ([string]::IsNullOrEmpty($ManagedBin)) { return $CurrentPath }
    $sep = [System.IO.Path]::PathSeparator
    if ([string]::IsNullOrEmpty($CurrentPath)) { return $CurrentPath }
    $entries = $CurrentPath -split $sep
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $entries) {
        if (-not (Test-JenvPathsEqual -ReferencePath $e -DifferencePath $ManagedBin)) { [void]$kept.Add($e) }
    }
    return ($kept -join $sep)
}

# Ownership-based restore for a single variable. Only restore the original if
# the current value still equals the value jenv last wrote; otherwise a caller
# has taken ownership and we leave it alone.
function Restore-JenvOwnedEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][string]$ManagedValue,
        [Parameter(Mandatory)]$Original
    )
    $current = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrEmpty($ManagedValue)) { return }
    if (-not (Test-JenvPathsEqual -ReferencePath $current -DifferencePath $ManagedValue)) { return }

    if ($Original.Exists) {
        [Environment]::SetEnvironmentVariable($Name, $Original.Value, 'Process')
    } else {
        [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
    }
}

# Apply the `system` state: drop the managed bin from PATH and ownership-restore
# JAVA_HOME/JDK_HOME. Clears Managed* on the session state.
function Sync-JenvSystemState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)

    if (-not [string]::IsNullOrEmpty($State.ManagedBin)) {
        $env:PATH = Remove-JenvManagedPathEntry -CurrentPath $env:PATH -ManagedBin $State.ManagedBin
    }
    Restore-JenvOwnedEnvironment -Name 'JAVA_HOME' -ManagedValue $State.ManagedJavaHome -Original $State.OriginalJavaHome
    Restore-JenvOwnedEnvironment -Name 'JDK_HOME' -ManagedValue $State.ManagedJdkHome -Original $State.OriginalJdkHome

    $State.ManagedBin = $null
    $State.ManagedJavaHome = $null
    $State.ManagedJdkHome = $null
    $State.LastSyncedCanonical = $null
}
