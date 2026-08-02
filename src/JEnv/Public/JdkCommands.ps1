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
    $sorted = [System.Collections.Generic.List[string]]::new()
    foreach ($aliasName in $aliases) { $sorted.Add($aliasName) }
    $sorted.Sort([System.StringComparer]::OrdinalIgnoreCase)
    return $sorted.ToArray()
}

function New-JenvJdkObject {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure view-model factory; it does not modify state.')]
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
        [Parameter(Mandatory, Position = 0)][Alias('Home')][string]$JdkHome,
        [Parameter()][string[]]$Alias,
        [Parameter()][switch]$Force,
        [Parameter()][string]$Root = (Get-JenvRoot)
    )

    $metadata = Get-JenvProbedJdk -JdkHome $JdkHome
    $canonical = $metadata.CanonicalId
    $allowForce = [bool]$Force
    $unresolvedBeforeAdd = $false
    try {
        Resolve-JenvVersion -Root $Root | Out-Null
    } catch {
        if ($_.FullyQualifiedErrorId -eq 'JEnv.Version.NotInstalled') {
            $unresolvedBeforeAdd = $true
        } elseif ($_.FullyQualifiedErrorId -eq 'JEnv.Registry.Invalid') {
            throw
        }
    }
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

    $updateResult = Update-JenvRegistry -Root $Root -Mutation {
        param($reg)

        $warnings = [System.Collections.Generic.List[string]]::new()
        $existing = Get-JenvJdkRecord -CanonicalId $canonical -Registry $reg
        $existingHomeId = $null
        foreach ($candidateId in @($reg.jdks.Keys)) {
            if (Test-JenvPathsEqual -ReferencePath $reg.jdks[$candidateId].home -DifferencePath $metadata.Home) {
                $existingHomeId = $candidateId
                break
            }
        }
        $action = 'Added'
        $changed = $false

        if ($existing) {
            if (Test-JenvPathsEqual -ReferencePath $existing.home -DifferencePath $metadata.Home) {
                $metadataChanged =
                    -not [string]::Equals($existing.version, $metadata.Version, [System.StringComparison]::Ordinal) -or
                    -not [string]::Equals($existing.normalizedVersion, $metadata.NormalizedVersion, [System.StringComparison]::Ordinal) -or
                    [int]$existing.major -ne [int]$metadata.Major -or
                    -not [string]::Equals($existing.vendor, $metadata.Vendor, [System.StringComparison]::Ordinal) -or
                    -not [string]::Equals($existing.vendorId, $metadata.VendorId, [System.StringComparison]::Ordinal) -or
                    -not [string]::Equals($existing.architecture, $metadata.Architecture, [System.StringComparison]::Ordinal)
                if ($metadataChanged) {
                    $existing.updatedAt = $now
                    $existing.version = $metadata.Version
                    $existing.normalizedVersion = $metadata.NormalizedVersion
                    $existing.major = $metadata.Major
                    $existing.vendor = $metadata.Vendor
                    $existing.vendorId = $metadata.VendorId
                    $existing.architecture = $metadata.Architecture
                    $reg.jdks[$canonical] = $existing
                    $changed = $true
                    $action = 'Updated'
                } else {
                    $action = 'Unchanged'
                }
            } else {
                if (-not $allowForce) {
                    throw (New-JenvErrorRecord -Id 'JEnv.Alias.Conflict' `
                        -Message "Canonical id '$canonical' is already registered to a different home ('$($existing.home)'). Use --force to replace that registration." `
                        -Category ResourceExists -TargetObject $canonical)
                }
                $existing.home = $metadata.Home
                $existing.version = $metadata.Version
                $existing.normalizedVersion = $metadata.NormalizedVersion
                $existing.major = $metadata.Major
                $existing.vendor = $metadata.Vendor
                $existing.vendorId = $metadata.VendorId
                $existing.architecture = $metadata.Architecture
                $existing.updatedAt = $now
                $reg.jdks[$canonical] = $existing
                $changed = $true
                $action = 'Updated'
            }
        } elseif ($existingHomeId) {
            # The same installation reported new metadata and therefore a new
            # canonical id. Preserve its registration time and aliases.
            $oldRecord = $reg.jdks[$existingHomeId]
            $reg.jdks.Remove($existingHomeId) | Out-Null
            $reg.jdks[$canonical] = [ordered]@{
                home              = $metadata.Home
                version           = $metadata.Version
                normalizedVersion = $metadata.NormalizedVersion
                major             = $metadata.Major
                vendor            = $metadata.Vendor
                vendorId          = $metadata.VendorId
                architecture      = $metadata.Architecture
                registeredAt      = $oldRecord.registeredAt
                updatedAt         = $now
            }
            foreach ($aliasName in @($reg.aliases.Keys)) {
                if ([string]::Equals($reg.aliases[$aliasName], $existingHomeId, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $reg.aliases[$aliasName] = $canonical
                }
            }
            $changed = $true
            $action = 'Updated'
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
            $changed = $true
        }

        foreach ($a in $metadata.Aliases) {
            if ([string]::Equals($a, $canonical, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $owner = Resolve-JenvCanonicalId -Name $a -Registry $reg
            if ([string]::IsNullOrEmpty($owner)) {
                $reg.aliases[$a] = $canonical
                $changed = $true
                if ($action -eq 'Unchanged') { $action = 'Updated' }
            } elseif (-not [string]::Equals($owner, $canonical, [System.StringComparison]::OrdinalIgnoreCase)) {
                $warnings.Add("Auto-alias '$a' is already used by '$owner'; skipped.")
            }
        }

        foreach ($ea in $explicitAliases) {
            $owner = Resolve-JenvCanonicalId -Name $ea -Registry $reg
            if ([string]::IsNullOrEmpty($owner)) {
                $reg.aliases[$ea] = $canonical
                $changed = $true
                if ($action -eq 'Unchanged') { $action = 'Updated' }
            } elseif ([string]::Equals($owner, $canonical, [System.StringComparison]::OrdinalIgnoreCase)) {
                # already points here; nothing to do
            } else {
                if ($allowForce) {
                    $reg.aliases[$ea] = $canonical
                    $changed = $true
                    if ($action -eq 'Unchanged') { $action = 'Updated' }
                } else {
                    throw (New-JenvErrorRecord -Id 'JEnv.Alias.Conflict' `
                        -Message "Explicit alias '$ea' is already used by '$owner'. Use --force to rebind it." `
                        -Category ResourceExists -TargetObject $ea)
                }
            }
        }

        foreach ($w in $warnings) { Write-Warning $w }

        $registrationResult = [pscustomobject]@{
            PSTypeName  = 'JEnv.RegistrationResult'
            Action      = $action
            CanonicalId = $canonical
            Home        = $metadata.Home
            Aliases     = (Get-JenvAliasesFor -CanonicalId $canonical -Registry $reg)
            Warnings    = $warnings.ToArray()
        }
        return [pscustomobject]@{
            RegistryChanged = $changed
            Result          = $registrationResult
        }
    }

    if ($unresolvedBeforeAdd) {
        $resolvedAfterAdd = Resolve-JenvVersion -Root $Root
        if ($resolvedAfterAdd.CanonicalId -and
            [string]::Equals($resolvedAfterAdd.CanonicalId, $canonical, [System.StringComparison]::OrdinalIgnoreCase)) {
            Sync-JenvEnvironment -Root $Root -Force
        }
    }
    return $updateResult
}

function Get-JenvReferencesToCanonicalId {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$CanonicalId,
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)][string]$Root
    )

    $references = [System.Collections.Generic.List[string]]::new()
    $sources = [System.Collections.Generic.List[object]]::new()
    if (-not [string]::IsNullOrEmpty($env:JENV_VERSION)) {
        $sources.Add([pscustomobject]@{ Name = 'shell'; Expression = $env:JENV_VERSION })
    }
    $location = Get-JenvLocationPath
    if ($location) {
        $localFile = Find-JenvLocalVersionFile -Directory $location
        if ($localFile) {
            $sources.Add([pscustomobject]@{ Name = $localFile; Expression = (Read-JenvVersionFile -Path $localFile) })
        }
    }
    $globalFile = Get-JenvGlobalVersionFile -Root $Root
    if (Test-Path -LiteralPath $globalFile -PathType Leaf) {
        $sources.Add([pscustomobject]@{ Name = $globalFile; Expression = (Read-JenvVersionFile -Path $globalFile) })
    }

    foreach ($source in $sources) {
        if ([string]::Equals($source.Expression, 'system', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $target = Resolve-JenvCanonicalId -Name $source.Expression -Registry $Registry
        if ($target -and [string]::Equals($target, $CanonicalId, [System.StringComparison]::OrdinalIgnoreCase)) {
            $references.Add($source.Name)
        }
    }
    return $references.ToArray()
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

    $references = @(Get-JenvReferencesToCanonicalId -CanonicalId $canonical -Registry $reg -Root $Root)
    if (-not $Force -and $references.Count -gt 0) {
        throw (New-JenvErrorRecord -Id 'JEnv.Version.InUse' `
            -Message "Cannot remove '$canonical'; it is referenced by $($references -join ', '). Use --force to remove anyway." `
            -Category ResourceExists -TargetObject $canonical)
    }

    if (-not $PSCmdlet.ShouldProcess($canonical, 'Remove JDK registration')) {
        return $null
    }

    # Avoid PowerShell dynamic-scope collision with the registry mutex helper's
    # local `$name` variable.
    $versionToRemove = $Name
    $result = Update-JenvRegistry -Root $Root -Mutation {
        param($r)
        $lockedCanonical = Resolve-JenvCanonicalId -Name $versionToRemove -Registry $r
        if ([string]::IsNullOrEmpty($lockedCanonical)) {
            throw (New-JenvErrorRecord -Id 'JEnv.Version.NotInstalled' `
                -Message "Java version '$versionToRemove' is no longer registered." `
                -Category ObjectNotFound -TargetObject $versionToRemove)
        }
        if ($r.jdks.Contains($lockedCanonical)) { $r.jdks.Remove($lockedCanonical) | Out-Null }
        if ($r.aliases) {
            foreach ($k in @($r.aliases.Keys)) {
                if ([string]::Equals($r.aliases[$k], $lockedCanonical, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $r.aliases.Remove($k) | Out-Null
                }
            }
        }
        return [pscustomobject]@{
            PSTypeName  = 'JEnv.RegistrationResult'
            Action      = 'Removed'
            CanonicalId = $lockedCanonical
            Home        = $null
            Aliases     = @()
            Warnings    = @()
        }
    }

    if ($Force -and $references.Count -gt 0) {
        Write-Warning "Removed '$canonical', leaving dangling version reference(s): $($references -join ', ')."
    }
    Sync-JenvEnvironment -Root $Root -Force
    return $result
}

function Get-JenvVersionSortKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Version)

    $segments = [regex]::Matches($Version, '\d+') | ForEach-Object {
        $digits = $_.Value.TrimStart('0')
        if ([string]::IsNullOrEmpty($digits)) { $digits = '0' }
        '{0:D3}:{1}' -f $digits.Length, $digits
    }
    return ($segments -join '.')
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

    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $reg.jdks.Keys) {
        $list.Add((New-JenvJdkObject -CanonicalId $id -Record $reg.jdks[$id] -Registry $reg))
    }
    $comparer = [System.Collections.Generic.Comparer[object]]::Create(
        [System.Comparison[object]]{
            param($left, $right)
            $majorComparison = [int]$left.Major - [int]$right.Major
            if ($majorComparison -ne 0) { return $majorComparison }
            $versionComparison = [string]::Compare(
                (Get-JenvVersionSortKey -Version $left.NormalizedVersion),
                (Get-JenvVersionSortKey -Version $right.NormalizedVersion),
                [System.StringComparison]::Ordinal)
            if ($versionComparison -ne 0) { return $versionComparison }
            return [string]::Compare($left.CanonicalId, $right.CanonicalId, [System.StringComparison]::OrdinalIgnoreCase)
        })
    $list.Sort($comparer)
    return $list.ToArray()
}
