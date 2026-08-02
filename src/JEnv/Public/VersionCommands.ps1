Set-StrictMode -Version Latest

# Display helpers for `jenv versions` and `jenv current`.
# See docs/command-reference.md section 5-6. Environment-mutating version commands
# (global/local/shell/home/which/refresh) are added in a later phase.

# `jenv versions`: list registered JDKs, marking the active one. Supports --bare
# (canonical ids only) and --json.
function Format-JenvVersions {
    [CmdletBinding()]
    param(
        [Parameter()][switch]$Bare,
        [Parameter()][switch]$Json,
        [Parameter()][string]$Root = (Get-JenvRoot)
    )

    if ($Bare -and $Json) {
        throw (New-JenvErrorRecord -Id 'JEnv.Command.Unknown' `
            -Message '--bare and --json cannot be used together.' -Category InvalidArgument)
    }

    $all = @(Get-JenvJdk -Root $Root)

    # The active version may fail to resolve (e.g. a dangling .java-version);
    # `versions` still lists what is registered, so swallow that error here.
    $currentCanonical = $null
    $currentOrigin = $null
    try {
        $cur = Resolve-JenvVersion -Root $Root
        $currentCanonical = $cur.CanonicalId
        $currentOrigin = $cur
    } catch {
        Write-Warning "Active version could not be resolved: $($_.Exception.Message)"
    }

    if ($Bare) {
        foreach ($jdk in $all) { Write-Output $jdk.CanonicalId }
        return
    }

    if ($Json) {
        $payload = foreach ($jdk in $all) {
            $isCurrent = $currentCanonical -and [string]::Equals($currentCanonical, $jdk.CanonicalId, [System.StringComparison]::OrdinalIgnoreCase)
            [ordered]@{
                canonicalId  = $jdk.CanonicalId
                version      = $jdk.Version
                vendor       = $jdk.Vendor
                vendorId     = $jdk.VendorId
                major        = $jdk.Major
                architecture = $jdk.Architecture
                home         = $jdk.Home
                aliases      = @($jdk.Aliases)
                isCurrent    = $isCurrent
            }
        }
        Write-Output (ConvertTo-JenvJson -Object $payload)
        return
    }

    foreach ($jdk in $all) {
        $marker = ' '
        $suffix = ''
        if ($currentCanonical -and [string]::Equals($currentCanonical, $jdk.CanonicalId, [System.StringComparison]::OrdinalIgnoreCase)) {
            $marker = '*'
            if ($currentOrigin -and $currentOrigin.OriginPath) {
                $suffix = " (set by $($currentOrigin.OriginPath))"
            } elseif ($currentOrigin) {
                $suffix = " (set by $($currentOrigin.OriginKind))"
            }
        }
        $aliasText = if ($jdk.Aliases -and $jdk.Aliases.Count -gt 0) { " (aliases: $($jdk.Aliases -join ', '))" } else { '' }
        Write-Output ("{0} {1}{2}{3}" -f $marker, $jdk.CanonicalId, $aliasText, $suffix)
    }
}

# `jenv current`: show the resolved version with its origin. Fail-fast: an
# invalid/unregistered active selection errors rather than silently reporting
# a lower scope.
function Get-JenvCurrent {
    [CmdletBinding()]
    param(
        [Parameter()][switch]$Json,
        [Parameter()][string]$Root = (Get-JenvRoot)
    )

    $resolved = Resolve-JenvVersion -Root $Root

    if ($Json) {
        $payload = [ordered]@{
            requestedVersion = $resolved.RequestedVersion
            canonicalId      = $resolved.CanonicalId
            home             = $resolved.Home
            originKind       = $resolved.OriginKind
            originPath       = $resolved.OriginPath
        }
        Write-Output (ConvertTo-JenvJson -Object $payload)
        return
    }

    if ($resolved.OriginKind -eq 'System') {
        Write-Output 'system'
        return
    }
    $where = if ($resolved.OriginPath) { $resolved.OriginPath } else { $resolved.OriginKind }
    Write-Output ("{0} (set by {1})" -f $resolved.CanonicalId, $where)
}

# Resolve a version expression (or the full precedence chain) and fail fast if it
# is not registered. Returns a JEnv.ResolvedVersion. Used by the set/home/which
# commands to validate before writing.
function Resolve-JenvRequiredVersion {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][string]$Version,
        [Parameter()][string]$Root = (Get-JenvRoot)
    )
    if ([string]::IsNullOrEmpty($Version)) {
        $resolved = Resolve-JenvVersion -Root $Root
    } else {
        $reg = Read-JenvRegistry -Root $Root
        $canonical = Resolve-JenvCanonicalId -Name $Version -Registry $reg
        if ([string]::IsNullOrEmpty($canonical)) {
            throw (New-JenvErrorRecord -Id 'JEnv.Version.NotInstalled' `
                -Message "Java version '$Version' is not registered." `
                -Category ObjectNotFound -TargetObject $Version)
        }
        $rec = Get-JenvJdkRecord -CanonicalId $canonical -Registry $reg
        $resolved = [pscustomobject]@{
            PSTypeName       = 'JEnv.ResolvedVersion'
            RequestedVersion = $Version
            CanonicalId      = $canonical
            Home             = $rec.home
            OriginKind       = 'Explicit'
            OriginPath       = $null
        }
    }
    return $resolved
}

function Write-JenvVersionExpressionFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Expression,
        [Parameter()][string]$BackupPath
    )
    Write-JenvFileAtomic -Path $Path -Content "$Expression`n" -BackupPath $BackupPath
}

# `jenv global [version|--unset]`: write or remove the user default, then re-sync.
function Set-JenvGlobal {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Position = 0)][string]$Version,
        [Parameter()][switch]$Unset,
        [Parameter()][string]$Root = (Get-JenvRoot)
    )

    $file = Get-JenvGlobalVersionFile -Root $Root

    if ($Unset) {
        if (-not $PSCmdlet.ShouldProcess($file, 'Remove global version file')) { return }
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            Remove-Item -LiteralPath $file -Force
        }
        Sync-JenvEnvironment -Root $Root -Force
        return
    }

    if ([string]::IsNullOrEmpty($Version)) {
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            Write-Output (Read-JenvVersionFile -Path $file)
        } else {
            Write-Output 'system'
        }
        return
    }

    Resolve-JenvRequiredVersion -Version $Version -Root $Root | Out-Null
    if (-not $PSCmdlet.ShouldProcess($file, "Set global version to '$Version'")) { return }
    $backup = Join-Path (Get-JenvBackupsDir -Root $Root) 'version.bak'
    Write-JenvVersionExpressionFile -Path $file -Expression $Version -BackupPath $backup
    Sync-JenvEnvironment -Root $Root -Force
}

