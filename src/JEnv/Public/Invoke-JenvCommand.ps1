Set-StrictMode -Version Latest

# `jenv exec`: run a command with the resolved (or explicit) JDK applied to a
# transient process environment, then restore the caller's environment in a
# finally. Does NOT touch the session Managed* state or $LASTEXITCODE (other than
# what the target command itself sets). See docs/command-reference.md section 12 and
# docs/powershell-integration.md section 8.
function Invoke-JenvCommand {
    [CmdletBinding()]
    param(
        [Parameter()][string]$Version,
        [Parameter(Mandatory)][object[]]$ArgumentList,
        [Parameter()][string]$Root = (Get-JenvRoot)
    )

    $args = @($ArgumentList | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    if ($args.Count -eq 0) {
        throw (New-JenvErrorRecord -Id 'JEnv.Command.NotFound' `
            -Message "jenv exec requires a command after '--'." -Category InvalidArgument)
    }

    $command = $args[0]
    $cmdArgs = @()
    if ($args.Count -gt 1) { $cmdArgs = @($args[1..($args.Count - 1)]) }

    $resolved = Resolve-JenvRequiredVersion -Version $Version -Root $Root
    $snapshot = Get-JenvProcessEnvironmentSnapshot

    try {
        if ($resolved.OriginKind -ne 'System' -and -not [string]::IsNullOrEmpty($resolved.Home)) {
            $bin = Join-Path $resolved.Home 'bin'
            [Environment]::SetEnvironmentVariable('JAVA_HOME', $resolved.Home, 'Process')
            [Environment]::SetEnvironmentVariable('JDK_HOME', $resolved.Home, 'Process')
            [Environment]::SetEnvironmentVariable('PATH', ($bin + [System.IO.Path]::PathSeparator + $env:PATH), 'Process')
        }

        if ($cmdArgs.Count -gt 0) {
            & $command @cmdArgs
        } else {
            & $command
        }
    } finally {
        Restore-JenvProcessEnvironment -Snapshot $snapshot
    }
}
