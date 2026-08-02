Set-StrictMode -Version Latest

# Centralized error factory. Per docs/development.md section 5, every failure path goes
# through here so that FullyQualifiedErrorId is a stable automation contract.
# Tests assert FullyQualifiedErrorId and TargetObject, never the prose message.
#
# Stable error IDs (extend as needed; do not reuse or rename in a minor version):
#   JEnv.Platform.Unsupported
#   JEnv.PowerShellVersion.Unsupported
#   JEnv.Jdk.InvalidHome
#   JEnv.Jdk.ProbeFailed
#   JEnv.Version.NotInstalled
#   JEnv.Version.InUse
#   JEnv.VersionFile.Invalid
#   JEnv.Alias.Conflict
#   JEnv.Registry.Invalid
#   JEnv.Registry.LockTimeout
#   JEnv.Profile.UpdateFailed
#   JEnv.Command.NotFound
#   JEnv.Command.Unknown
#   JEnv.Location.NotFileSystem
#   JEnv.Version.SystemHasNoHome
#   JEnv.NotInitialized

function New-JenvErrorRecord {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure ErrorRecord factory; it does not modify state.')]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter()]
        [System.Management.Automation.ErrorCategory]$Category = [System.Management.Automation.ErrorCategory]::OperationStopped,

        [Parameter()]
        $TargetObject
    )

    $exception = [System.Exception]::new($Message)
    return [System.Management.Automation.ErrorRecord]::new($exception, $Id, $Category, $TargetObject)
}

# Convenience wrapper: throw a JEnv error with a stable ID.
function ThrowJenvError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Id,
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][System.Management.Automation.ErrorCategory]$Category = [System.Management.Automation.ErrorCategory]::OperationStopped,
        [Parameter()]$TargetObject
    )
    throw (New-JenvErrorRecord -Id $Id -Message $Message -Category $Category -TargetObject $TargetObject)
}