# `jenv local [version|--unset]`: write or remove ./​.java-version, then re-sync.
function Set-JenvLocal {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Position = 0)][string]$Version,
        [Parameter()][switch]$Unset,
        [Parameter()][string]$Root = (Get-JenvRoot)
    )

    if (-not (Test-JenvCurrentLocationIsFileSystem)) {
        throw (New-JenvErrorRecord -Id 'JEnv.Location.NotFileSystem' `
            -Message "jenv local requires a FileSystem directory." -Category InvalidOperation)
    }
    $file = Join-Path (Get-JenvLocationPath) '.java-version'

    if ($Unset) {
        if (-not $PSCmdlet.ShouldProcess($file, 'Remove .java-version')) { return }
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            Remove-Item -LiteralPath $file -Force
        }
        Sync-JenvEnvironment -Root $Root -Force
        return
    }

    if ([string]::IsNullOrEmpty($Version)) {
        $found = Find-JenvLocalVersionFile -Directory (Get-JenvLocationPath)
        if ($found) {
            Write-Output ("{0} (in {1})" -f (Read-JenvVersionFile -Path $found), $found)
        } else {
            Write-Output 'system'
        }
        return
    }

    Resolve-JenvRequiredVersion -Version $Version -Root $Root | Out-Null
    if (-not $PSCmdlet.ShouldProcess($file, "Set local version to '$Version'")) { return }
    Write-JenvVersionExpressionFile -Path $file -Expression $Version
    Sync-JenvEnvironment -Root $Root -Force
}

# `jenv shell [version|--unset]`: set or remove $env:JENV_VERSION, then re-sync.
function Set-JenvShell {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Position = 0)][string]$Version,
        [Parameter()][switch]$Unset,
        [Parameter()][string]$Root = (Get-JenvRoot)
    )

    if ($Unset) {
        if (-not $PSCmdlet.ShouldProcess('JENV_VERSION', 'Remove shell version')) { return }
        Remove-Item -Path Env:\JENV_VERSION -ErrorAction SilentlyContinue
        Sync-JenvEnvironment -Root $Root -Force
        return
    }

    if ([string]::IsNullOrEmpty($Version)) {
        if ([string]::IsNullOrEmpty($env:JENV_VERSION)) {
            Write-Output 'system'
        } else {
            Write-Output $env:JENV_VERSION
        }
        return
    }

    Resolve-JenvRequiredVersion -Version $Version -Root $Root | Out-Null
    if (-not $PSCmdlet.ShouldProcess('JENV_VERSION', "Set shell version to '$Version'")) { return }
    $env:JENV_VERSION = $Version
    Sync-JenvEnvironment -Root $Root -Force
}

# `jenv home [version]`: print the JDK home. Errors on system (no managed home).
function Get-JenvHome {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][string]$Version,
        [Parameter()][string]$Root = (Get-JenvRoot)
    )

    $resolved = Resolve-JenvRequiredVersion -Version $Version -Root $Root
    if ($resolved.OriginKind -eq 'System' -or [string]::IsNullOrEmpty($resolved.Home)) {
        throw (New-JenvErrorRecord -Id 'JEnv.Version.SystemHasNoHome' `
            -Message 'Using the system JDK; no managed JAVA_HOME is set.' `
            -Category InvalidOperation)
    }
    Write-Output $resolved.Home
}

# `jenv which [command]`: print the path to a command in the active (or named)
# JDK bin; for system, resolve via Get-Command. Rejects names with separators.
function Resolve-JenvWhich {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][string]$Command = 'java',
        [Parameter()][string]$Version,
        [Parameter()][string]$Root = (Get-JenvRoot)
    )

    if ([string]::IsNullOrEmpty($Command)) { $Command = 'java' }
    if ($Command -match '[\\/]|:') {
        throw (New-JenvErrorRecord -Id 'JEnv.Command.NotFound' `
            -Message "Command name must not contain a path separator or drive." `
            -Category InvalidArgument -TargetObject $Command)
    }

    $resolved = Resolve-JenvRequiredVersion -Version $Version -Root $Root
    if ($resolved.OriginKind -eq 'System' -or [string]::IsNullOrEmpty($resolved.Home)) {
        $found = Get-Command -Name $Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { Write-Output $found.Source; return }
        throw (New-JenvErrorRecord -Id 'JEnv.Command.NotFound' `
            -Message "Command '$Command' not found on PATH (system)." -Category ObjectNotFound -TargetObject $Command)
    }

    $bin = Join-Path $resolved.Home 'bin'
    foreach ($suffix in @('', '.exe', '.cmd', '.bat')) {
        $candidate = Join-Path $bin ($Command + $suffix)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { Write-Output $candidate; return }
    }
    throw (New-JenvErrorRecord -Id 'JEnv.Command.NotFound' `
        -Message "Command '$Command' not found in '$bin'." -Category ObjectNotFound -TargetObject $Command)
}

# `jenv refresh`: ignore caches and re-sync the environment to the current
# resolution.
function Invoke-JenvRefresh {
    [CmdletBinding()]
    param(
        [Parameter()][switch]$Quiet,
        [Parameter()][string]$Root = (Get-JenvRoot)
    )
    Sync-JenvEnvironment -Root $Root -Force
    if (-not $Quiet) {
        $resolved = Resolve-JenvVersion -Root $Root
        if ($resolved.OriginKind -eq 'System') {
            Write-Output 'system'
        } else {
            Write-Output ("{0} (set by {1})" -f $resolved.CanonicalId, $(if ($resolved.OriginPath) { $resolved.OriginPath } else { $resolved.OriginKind }))
        }
    }
}
