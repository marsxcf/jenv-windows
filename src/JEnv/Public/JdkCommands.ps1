Set-StrictMode -Version Latest

# JDK registration commands: Register-JenvJdk (jenv add), Unregister-JenvJdk
# (jenv remove), Get-JenvJdk (jenv versions / inspection).
# See docs/command-reference.md section 3-5.

function Get-JenvAliasesFor {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$CanonicalId,
        [Parameter(Mandatory)]$Registry
    )
    $aliases = @()
    if ($Registry.aliases) {
        foreach ($k in $Registry.aliases.Keys) {
            if ([string]::Equals($Registry.aliases[$k], $CanonicalId, [System.StringComparison]::OrdinalIgnoreCase)) {
                $aliases += $k
            }
        }
    }
    return $aliases
}

function New-JenvJdkObject {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$CanonicalId,
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)]$Registry
    )
    return [pscustomobject]@{
        PSTypeName        = 'JEnv.Jdk'
        CanonicalId       = $CanonicalId
        Home              = $Record.home
        Version           = $Record.version
        NormalizedVersion = $Record.normalizedVersion
        Major             = $Record.major
        Vendor            = $Record.vendor
        VendorId          = $Record.vendorId
        Architecture      = $Record.architecture
        RegisteredAt      = $Record.registeredAt
        UpdatedAt         = $Record.updatedAt
        Aliases           = (Get-JenvAliasesFor -CanonicalId $CanonicalId -Registry $Registry)
    }
}

