Set-StrictMode -Version Latest

# Path utilities and JENV_ROOT resolution.
# See docs/storage-and-resolution.md section 1 and docs/powershell-integration.md section 5.1.

# Resolve the JENV root directory. Precedence: $env:JENV_ROOT (trimmed) if set,
# otherwise Join-Path $HOME '.jenv'. Relative and CR/LF-bearing values are
# rejected. The result is an absolute filesystem path with a non-root trailing
# separator removed; on-disk casing is preserved.
function Get-JenvRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $candidate = $null
    if (-not [string]::IsNullOrEmpty($env:JENV_ROOT)) {
        $candidate = $env:JENV_ROOT.Trim()
    }
    if ([string]::IsNullOrEmpty($candidate)) {
        $candidate = Join-Path $HOME '.jenv'
    }

    if ($candidate -match '[\r\n]') {
        throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
            -Message "JENV_ROOT must not contain CR or LF characters." `
            -Category InvalidArgument -TargetObject $candidate)
    }
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        throw (New-JenvErrorRecord -Id 'JEnv.Registry.Invalid' `
            -Message "JENV_ROOT must be an absolute path (got '$candidate')." `
            -Category InvalidArgument -TargetObject $candidate)
    }

    return (ConvertTo-JenvNormalizedPath -Path $candidate)
}

function Get-JenvRegistryPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][string]$Root = (Get-JenvRoot))
    return (Join-Path $Root 'versions.json')
}

function Get-JenvGlobalVersionFile {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][string]$Root = (Get-JenvRoot))
    return (Join-Path $Root 'version')
}

function Get-JenvBackupsDir {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][string]$Root = (Get-JenvRoot))
    return (Join-Path $Root 'backups')
}

function Get-JenvTempDir {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][string]$Root = (Get-JenvRoot))
    return (Join-Path $Root 'tmp')
}

# Normalize a path into a stable comparison key: fully-qualified via
# [IO.Path]::GetFullPath (does not require the target to exist), with a
# non-root trailing separator removed. Empty stays empty. Comparison of two
# keys is done case-insensitively by the caller (Windows FS is case-insensitive).
# GetFullPath (not Resolve-Path) is used deliberately so stale managed-bin paths
# whose target JDK was moved/deleted can still be matched and removed.
function ConvertTo-JenvNormalizedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowEmptyString()][string]$Path,
        [Parameter()][string]$BaseDirectory = $PWD.ProviderPath
    )

    if ([string]::IsNullOrEmpty($Path)) { return [string]::Empty }

    try {
        $full = [System.IO.Path]::GetFullPath($Path, $BaseDirectory)
    } catch {
        # Fall back to single-arg form if the two-arg overload rejects the input.
        $full = [System.IO.Path]::GetFullPath($Path)
    }

    $root = [System.IO.Path]::GetPathRoot($full)
    if (-not [string]::Equals($full, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $full = $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    }
    return $full
}

# Case-insensitive, normalization-aware path equality.
function Test-JenvPathsEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowEmptyString()][string]$ReferencePath,
        [Parameter()][AllowEmptyString()][string]$DifferencePath,
        [Parameter()][string]$BaseDirectory = $PWD.ProviderPath
    )
    $a = ConvertTo-JenvNormalizedPath -Path $ReferencePath -BaseDirectory $BaseDirectory
    $b = ConvertTo-JenvNormalizedPath -Path $DifferencePath -BaseDirectory $BaseDirectory
    return [string]::Equals($a, $b, [System.StringComparison]::OrdinalIgnoreCase)
}

# True only when the current PowerShell location is in the FileSystem provider.
# Local (.java-version) discovery is skipped otherwise.
function Test-JenvCurrentLocationIsFileSystem {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return ((Get-Location).Provider.Name -ieq 'FileSystem')
}

# The current filesystem directory as the user sees it (logical path), used for
# .java-version parent-walking. Returns $null if not on the FileSystem provider.
function Get-JenvLocationPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not (Test-JenvCurrentLocationIsFileSystem)) { return $null }
    return (Get-Location).ProviderPath
}

# Reject JDK home values that cannot safely appear as a single PATH entry.
function Test-JenvHomePathSafe {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$HomePath)
    if ([string]::IsNullOrEmpty($HomePath)) { return $false }
    if ($HomePath -match '[;\r\n]') { return $false }
    return $true
}

# Resolve a JDK home argument to an absolute, normalized path (relative paths
# resolve against the current directory). Does not validate existence here.
function Resolve-JenvHomePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$HomePath)
    return (ConvertTo-JenvNormalizedPath -Path $HomePath -BaseDirectory $PWD.ProviderPath)
}
