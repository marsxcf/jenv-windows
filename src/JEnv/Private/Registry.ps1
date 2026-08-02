Set-StrictMode -Version Latest

# JDK registry: schema, read/validate, concurrency, atomic write.
# See docs/storage-and-resolution.md section 4 (schema) and section 9 (concurrency/atomicity).

# Reasonable size caps (docs/testing.md section 7).
$script:JEnvRegistryMaxBytes = 10 * 1024 * 1024  # 10 MiB
$script:JEnvVersionFileMaxBytes = 4 * 1024        # 4 KiB

function New-JenvRegistrySkeleton {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure in-memory object factory; it does not modify persistent state.')]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    return ([ordered]@{
        schemaVersion = 1
        revision      = 0
        jdks          = [ordered]@{}
        aliases       = [ordered]@{}
    })
}

function Test-JenvIntegerValue {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Value)

    return ($Value -is [byte] -or $Value -is [sbyte] -or
            $Value -is [int16] -or $Value -is [uint16] -or
            $Value -is [int32] -or $Value -is [uint32] -or
            $Value -is [int64] -or $Value -is [uint64])
}

# Validate a parsed registry object in place. Throws JEnv.Registry.Invalid on any
# structural problem. Never silently treats a corrupt file as empty (docs section 9.3).
function Test-JenvRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Registry)

    if ($null -eq $Registry) {
        throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
            -Message 'Registry is empty or null.' -Category InvalidData)
    }
    if (-not $Registry.Contains('schemaVersion') -or
        -not (Test-JenvIntegerValue -Value $Registry.schemaVersion) -or
        [long]$Registry.schemaVersion -ne 1) {
        throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
            -Message "Unsupported registry schemaVersion '$($Registry.schemaVersion)'. Only schemaVersion 1 is supported." `
            -Category InvalidData -TargetObject $Registry.schemaVersion)
    }

    if (-not $Registry.Contains('revision') -or
        -not (Test-JenvIntegerValue -Value $Registry.revision) -or
        [long]$Registry.revision -lt 0 -or [long]$Registry.revision -gt [int]::MaxValue) {
        throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
            -Message "Registry revision must be a non-negative integer." `
            -Category InvalidData -TargetObject $Registry.revision)
    }

    $jdks = $Registry.jdks
    if ($null -eq $jdks -or $jdks -isnot [System.Collections.IDictionary]) {
        throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
            -Message "Registry is missing the 'jdks' object." -Category InvalidData)
    }

    $aliases = $Registry.aliases
    if ($null -eq $aliases -or $aliases -isnot [System.Collections.IDictionary]) {
        throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
            -Message "Registry is missing the 'aliases' object." -Category InvalidData)
    }

    # Required per-JDK fields.
    $required = @('home', 'version', 'normalizedVersion', 'major', 'vendor', 'vendorId', 'architecture', 'registeredAt', 'updatedAt')
    $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($jdks.Keys)) {
        if ($id -isnot [string] -or -not (Test-JenvVersionExpression -Expression $id) -or
            [string]::Equals($id, 'system', [System.StringComparison]::OrdinalIgnoreCase) -or
            -not $seenIds.Add($id)) {
            throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
                -Message "Registry contains an invalid or duplicate canonical id '$id'." `
                -Category InvalidData -TargetObject $id)
        }
        $rec = $jdks[$id]
        if ($null -eq $rec -or $rec -isnot [System.Collections.IDictionary]) {
            throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
                -Message "Registry JDK '$id' has no record." -Category InvalidData -TargetObject $id)
        }
        foreach ($field in $required) {
            if (-not $rec.Contains($field) -or $null -eq $rec[$field]) {
                throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
                    -Message "Registry JDK '$id' is missing required field '$field'." -Category InvalidData -TargetObject $id)
            }
        }
        if ($rec.home -isnot [string] -or -not (Test-JenvHomePathSafe -HomePath $rec.home) -or
            -not [System.IO.Path]::IsPathRooted($rec.home) -or
            -not [string]::Equals($rec.home, (ConvertTo-JenvNormalizedPath -Path $rec.home), [System.StringComparison]::Ordinal)) {
            throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
                -Message "Registry JDK '$id' must have a normalized, absolute, safe home path." `
                -Category InvalidData -TargetObject $rec.home)
        }
        foreach ($field in @('version', 'normalizedVersion', 'vendor', 'vendorId', 'architecture')) {
            if ($rec[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace($rec[$field])) {
                throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
                    -Message "Registry JDK '$id' field '$field' must be a non-empty string." `
                    -Category InvalidData -TargetObject $id)
            }
        }
        if (-not (Test-JenvIntegerValue -Value $rec.major) -or [long]$rec.major -le 0) {
            throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
                -Message "Registry JDK '$id' major must be a positive integer." `
                -Category InvalidData -TargetObject $id)
        }
        if ($rec.architecture -notin @('x86', 'x64', 'arm64', 'unknown')) {
            throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
                -Message "Registry JDK '$id' has invalid architecture '$($rec.architecture)'." `
                -Category InvalidData -TargetObject $id)
        }
        foreach ($dateField in @('registeredAt', 'updatedAt')) {
            $parsedDate = [DateTimeOffset]::MinValue
            if ($rec[$dateField] -is [DateTimeOffset]) {
                $parsedDate = [DateTimeOffset]$rec[$dateField]
            } elseif ($rec[$dateField] -is [DateTime]) {
                $parsedDate = [DateTimeOffset]([DateTime]$rec[$dateField])
            } elseif ($rec[$dateField] -isnot [string] -or
                [string]::IsNullOrWhiteSpace($rec[$dateField]) -or
                -not [DateTimeOffset]::TryParse(
                    [string]$rec[$dateField],
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind,
                    [ref]$parsedDate)) {
                throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
                    -Message "Registry JDK '$id' field '$dateField' is not an ISO 8601 timestamp." `
                    -Category InvalidData -TargetObject $id)
            }
            $rec[$dateField] = $parsedDate.ToUniversalTime().ToString('o')
        }
    }

    # Aliases must point at existing canonical IDs (no dangling references).
    $seenAliases = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($alias in @($aliases.Keys)) {
        if ($alias -isnot [string] -or -not (Test-JenvVersionExpression -Expression $alias) -or
            [string]::Equals($alias, 'system', [System.StringComparison]::OrdinalIgnoreCase) -or
            -not $seenAliases.Add($alias)) {
            throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
                -Message "Registry contains an invalid or duplicate alias '$alias'." `
                -Category InvalidData -TargetObject $alias)
        }
        $target = $aliases[$alias]
        if ($target -isnot [string] -or [string]::IsNullOrEmpty((Resolve-JenvCanonicalId -Name $target -Registry ([ordered]@{ jdks = $jdks; aliases = [ordered]@{} })))) {
            throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
                -Message "Alias '$alias' points to unknown JDK '$target'." -Category InvalidData -TargetObject $alias)
        }
    }
}

# Read and validate the registry. A missing file returns an empty skeleton.
function Read-JenvRegistry {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter()][string]$Root = (Get-JenvRoot))

    $path = Get-JenvRegistryPath -Root $Root
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return (New-JenvRegistrySkeleton)
    }

    $fileInfo = Get-Item -LiteralPath $path
    if ($fileInfo.Length -gt $script:JEnvRegistryMaxBytes) {
        throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
            -Message "versions.json is $($fileInfo.Length) bytes, exceeding the $($script:JEnvRegistryMaxBytes) byte limit." `
            -Category InvalidData -TargetObject $path)
    }

    try {
        $json = Read-JenvTextFile -Path $path
        $obj = ConvertFrom-JenvJson -Json $json
    } catch {
        throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
            -Message "versions.json could not be parsed: $($_.Exception.Message)" `
            -Category InvalidData -TargetObject $path)
    }

    Test-JenvRegistry -Registry $obj
    return $obj
}

# Resolve a version expression (canonical id or alias) to its canonical id.
# Returns the canonical id (with stored casing) or $null if not found.
function Resolve-JenvCanonicalId {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)]$Registry
    )
    if ([string]::IsNullOrEmpty($Name)) { return $null }

    $jdks = $Registry.jdks
    if ($jdks) {
        foreach ($k in $jdks.Keys) {
            if ([string]::Equals($k, $Name, [System.StringComparison]::OrdinalIgnoreCase)) { return $k }
        }
    }
    $aliases = $Registry.aliases
    if ($aliases) {
        foreach ($k in $aliases.Keys) {
            if ([string]::Equals($k, $Name, [System.StringComparison]::OrdinalIgnoreCase)) { return $aliases[$k] }
        }
    }
    return $null
}

# Look up a JDK record by canonical id. Returns the record hashtable or $null.
function Get-JenvJdkRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CanonicalId,
        [Parameter(Mandatory)]$Registry
    )
    $jdks = $Registry.jdks
    if (-not $jdks) { return $null }
    foreach ($k in $jdks.Keys) {
        if ([string]::Equals($k, $CanonicalId, [System.StringComparison]::OrdinalIgnoreCase)) { return $jdks[$k] }
    }
    return $null
}

# ----- Concurrency -----

function Get-JenvRegistryMutexName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Root)
    $normalized = ConvertTo-JenvNormalizedPath -Path $Root
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    $hex = [System.Text.StringBuilder]::new(64)
    foreach ($b in $hash) { [void]$hex.Append($b.ToString('x2')) }
    return "Local\JEnv-$($hex.ToString().Substring(0, 32))"
}

function Invoke-WithJenvRegistryLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory)][string]$Root,
        [Parameter()][int]$TimeoutSeconds = 5
    )
    $name = Get-JenvRegistryMutexName -Root $Root
    $mutex = [System.Threading.Mutex]::new($false, $name)
    $owned = $false
    try {
        try {
            $owned = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds), $false)
        } catch [System.Threading.AbandonedMutexException] {
            # A previous holder crashed; we still acquired ownership.
            $owned = $true
        }
        if (-not $owned) {
            throw (New-JenvErrorRecord -Id 'JEnv.Registry.LockTimeout' `
                -Message "Timed out waiting for registry lock after $TimeoutSeconds s." `
                -Category ResourceUnavailable -TargetObject $Root)
        }
        return (& $ScriptBlock)
    } finally {
        if ($owned) {
            try { $mutex.ReleaseMutex() } catch { Write-Verbose "Unable to release the jenv registry mutex cleanly: $_" }
        }
        $mutex.Dispose()
    }
}

# ----- Atomic file write -----

# Atomically write text to $Path using a same-directory temp file then
# File.Replace (preserving the previous content in $BackupPath when given) or
# File.Move when the target does not yet exist. Always cleans up the temp file.
function Write-JenvFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter()][AllowEmptyString()][string]$BackupPath
    )

    $dir = Split-Path $Path -Parent
    if ([string]::IsNullOrEmpty($dir)) { $dir = (Get-Location).ProviderPath }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $temp = Join-Path $dir ([System.IO.Path]::GetRandomFileName())
    Write-JenvTextUtf8NoBom -Path $temp -Content $Content

    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            if (-not [string]::IsNullOrEmpty($BackupPath)) {
                $bdir = Split-Path $BackupPath -Parent
                if (-not (Test-Path -LiteralPath $bdir -PathType Container)) {
                    New-Item -ItemType Directory -Path $bdir -Force | Out-Null
                }
                [System.IO.File]::Replace($temp, $Path, $BackupPath, $true)
            } else {
                [System.IO.File]::Replace($temp, $Path, $null, $true)
            }
        } else {
            [System.IO.File]::Move($temp, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $temp -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

# Serialize and atomically write the registry, bumping revision.
function Write-JenvRegistryAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)][string]$Root
    )
    Test-JenvRegistry -Registry $Registry
    if ($null -eq $Registry.revision -or ($Registry.revision -isnot [int] -and $Registry.revision -isnot [long])) {
        $Registry.revision = 0
    }
    $Registry.revision = [int]$Registry.revision + 1
    $json = ConvertTo-JenvJson -Object $Registry
    $backup = Join-Path (Get-JenvBackupsDir -Root $Root) 'versions.json.bak'
    Write-JenvFileAtomic -Path (Get-JenvRegistryPath -Root $Root) -Content $json -BackupPath $backup
}

# Acquire the registry lock, re-read, hand the in-memory registry to a mutation
# scriptblock (param($reg)), validate, bump revision, and atomically write.
# Returns whatever the mutation scriptblock returns.
function Update-JenvRegistry {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private transaction boundary; public callers implement ShouldProcess before invoking it.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Mutation', Justification = 'Used inside the registry-lock script block through PowerShell dynamic scope.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'DoNotBumpRevision', Justification = 'Used inside the registry-lock script block through PowerShell dynamic scope.')]
    param(
        [Parameter(Mandatory)][scriptblock]$Mutation,
        [Parameter()][string]$Root = (Get-JenvRoot),
        [Parameter()][switch]$DoNotBumpRevision
    )
    return (Invoke-WithJenvRegistryLock -Root $Root -ScriptBlock {
        $reg = Read-JenvRegistry -Root $Root
        $result = & $Mutation $reg
        $registryChanged = $true
        $publicResult = $result
        if ($null -ne $result -and $result.PSObject.Properties['RegistryChanged']) {
            $registryChanged = [bool]$result.RegistryChanged
            $publicResult = $result.Result
        }
        if (-not $registryChanged) { return $publicResult }
        Test-JenvRegistry -Registry $reg
        if (-not $DoNotBumpRevision) {
            if ($null -eq $reg.revision -or ($reg.revision -isnot [int] -and $reg.revision -isnot [long])) {
                $reg.revision = 0
            }
            $reg.revision = [int]$reg.revision + 1
        }
        $json = ConvertTo-JenvJson -Object $reg
        $backup = Join-Path (Get-JenvBackupsDir -Root $Root) 'versions.json.bak'
        Write-JenvFileAtomic -Path (Get-JenvRegistryPath -Root $Root) -Content $json -BackupPath $backup
        return $publicResult
    })
}