# Register an already-installed JDK. Probes metadata, generates canonical id and
# auto aliases, optionally adds explicit aliases, and writes the registry
# atomically under the registry mutex. Returns a JEnv.RegistrationResult.
function Register-JenvJdk {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Home,
        [Parameter()][string[]]$Alias,
        [Parameter()][switch]$Force,
        [Parameter()][string]$Root = (Get-JenvRoot)
    )

    $metadata = Probe-JenvJdk -Home $Home
    $canonical = $metadata.CanonicalId
    $explicitAliases = @($Alias | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() })

    # Validate explicit aliases up front (before acquiring the lock).
    foreach ($ea in $explicitAliases) {
        if ([string]::Equals($ea, 'system', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw (New-JenvErrorRecord -Id 'JEnv.Alias.Conflict' `
                -Message "'system' is reserved and cannot be used as an alias." `
                -Category InvalidArgument -TargetObject $ea)
        }
        if (-not (Test-JenvVersionExpression -Expression $ea)) {
            throw (New-JenvErrorRecord -Id 'JEnv.Alias.Conflict' `
                -Message "Explicit alias '$ea' is not a valid version expression." `
                -Category InvalidArgument -TargetObject $ea)
        }
    }

    if (-not $PSCmdlet.ShouldProcess($canonical, "Register JDK from '$($metadata.Home)'")) {
        return $null
    }

    $now = (Get-Date).ToUniversalTime().ToString('o')

    return (Update-JenvRegistry -Root $Root -Mutation {
        param($reg)

        $warnings = [System.Collections.Generic.List[string]]::new()
        $existing = Get-JenvJdkRecord -CanonicalId $canonical -Registry $reg
        $action = 'Added'

        if ($existing) {
            if (Test-JenvPathsEqual -ReferencePath $existing.home -DifferencePath $metadata.Home) {
                $existing.updatedAt = $now
                $existing.version = $metadata.Version
                $existing.normalizedVersion = $metadata.NormalizedVersion
                $existing.major = $metadata.Major
                $existing.vendor = $metadata.Vendor
                $existing.vendorId = $metadata.VendorId
                $existing.architecture = $metadata.Architecture
                $reg.jdks[$canonical] = $existing
                $action = 'Updated'
            } else {
                throw (New-JenvErrorRecord -Id 'JEnv.Alias.Conflict' `
                    -Message "Canonical id '$canonical' is already registered to a different home ('$($existing.home)'). Run 'jenv remove $canonical' first." `
                    -Category ResourceExists -TargetObject $canonical)
            }
        } else {
            $record = [ordered]@{
                home              = $metadata.Home
                version           = $metadata.Version
                normalizedVersion = $metadata.NormalizedVersion
                major             = $metadata.Major
                vendor            = $metadata.Vendor
                vendorId          = $metadata.VendorId
                architecture      = $metadata.Architecture
                registeredAt      = $now
                updatedAt         = $now
            }
            $reg.jdks[$canonical] = $record

            foreach ($a in $metadata.Aliases) {
                if ([string]::Equals($a, $canonical, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                $owner = Resolve-JenvCanonicalId -Name $a -Registry $reg
                if ([string]::IsNullOrEmpty($owner)) {
                    $reg.aliases[$a] = $canonical
                } elseif (-not [string]::Equals($owner, $canonical, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $warnings.Add("Auto-alias '$a' is already used by '$owner'; skipped.")
                }
            }
        }

        foreach ($ea in $explicitAliases) {
            $owner = Resolve-JenvCanonicalId -Name $ea -Registry $reg
            if ([string]::IsNullOrEmpty($owner)) {
                $reg.aliases[$ea] = $canonical
            } elseif ([string]::Equals($owner, $canonical, [System.StringComparison]::OrdinalIgnoreCase)) {
                # already points here; nothing to do
            } else {
                if ($Force) {
                    $reg.aliases[$ea] = $canonical
                } else {
                    throw (New-JenvErrorRecord -Id 'JEnv.Alias.Conflict' `
                        -Message "Explicit alias '$ea' is already used by '$owner'. Use --force to rebind it." `
                        -Category ResourceExists -TargetObject $ea)
                }
            }
        }

        foreach ($w in $warnings) { Write-Warning $w }

        return [pscustomobject]@{
            PSTypeName  = 'JEnv.RegistrationResult'
            Action      = $action
            CanonicalId = $canonical
            Home        = $metadata.Home
            Aliases     = (Get-JenvAliasesFor -CanonicalId $canonical -Registry $reg)
            Warnings    = $warnings.ToArray()
        }
    })
}

# Remove a JDK by canonical id or alias. Refuses when the target is the active
# shell/local/global selection unless -Force is given. Never deletes JDK files.
function Unregister-JenvJdk {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter()][switch]$Force,
        [Parameter()][string]$Root = (Get-JenvRoot)
    )

    $reg = Read-JenvRegistry -Root $Root
    $canonical = Resolve-JenvCanonicalId -Name $Name -Registry $reg
    if ([string]::IsNullOrEmpty($canonical)) {
        throw (New-JenvErrorRecord -Id 'JEnv.Version.NotInstalled' `
            -Message "Java version '$Name' is not registered." `
            -Category ObjectNotFound -TargetObject $Name)
    }

    if (-not $Force) {
        $active = Resolve-JenvVersion -Root $Root -Registry $reg
        if ($active.CanonicalId -and [string]::Equals($active.CanonicalId, $canonical, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw (New-JenvErrorRecord -Id 'JEnv.Version.NotInstalled' `
                -Message "Cannot remove '$canonical'; it is the active version (set by $($active.OriginKind)). Use --force to remove anyway." `
                -Category ResourceExists -TargetObject $canonical)
        }
    }

    if (-not $PSCmdlet.ShouldProcess($canonical, 'Remove JDK registration')) {
        return $null
    }

    return (Update-JenvRegistry -Root $Root -Mutation {
        param($r)
        if ($r.jdks.Contains($canonical)) { $r.jdks.Remove($canonical) | Out-Null }
        if ($r.aliases) {
            foreach ($k in @($r.aliases.Keys)) {
                if ([string]::Equals($r.aliases[$k], $canonical, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $r.aliases.Remove($k) | Out-Null
                }
            }
        }
        return [pscustomobject]@{
            PSTypeName  = 'JEnv.RegistrationResult'
            Action      = 'Removed'
            CanonicalId = $canonical
            Home        = $null
            Aliases     = @()
            Warnings    = @()
        }
    })
}

# Return registered JDKs as JEnv.Jdk objects. With -Name, returns a single JDK
# (or $null). Without, returns all, sorted for stable display.
function Get-JenvJdk {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)][string]$Name,
        [Parameter()][string]$Root = (Get-JenvRoot)
    )

    $reg = Read-JenvRegistry -Root $Root

    if ($PSBoundParameters.ContainsKey('Name') -and -not [string]::IsNullOrEmpty($Name)) {
        $canonical = Resolve-JenvCanonicalId -Name $Name -Registry $reg
        if ([string]::IsNullOrEmpty($canonical)) { return $null }
        return (New-JenvJdkObject -CanonicalId $canonical -Record $reg.jdks[$canonical] -Registry $reg)
    }

    $list = foreach ($id in $reg.jdks.Keys) {
        New-JenvJdkObject -CanonicalId $id -Record $reg.jdks[$id] -Registry $reg
    }
    return ($list | Sort-Object `
        @{Expression = { [int]$_.Major }}, `
        @{Expression = { $_.NormalizedVersion }}, `
        @{Expression = { $_.CanonicalId }})
}
