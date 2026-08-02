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

    $commandArguments = @($ArgumentList | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    if ($commandArguments.Count -eq 0) {
        throw (New-JenvErrorRecord -Id 'JEnv.Command.NotFound' `
            -Message "jenv exec requires a command after '--'." -Category InvalidArgument)
    }

    $command = $commandArguments[0]
    $cmdArgs = @()
    if ($commandArguments.Count -gt 1) { $cmdArgs = @($commandArguments[1..($commandArguments.Count - 1)]) }

    $resolved = Resolve-JenvRequiredVersion -Version $Version -Root $Root
    $snapshot = Get-JenvProcessEnvironmentSnapshot

    try {
        if ($resolved.OriginKind -eq 'System') {
            if ($null -ne $script:JEnvSession) {
                if (-not [string]::IsNullOrEmpty($script:JEnvSession.ManagedBin)) {
                    [Environment]::SetEnvironmentVariable(
                        'PATH',
                        (Remove-JenvManagedPathEntry -CurrentPath $env:PATH -ManagedBin $script:JEnvSession.ManagedBin),
                        'Process')
                }
                Restore-JenvOwnedEnvironment -Name 'JAVA_HOME' `
                    -ManagedValue $script:JEnvSession.ManagedJavaHome -Original $script:JEnvSession.OriginalJavaHome
                Restore-JenvOwnedEnvironment -Name 'JDK_HOME' `
                    -ManagedValue $script:JEnvSession.ManagedJdkHome -Original $script:JEnvSession.OriginalJdkHome
            }
        } elseif (-not [string]::IsNullOrEmpty($resolved.Home)) {
            $bin = Join-Path $resolved.Home 'bin'
            [Environment]::SetEnvironmentVariable('JAVA_HOME', $resolved.Home, 'Process')
            [Environment]::SetEnvironmentVariable('JDK_HOME', $resolved.Home, 'Process')
            $oldManagedBin = if ($null -ne $script:JEnvSession) { $script:JEnvSession.ManagedBin } else { '' }
            [Environment]::SetEnvironmentVariable(
                'PATH',
                (Build-JenvManagedPath -CurrentPath $env:PATH -OldManagedBin $oldManagedBin -TargetBin $bin),
                'Process')
        }

        $resolvedCommand = Get-Command -Name $command -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $resolvedCommand) {
            throw (New-JenvErrorRecord -Id 'JEnv.Command.NotFound' `
                -Message "Command '$command' was not found for jenv exec." `
                -Category ObjectNotFound -TargetObject $command)
        }

        if ($cmdArgs.Count -gt 0) {
            & $resolvedCommand @cmdArgs
        } else {
            & $resolvedCommand
        }
    } finally {
        Restore-JenvProcessEnvironment -Snapshot $snapshot
    }
}
