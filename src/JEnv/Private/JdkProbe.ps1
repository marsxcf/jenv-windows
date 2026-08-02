Set-StrictMode -Version Latest

# JDK metadata detection. Pure parsing functions are separated from I/O so unit
# tests can feed captured text without a real JDK (docs/development.md section 7).
# See docs/storage-and-resolution.md section 6.

# Parse a `release` file body (KEY="VALUE" lines). Strips surrounding quotes and
# decodes basic release-file escapes. Non KEY=VALUE lines are ignored. Never
# executes the content.
function Read-JenvReleaseFile {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    $props = [ordered]@{}
    foreach ($rawLine in ($Content -split "`n")) {
        $line = $rawLine.TrimEnd("`r")
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('#')) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -le 0) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        if ($val.Length -ge 2 -and $val.StartsWith('"') -and $val.EndsWith('"')) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        # basic escapes (release files rarely use these in the fields we read)
        $val = $val -replace '\\n', "`n" -replace '\\t', "`t" -replace '\\"', '"' -replace '\\\\', '\'
        if ($key) { $props[$key] = $val }
    }
    return $props
}

# Parse `java -XshowSettings:properties -version` style output ("    key = value").
function ConvertFrom-JenvPropertyOutput {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $props = [ordered]@{}
    foreach ($rawLine in ($Text -split "`n")) {
        $line = $rawLine.TrimEnd("`r")
        if ($line -notmatch '^\s*([A-Za-z][\w.\-]*)\s*=\s*(.*)$') { continue }
        $props[$Matches[1]] = $Matches[2].Trim().Trim('"')
    }
    return $props
}

# Run <home>\bin\java.exe -XshowSettings:properties -version using an argument
# array (no string concatenation) and temp-file redirection to avoid pipe
# deadlock. Kills the process tree on timeout.
function Invoke-JenvJavaProbe {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$JavaExe,
        [Parameter()][int]$TimeoutSeconds = 10
    )

    if (-not (Test-Path -LiteralPath $JavaExe -PathType Leaf)) {
        throw (New-JenvErrorRecord -Id 'JEnv.Jdk.ProbeFailed' `
            -Message "java.exe not found at '$JavaExe'." -Category ObjectNotFound -TargetObject $JavaExe)
    }

    $tmpDir = [System.IO.Path]::GetTempPath()
    $outFile = Join-Path $tmpDir ([System.IO.Path]::GetRandomFileName())
    $errFile = Join-Path $tmpDir ([System.IO.Path]::GetRandomFileName())

    try {
        $p = Start-Process -FilePath $JavaExe `
            -ArgumentList @('-XshowSettings:properties', '-version') `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $p.Kill($true)
            } catch {
                try { $p.Kill() } catch { Write-Verbose "Unable to kill timed-out java.exe process: $_" }
            }
            throw (New-JenvErrorRecord -Id 'JEnv.Jdk.ProbeFailed' `
                -Message "java.exe did not exit within $TimeoutSeconds s; process tree killed." `
                -Category Timeout -TargetObject $JavaExe)
        }

        $stdout = if (Test-Path -LiteralPath $outFile) { Read-JenvTextFile -Path $outFile } else { '' }
        $stderr = if (Test-Path -LiteralPath $errFile) { Read-JenvTextFile -Path $errFile } else { '' }
        return (ConvertFrom-JenvPropertyOutput -Text ($stdout + "`n" + $stderr))
    } catch {
        if ($_.FullyQualifiedErrorId -eq 'JEnv.Jdk.ProbeFailed') { throw }
        throw (New-JenvErrorRecord -Id 'JEnv.Jdk.ProbeFailed' `
            -Message "Failed to probe java.exe: $($_.Exception.Message)" `
            -Category OperationStopped -TargetObject $JavaExe)
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-JenvArchitecture {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][string]$OsArch)
    switch -Wildcard ($OsArch) {
        'amd64'      { return 'x64' }
        'x86_64'     { return 'x64' }
        'aarch64'    { return 'arm64' }
        'arm64'      { return 'arm64' }
        'x86'        { return 'x86' }
        'i386'       { return 'x86' }
        'i486'       { return 'x86' }
        'i586'       { return 'x86' }
        'i686'       { return 'x86' }
        default      { return 'unknown' }
    }
}

