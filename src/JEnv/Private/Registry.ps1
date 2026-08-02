Set-StrictMode -Version Latest

# JDK registry: schema, read/validate, concurrency, atomic write.
# See docs/storage-and-resolution.md section 4 (schema) and section 9 (concurrency/atomicity).

# Reasonable size caps (docs/testing.md section 7).
$script:JEnvRegistryMaxBytes = 10 * 1024 * 1024  # 10 MiB
$script:JEnvVersionFileMaxBytes = 4 * 1024        # 4 KiB

function New-JenvRegistrySkeleton {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    return ([ordered]@{
        schemaVersion = 1
        revision      = 0
        jdks          = [ordered]@{}
        aliases       = [ordered]@{}
    })
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
    if ($Registry.schemaVersion -ine '1' -and ($Registry.schemaVersion -isnot [int] -or $Registry.schemaVersion -ne 1)) {
        throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
            -Message "Unsupported registry schemaVersion '$($Registry.schemaVersion)'. Only schemaVersion 1 is supported." `
            -Category InvalidData -TargetObject $Registry.schemaVersion)
    }

    $jdks = $Registry.jdks
    if ($null -eq $jdks) {
        throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
            -Message "Registry is missing the 'jdks' object." -Category InvalidData)
    }

    # Required per-JDK fields.
    $required = @('home', 'version', 'normalizedVersion', 'major', 'vendor', 'vendorId', 'architecture', 'registeredAt', 'updatedAt')
    foreach ($id in @($jdks.Keys)) {
        $rec = $jdks[$id]
        if ($null -eq $rec) {
            throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
                -Message "Registry JDK '$id' has no record." -Category InvalidData -TargetObject $id)
        }
        foreach ($field in $required) {
            if (-not $rec.Contains($field) -or $null -eq $rec[$field]) {
                throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
                    -Message "Registry JDK '$id' is missing required field '$field'." -Category InvalidData -TargetObject $id)
            }
        }
        if (-not (Test-JenvHomePathSafe -HomePath $rec.home)) {
            throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
                -Message "Registry JDK '$id' has an unsafe home path (must not contain ';', CR or LF)." `
                -Category InvalidData -TargetObject $rec.home)
        }
    }

    # Aliases must point at existing canonical IDs (no dangling references).
    $aliases = $Registry.aliases
    if ($null -ne $aliases) {
        foreach ($alias in @($aliases.Keys)) {
            $target = $aliases[$alias]
            if (-not $jdks.Contains($target)) {
                throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
                    -Message "Alias '$alias' points to unknown JDK '$target'." -Category InvalidData -TargetObject $alias)
            }
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
            try { $mutex.ReleaseMutex() } catch { }
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
    param(
        [Parameter(Mandatory)][scriptblock]$Mutation,
        [Parameter()][string]$Root = (Get-JenvRoot),
        [Parameter()][switch]$DoNotBumpRevision
    )
    return (Invoke-WithJenvRegistryLock -Root $Root -ScriptBlock {
        $reg = Read-JenvRegistry -Root $Root
        $result = & $Mutation $reg
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
        return $result
    })
}
