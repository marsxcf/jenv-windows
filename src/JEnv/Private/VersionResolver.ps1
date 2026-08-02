Set-StrictMode -Version Latest

# Version expression + version file rules and the full resolution engine.
# See docs/storage-and-resolution.md section 5 (expressions), section 7 (local discovery), section 8
# (algorithm). The resolver is read-only and deterministic.

$script:JEnvVersionExpressionPattern = '^[A-Za-z0-9][A-Za-z0-9._+\-]{0,127}$'

function Test-JenvVersionExpression {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Expression)
    return ($Expression -match $script:JEnvVersionExpressionPattern)
}

# Read and validate a version file (.java-version or the global `version` file).
# One valid version expression only; no comments, multi-version, or quotes.
function Read-JenvVersionFile {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $fileInfo = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($fileInfo.Length -gt $script:JEnvVersionFileMaxBytes) {
        throw (New-JenvErrorRecord -Id 'JEnv.VersionFile.Invalid' `
            -Message "Version file '$Path' exceeds the $($script:JEnvVersionFileMaxBytes) byte limit." `
            -Category LimitsExceeded -TargetObject $Path)
    }

    $content = Read-JenvTextFile -Path $Path
    $content = $content -replace "`r`n", "`n"
    $lines = $content -split "`n"
    $nonEmpty = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($nonEmpty.Count -eq 0) {
        throw (New-JenvErrorRecord -Id 'JEnv.VersionFile.Invalid' `
            -Message "Version file '$Path' is empty." -Category InvalidData -TargetObject $Path)
    }
    if ($nonEmpty.Count -gt 1) {
        throw (New-JenvErrorRecord -Id 'JEnv.VersionFile.Invalid' `
            -Message "Version file '$Path' contains multiple lines; only one version expression is allowed." `
            -Category InvalidData -TargetObject $Path)
    }

    $expr = $nonEmpty[0].Trim()
    if (-not (Test-JenvVersionExpression -Expression $expr)) {
        throw (New-JenvErrorRecord -Id 'JEnv.VersionFile.Invalid' `
            -Message "Version file '$Path' contains an invalid version expression '$expr'." `
            -Category InvalidData -TargetObject $Path)
    }
    return $expr
}

# Walk from $Directory up to the volume root looking for `.java-version`.
# Uses logical (user-visible) paths; returns the first match or $null.
function Find-JenvLocalVersionFile {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Directory)

    if ([string]::IsNullOrEmpty($Directory)) { return $null }
    $dir = ConvertTo-JenvNormalizedPath -Path $Directory
    while (-not [string]::IsNullOrEmpty($dir)) {
        $f = Join-Path $dir '.java-version'
        if (Test-Path -LiteralPath $f -PathType Leaf) { return $f }
        $parent = Split-Path $dir -Parent
        if ([string]::IsNullOrEmpty($parent) -or
            [string]::Equals($parent, $dir, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $dir = $parent
    }
    return $null
}

# Full resolution. Returns a JEnv.ResolvedVersion with RequestedVersion,
# CanonicalId, Home, OriginKind (Shell|Local|Global|System), OriginPath.
# A set but unregistered/invalid higher-priority source errors (fail-fast) and
# never silently falls back to a lower scope.
function Resolve-JenvVersion {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][string]$Root = (Get-JenvRoot),
        [Parameter()][string]$CurrentDirectory = (Get-JenvLocationPath),
        [Parameter()][AllowEmptyString()][string]$ShellVersion = $env:JENV_VERSION,
        [Parameter()]$Registry = $null
    )

    $reg = if ($null -ne $Registry) { $Registry } else { Read-JenvRegistry -Root $Root }

    $requested = $null
    $originKind = $null
    $originPath = $null

    if (-not [string]::IsNullOrEmpty($ShellVersion)) {
        $requested = $ShellVersion.Trim()
        $originKind = 'Shell'
    } elseif ($null -ne $CurrentDirectory) {
        $localFile = Find-JenvLocalVersionFile -Directory $CurrentDirectory
        if ($localFile) {
            $requested = Read-JenvVersionFile -Path $localFile
            $originKind = 'Local'
            $originPath = $localFile
        }
    }

    if ($null -eq $requested) {
        $globalFile = Get-JenvGlobalVersionFile -Root $Root
        if (Test-Path -LiteralPath $globalFile -PathType Leaf) {
            $requested = Read-JenvVersionFile -Path $globalFile
            $originKind = 'Global'
            $originPath = $globalFile
        }
    }

    if ($null -eq $requested -or [string]::Equals($requested, 'system', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
            PSTypeName       = 'JEnv.ResolvedVersion'
            RequestedVersion = 'system'
            CanonicalId      = $null
            Home             = $null
            OriginKind       = 'System'
            OriginPath       = $null
        }
    }

    $canonical = Resolve-JenvCanonicalId -Name $requested -Registry $reg
    if ([string]::IsNullOrEmpty($canonical)) {
        $where = if ($originPath) { "$originKind ($originPath)" } else { "$originKind" }
        throw (New-JenvErrorRecord -Id 'JEnv.Version.NotInstalled' `
            -Message "Java version '$requested' is not registered (set by $where)." `
            -Category ObjectNotFound -TargetObject $requested)
    }

    $rec = Get-JenvJdkRecord -CanonicalId $canonical -Registry $reg
    if ($null -eq $rec) {
        throw (New-JenvErrorRecord -Id 'JEnv.Version.NotInstalled' `
            -Message "Java version '$requested' resolved to canonical '$canonical' which has no record." `
            -Category ObjectNotFound -TargetObject $requested)
    }

    $javaExe = Join-Path $rec.home 'bin\java.exe'
    $javacExe = Join-Path $rec.home 'bin\javac.exe'
    if (-not (Test-Path -LiteralPath $javaExe -PathType Leaf) -or
        -not (Test-Path -LiteralPath $javacExe -PathType Leaf)) {
        throw (New-JenvErrorRecord -Id 'JEnv.Jdk.InvalidHome' `
            -Message "Registered JDK '$canonical' at '$($rec.home)' no longer contains bin\java.exe and bin\javac.exe. Reinstall it or run 'jenv remove $canonical --force'." `
            -Category ObjectNotFound -TargetObject $rec.home)
    }

    return [pscustomobject]@{
        PSTypeName       = 'JEnv.ResolvedVersion'
        RequestedVersion = $requested
        CanonicalId      = $canonical
        Home             = $rec.home
        OriginKind       = $originKind
        OriginPath       = $originPath
    }
}