function ConvertTo-JenvVendorId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][string]$Vendor)
    if ($Vendor -match 'Amazon Corretto|Amazon\.com') { return 'corretto' }
    if ($Vendor -match 'Eclipse Adoptium|Temurin|AdoptOpenJDK') { return 'temurin' }
    if ($Vendor -match 'Azul|Zulu') { return 'zulu' }
    if ($Vendor -match 'BellSoft|Liberica') { return 'liberica' }
    if ($Vendor -match 'Microsoft') { return 'microsoft' }
    if ($Vendor -match 'SAP|SapMachine') { return 'sapmachine' }
    if ($Vendor -match 'GraalVM|Graal VM') { return 'graalvm' }
    if ($Vendor -match 'Oracle') { return 'oracle' }
    if ($Vendor -match 'OpenJDK') { return 'openjdk' }
    return 'other'
}

# Pure: merge release + java-probe property maps into a normalized metadata
# object. Per docs section 7, version is taken from the running Java process when
# available; vendor/architecture prefer the release file unless unrecognized.
function ConvertTo-JenvJdkMetadata {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Metadata is the conventional singular mass noun for this value object.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]$Release = $null,
        [Parameter()]$Probe = $null,
        [Parameter()][Alias('Home')][string]$JdkHome = ''
    )

    $rel = if ($Release) { $Release } else { [ordered]@{} }
    $prb = if ($Probe) { $Probe } else { [ordered]@{} }

    $rawVersion = $prb['java.version']
    if ([string]::IsNullOrEmpty($rawVersion)) { $rawVersion = $rel['JAVA_VERSION'] }
    if ([string]::IsNullOrEmpty($rawVersion)) {
        throw (New-JenvErrorRecord -Id 'JEnv.Jdk.ProbeFailed' `
            -Message "Could not determine the Java version for '$JdkHome'." -Category InvalidResult -TargetObject $JdkHome)
    }

    # Strip build metadata ("+7") for the normalized form, then unify "_" with ".".
    $base = ($rawVersion -split '\+')[0]
    $normalized = $base -replace '_', '.'

    $parts = $normalized -split '\.'
    if ($normalized -match '^1\.(\d+)\.') {
        $major = [int]$Matches[1]
    } else {
        $first = $parts[0]
        if ($first -notmatch '^\d+$') {
            throw (New-JenvErrorRecord -Id 'JEnv.Jdk.ProbeFailed' `
                -Message "Could not parse a positive major version from '$rawVersion'." `
                -Category InvalidResult -TargetObject $rawVersion)
        }
        $major = [int]$first
    }
    if ($major -le 0) {
        throw (New-JenvErrorRecord -Id 'JEnv.Jdk.ProbeFailed' `
            -Message "Java major version must be positive (got '$rawVersion')." `
            -Category InvalidResult -TargetObject $rawVersion)
    }

    $vendor = $rel['IMPLEMENTOR']
    if ([string]::IsNullOrEmpty($vendor)) { $vendor = $prb['java.vendor'] }
    if ([string]::IsNullOrEmpty($vendor)) { $vendor = $prb['java.vm.vendor'] }
    if ([string]::IsNullOrEmpty($vendor)) { $vendor = 'Unknown' }

    $vendorId = ConvertTo-JenvVendorId -Vendor $vendor

    $osArch = $rel['OS_ARCH']
    if ([string]::IsNullOrEmpty($osArch)) { $osArch = $prb['os.arch'] }
    $architecture = ConvertTo-JenvArchitecture -OsArch $osArch

    return [pscustomobject]@{
        Home              = $JdkHome
        Version           = $rawVersion
        NormalizedVersion = $normalized
        Major             = $major
        Vendor            = $vendor
        VendorId          = $vendorId
        Architecture      = $architecture
    }
}

function Get-JenvCanonicalId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Metadata)
    $bits = switch ($Metadata.Architecture) {
        'x64'   { '64' }
        'x86'   { '32' }
        'arm64' { 'arm64' }
        default { '' }
    }
    if ([string]::IsNullOrEmpty($bits)) {
        return "$($Metadata.VendorId)-$($Metadata.NormalizedVersion)"
    }
    return "$($Metadata.VendorId)$bits-$($Metadata.NormalizedVersion)"
}

# Candidate auto-aliases: canonical, full normalized, major.minor, major.
# Order is significant; deduped preserving order.
function Get-JenvCandidateAliases {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function intentionally returns a collection of aliases.')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]$Metadata,
        [Parameter(Mandatory)][string]$CanonicalId
    )

    $list = [System.Collections.Generic.List[string]]::new()
    [void]$list.Add($CanonicalId)
    [void]$list.Add($Metadata.NormalizedVersion)

    $parts = $Metadata.NormalizedVersion -split '\.'
    if ($parts.Count -ge 2) {
        [void]$list.Add(($parts[0..1] -join '.'))
    }
    [void]$list.Add([string]$Metadata.Major)

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $list) {
        if ($seen.Add($a)) { [void]$result.Add($a) }
    }
    return $result.ToArray()
}

# Top-level probe: validate the JDK home, read release, fall back to java, and
# return a metadata object plus canonical id and candidate aliases.
function Get-JenvProbedJdk {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][Alias('Home')][string]$JdkHome)

    $homeAbs = Resolve-JenvHomePath -HomePath $JdkHome
    if (-not (Test-JenvHomePathSafe -HomePath $homeAbs)) {
        throw (New-JenvErrorRecord -Id 'JEnv.Jdk.InvalidHome' `
            -Message "JDK home must not be empty and must not contain ';', CR or LF (got '$JdkHome')." `
            -Category InvalidArgument -TargetObject $JdkHome)
    }

    $javaExe = Join-Path $homeAbs 'bin\java.exe'
    $javacExe = Join-Path $homeAbs 'bin\javac.exe'
    if (-not (Test-Path -LiteralPath $javaExe -PathType Leaf) -or -not (Test-Path -LiteralPath $javacExe -PathType Leaf)) {
        throw (New-JenvErrorRecord -Id 'JEnv.Jdk.InvalidHome' `
            -Message "JDK home '$homeAbs' must contain bin\java.exe and bin\javac.exe." `
            -Category InvalidArgument -TargetObject $homeAbs)
    }

    $releasePath = Join-Path $homeAbs 'release'
    $release = $null
    if (Test-Path -LiteralPath $releasePath -PathType Leaf) {
        $release = Read-JenvReleaseFile -Content (Read-JenvTextFile -Path $releasePath)
    }

    $probe = $null
    $needsProbe = $true
    if ($release) {
        $hasVersion = -not [string]::IsNullOrEmpty($release['JAVA_VERSION'])
        $hasVendor = -not [string]::IsNullOrEmpty($release['IMPLEMENTOR'])
        $hasArch = -not [string]::IsNullOrEmpty($release['OS_ARCH'])
        if ($hasVersion -and $hasVendor -and $hasArch) { $needsProbe = $false }
    }
    if ($needsProbe) { $probe = Invoke-JenvJavaProbe -JavaExe $javaExe }

    $metadata = ConvertTo-JenvJdkMetadata -Release $release -Probe $probe -JdkHome $homeAbs
    $canonical = Get-JenvCanonicalId -Metadata $metadata
    $aliases = Get-JenvCandidateAliases -Metadata $metadata -CanonicalId $canonical

    return [pscustomobject]@{
        PSTypeName     = 'JEnv.Jdk'
        Home           = $metadata.Home
        Version        = $metadata.Version
        NormalizedVersion = $metadata.NormalizedVersion
        Major          = $metadata.Major
        Vendor         = $metadata.Vendor
        VendorId       = $metadata.VendorId
        Architecture   = $metadata.Architecture
        CanonicalId    = $canonical
        Aliases        = $aliases
    }
}
