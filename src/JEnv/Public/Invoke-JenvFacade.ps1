Set-StrictMode -Version Latest

# The `jenv` user-facing facade and its dispatcher. `jenv` is intentionally not
# Verb-Noun: it mirrors the upstream CLI name. Per-command GNU-style argument
# parsing lives here; it never re-splits already-parsed strings and always
# preserves argument boundaries (docs/development.md section 10).

$script:JEnvVersion = '0.1.0'

function jenv {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', 'jenv', Justification = 'Upstream jenv CLI facade name; intentionally not Verb-Noun.')]
    param(
        [Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments
    )
    # Capture raw arguments ourselves so a subcommand's own args (e.g. `pwsh
    # -Command`) never collide with named parameters, and so `--` is handled
    # predictably (PowerShell consumes the first `--`; we don't rely on seeing it).
    $all = @()
    if ($Arguments) { $all = @($Arguments | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) }
    $command = if ($all.Count -gt 0) { $all[0] } else { 'help' }
    $rest = @()
    if ($all.Count -gt 1) { $rest = @($all[1..($all.Count - 1)]) }
    Invoke-JenvFacade -Command $command -Arguments $rest
}

function Invoke-JenvFacade {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter()][object[]]$Arguments
    )

    # Normalize arguments to a clean string array, dropping $nulls.
    $rest = @()
    if ($Arguments) {
        $rest = @($Arguments | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    }

    switch ($Command.ToLowerInvariant()) {
        '--version' { Write-Output "jenv-windows $script:JEnvVersion"; return }
        'version'   { Write-Warning "'version' is not a command; did you mean 'current'? Use 'jenv current'."; return }

        'add' {
            $path = $null
            $aliases = [System.Collections.Generic.List[string]]::new()
            $force = $false
            for ($i = 0; $i -lt $rest.Count; $i++) {
                $a = $rest[$i]
                if ($a -eq '--force') { $force = $true }
                elseif ($a -eq '--alias' -or $a -eq '-a') {
                    $i++
                    if ($i -ge $rest.Count -or [string]::IsNullOrWhiteSpace($rest[$i])) {
                        throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv add: '$a' requires a value." -Category InvalidArgument -TargetObject $a)
                    }
                    $aliases.Add($rest[$i])
                }
                elseif ($a -like '--alias=*') { $aliases.Add($a.Substring('--alias='.Length)) }
                elseif ($a -eq '--') { }
                elseif ($a.StartsWith('-') -and $a.Length -gt 1) {
                    throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv add: unknown option '$a'." -Category InvalidArgument -TargetObject $a)
                }
                elseif ([string]::IsNullOrEmpty($path)) { $path = $a }
                else { throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv add: unexpected argument '$a'." -Category InvalidArgument -TargetObject $a) }
            }
            if ([string]::IsNullOrEmpty($path)) { throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv add: a JDK home path is required." -Category InvalidArgument) }
            $result = Register-JenvJdk -Home $path -Alias $aliases.ToArray() -Force:$force
            if ($result) { Write-JenvRegistrationSummary -Result $result }
            return
        }

        'remove' {
            $name = $null
            $force = $false
            for ($i = 0; $i -lt $rest.Count; $i++) {
                $a = $rest[$i]
                if ($a -eq '--force') { $force = $true }
                elseif ($a.StartsWith('-') -and $a.Length -gt 1 -and $a -ne '--') { throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv remove: unknown option '$a'." -Category InvalidArgument -TargetObject $a) }
                elseif ([string]::IsNullOrEmpty($name)) { $name = $a }
                else { throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv remove: unexpected argument '$a'." -Category InvalidArgument -TargetObject $a) }
            }
            if ([string]::IsNullOrEmpty($name)) { throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv remove: a version or alias is required." -Category InvalidArgument) }
            $result = Unregister-JenvJdk -Name $name -Force:$force
            if ($result) { Write-Output "Removed $($result.CanonicalId)." }
            return
        }

        'versions' {
            $bare = $false; $json = $false
            foreach ($a in $rest) {
                if ($a -eq '--bare') { $bare = $true }
                elseif ($a -eq '--json') { $json = $true }
                else { throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv versions: unknown option '$a'." -Category InvalidArgument -TargetObject $a) }
            }
            Format-JenvVersionList -Bare:$bare -Json:$json
            return
        }

        'current' {
            $json = $false
            foreach ($a in $rest) { if ($a -eq '--json') { $json = $true } else { throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv current: unknown option '$a'." -Category InvalidArgument -TargetObject $a) } }
            Get-JenvCurrent -Json:$json
            return
        }

        'global' { Invoke-JenvScopedSet -Command 'global' -Rest $rest; return }
        'local'  { Invoke-JenvScopedSet -Command 'local' -Rest $rest; return }
        'shell'  { Invoke-JenvScopedSet -Command 'shell' -Rest $rest; return }

        'home' {
            $ver = $null
            foreach ($a in $rest) {
                if ($a.StartsWith('-') -and $a.Length -gt 1) {
                    throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv home: unknown option '$a'." -Category InvalidArgument -TargetObject $a)
                } elseif ($null -eq $ver) {
                    $ver = $a
                } else {
                    throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv home: unexpected argument '$a'." -Category InvalidArgument -TargetObject $a)
                }
            }
            Get-JenvHome -Version $ver
            return
        }

        'which' {
            $cmdName = $null; $ver = $null
            for ($i = 0; $i -lt $rest.Count; $i++) {
                $a = $rest[$i]
                if ($a -eq '--version') {
                    $i++
                    if ($i -ge $rest.Count -or [string]::IsNullOrWhiteSpace($rest[$i])) {
                        throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv which: --version requires a value." -Category InvalidArgument -TargetObject '--version')
                    }
                    $ver = $rest[$i]
                }
                elseif ($a.StartsWith('-') -and $a.Length -gt 1) {
                    throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv which: unknown option '$a'." -Category InvalidArgument -TargetObject $a)
                }
                elseif ($null -eq $cmdName) { $cmdName = $a }
                else { throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv which: unexpected argument '$a'." -Category InvalidArgument -TargetObject $a) }
            }
            if ([string]::IsNullOrEmpty($cmdName)) {
                throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message 'jenv which: a command name is required.' -Category InvalidArgument)
            }
            Resolve-JenvWhich -Command $cmdName -Version $ver
            return
        }

        'refresh' {
            $quiet = $false
            foreach ($a in $rest) { if ($a -eq '--quiet') { $quiet = $true } else { throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv refresh: unknown option '$a'." -Category InvalidArgument -TargetObject $a) } }
            Invoke-JenvRefresh -Quiet:$quiet
            return
        }

        'exec' {
            # PowerShell consumes the first bare `--`, so we don't rely on seeing
            # it: an optional jenv `--version <v>` is consumed, then the first
            # remaining token (or one following an explicit `--`) is the command.
            $ver = $null
            $cmdStart = -1
            for ($i = 0; $i -lt $rest.Count; $i++) {
                if ($rest[$i] -eq '--version') {
                    $i++
                    if ($i -ge $rest.Count -or [string]::IsNullOrWhiteSpace($rest[$i])) {
                        throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message 'jenv exec: --version requires a value.' -Category InvalidArgument -TargetObject '--version')
                    }
                    $ver = $rest[$i]
                }
                elseif ($rest[$i] -eq '--') { $cmdStart = $i + 1; break }
                elseif ($rest[$i].StartsWith('-') -and $rest[$i].Length -gt 1) {
                    throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv exec: unknown option '$($rest[$i])'." -Category InvalidArgument -TargetObject $rest[$i])
                }
                else { $cmdStart = $i; break }
            }
            if ($cmdStart -lt 0 -or $cmdStart -ge $rest.Count) {
                throw (New-JenvErrorRecord -Id 'JEnv.Command.NotFound' `
                    -Message "jenv exec requires a command to run." -Category InvalidArgument)
            }
            Invoke-JenvCommand -Version $ver -ArgumentList (@($rest[$cmdStart..($rest.Count - 1)]))
            return
        }

        'root' { Write-Output (Get-JenvRoot); return }

        'init' {
            $install = $false; $uninstall = $false
            foreach ($a in $rest) {
                if ($a -eq '--install') { $install = $true }
                elseif ($a -eq '--uninstall') { $uninstall = $true }
                else { throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv init: unknown option '$a'." -Category InvalidArgument -TargetObject $a) }
            }
            if ($install -and $uninstall) {
                throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message 'jenv init: --install and --uninstall cannot be combined.' -Category InvalidArgument)
            }
            Initialize-Jenv -Install:$install -Uninstall:$uninstall
            return
        }

        'doctor' {
            $json = $false
            foreach ($a in $rest) { if ($a -eq '--json') { $json = $true } else { throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv doctor: unknown option '$a'." -Category InvalidArgument -TargetObject $a) } }
            $checks = Test-JenvInstallation
            $hasError = @($checks | Where-Object { $_.Status -eq 'ERROR' }).Count -gt 0
            if ($json) {
                $payload = foreach ($c in $checks) { [ordered]@{ name = $c.Name; status = $c.Status; message = $c.Message } }
                Write-Output (ConvertTo-JenvJson -Object $payload)
            } else {
                foreach ($c in $checks) {
                    $tag = switch ($c.Status) { 'OK' { '[OK]  ' } 'WARN' { '[WARN]' } 'ERROR' { '[ERROR]' } }
                    Write-Output ("{0} {1,-16} {2}" -f $tag, $c.Name, $c.Message)
                }
            }
            if ($hasError) {
                throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' `
                    -Message 'jenv doctor reported one or more errors (see above).' -Category OperationStopped)
            }
            return
        }

        'help' { Write-JenvHelp -Topic $(if ($rest.Count -gt 0) { $rest[0] }); return }

        default {
            throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' `
                -Message "Unknown jenv command '$Command'. Run 'jenv help' for usage." `
                -Category ObjectNotFound -TargetObject $Command)
        }
    }
}

# Parse `<version>` or `--unset` for the global/local/shell commands.
function Invoke-JenvScopedSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][object[]]$Rest
    )
    $unset = $false
    $version = $null
    foreach ($a in $Rest) {
        if ($a -eq '--unset') { $unset = $true }
        elseif ($a -eq '--') { }
        elseif ($a.StartsWith('-') -and $a.Length -gt 1) {
            throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv ${Command}: unknown option '$a'." -Category InvalidArgument -TargetObject $a)
        }
        elseif ($null -eq $version) { $version = $a }
        else { throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' -Message "jenv ${Command}: unexpected argument '$a'." -Category InvalidArgument -TargetObject $a) }
    }
    if ($unset -and $null -ne $version) {
        throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' `
            -Message "jenv ${Command}: --unset cannot be combined with a version." `
            -Category InvalidArgument -TargetObject $version)
    }
    switch ($Command) {
        'global' { Set-JenvGlobal -Version $version -Unset:$unset }
        'local'  { Set-JenvLocal -Version $version -Unset:$unset }
        'shell'  { Set-JenvShell -Version $version -Unset:$unset }
    }
}

function Write-JenvRegistrationSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Result)
    $verb = switch ($Result.Action) { 'Added' { 'Added' } 'Updated' { 'Updated' } 'Unchanged' { 'No change for' } default { $Result.Action } }
    Write-Output ("{0} {1}" -f $verb, $Result.CanonicalId)
    if ($Result.Home) { Write-Output ("  home: {0}" -f $Result.Home) }
    if ($Result.Aliases -and $Result.Aliases.Count -gt 0) {
        Write-Output ("  aliases: {0}" -f ($Result.Aliases -join ', '))
    }
}

function Write-JenvHelp {
    [CmdletBinding()]
    param([Parameter()][string]$Topic)

    if ([string]::IsNullOrEmpty($Topic)) {
        @(
            'jenv-windows - JDK version selector for PowerShell 7'
            ''
            'Usage: jenv <command> [arguments] [options]'
            ''
            'Commands:'
            '  add <jdk-home> [--alias <name>]... [--force]   Register an installed JDK'
            '  remove <version> [--force]                     Unregister a JDK'
            '  versions [--bare|--json]                       List registered JDKs'
            '  current [--json]                               Show the active version and its origin'
            '  root                                           Print the JENV root directory'
            '  help [command]                                 Show help'
            ''
            'Version selection (shell > local > global > system):'
            '  global [version|--unset]   user default'
            '  local  [version|--unset]   per-directory (.java-version)'
            '  shell  [version|--unset]   current session'
            ''
            'Other: home, which, exec, refresh, doctor, init, --version'
        ) | Write-Output
        return
    }

    switch ($Topic.ToLowerInvariant()) {
        'add' {
            @(
                'jenv add <jdk-home> [--alias <name>]... [--force]'
                ''
                'Register an already-installed JDK. jenv does not copy JDK files.'
                'A canonical id and auto-aliases (full, major.minor, major) are generated.'
                'Auto-aliases that collide are skipped with a warning; explicit --alias'
                'collisions fail unless --force is given.'
            ) | Write-Output
        }
        'remove' {
            @(
                'jenv remove <version> [--force]'
                ''
                'Remove a JDK registration (by canonical id or alias). JDK files are not deleted.'
                'Refuses if the target is the active selection, unless --force.'
            ) | Write-Output
        }
        default { Write-Warning "No help for '$Topic'. Run 'jenv help' for the command list." }
    }
}
