Set-StrictMode -Version Latest

# PowerShell Profile integration: idempotent install/uninstall of the jenv
# bootstrap block. See docs/powershell-integration.md section 7.

$script:JEnvProfileBegin = '# >>> jenv-windows initialize >>>'
$script:JEnvProfileEnd = '# <<< jenv-windows initialize <<<'

function Get-JenvProfilePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) {
        return $PROFILE.CurrentUserAllHosts
    }
    return $Path
}

function Get-JenvProfileBootstrapBlock {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][string]$Newline = "`n")
    $nl = $Newline
    return ($script:JEnvProfileBegin + $nl +
            'Import-Module JEnv' + $nl +
            'Initialize-Jenv' + $nl +
            $script:JEnvProfileEnd)
}

# Detect Authenticode signature on an existing profile.
function Test-JenvProfileSigned {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        return ($sig.Status -ne 'NotSigned')
    } catch { return $false }
}

# Returns: 'Absent' | 'Present' | 'Partial' | 'Duplicate'
function Test-JenvProfileBlockState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][string]$Content)

    $begins = ([regex]::Matches($Content, [regex]::Escape($script:JEnvProfileBegin))).Count
    $ends = ([regex]::Matches($Content, [regex]::Escape($script:JEnvProfileEnd))).Count
    if ($begins -eq 0 -and $ends -eq 0) { return 'Absent' }
    if ($begins -eq 1 -and $ends -eq 1) {
        if ([regex]::IsMatch($Content, [regex]::Escape($script:JEnvProfileBegin) + '[\s\S]*?' + [regex]::Escape($script:JEnvProfileEnd))) {
            return 'Present'
        }
    }
    if ($begins -gt 1 -or $ends -gt 1) { return 'Duplicate' }
    return 'Partial'
}

# Append the managed block to the profile idempotently. Preserves the existing
# file's BOM and line-ending style; new files are no-BOM UTF-8 LF. Refuses a
# signed profile and malformed/partial markers. Creates a backup.
function Add-JenvProfileBootstrap {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param([Parameter()][string]$Path)

    $path = Get-JenvProfilePath -Path $Path
    $exists = Test-Path -LiteralPath $path -PathType Leaf

    if ($exists) {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        $newline = if ($content -match "`r`n") { "`r`n" } else { "`n" }
    } else {
        $hasBom = $false
        $content = ''
        $newline = "`n"
    }

    $state = Test-JenvProfileBlockState -Content $content
    if ($state -eq 'Present') {
        return [pscustomobject]@{ PSTypeName = 'JEnv.ProfileResult'; Action = 'Unchanged'; Path = $path }
    }
    if ($state -eq 'Partial' -or $state -eq 'Duplicate') {
        throw (New-JenvErrorRecord -Id 'JEnv.Profile.UpdateFailed' `
            -Message "Profile '$path' has a malformed jenv-windows block ($state). Fix or remove it manually." `
            -Category InvalidOperation -TargetObject $path)
    }
    if ($exists -and (Test-JenvProfileSigned -Path $path)) {
        throw (New-JenvErrorRecord -Id 'JEnv.Profile.UpdateFailed' `
            -Message "Profile '$path' is Authenticode-signed; jenv will not modify it. Add the block manually and re-sign." `
            -Category SecurityError -TargetObject $path)
    }

    if (-not $PSCmdlet.ShouldProcess($path, 'Install jenv-windows bootstrap block')) {
        return $null
    }

    $block = Get-JenvProfileBootstrapBlock -Newline $newline
    if ($content.Length -eq 0) {
        $newContent = $block + $newline
    } else {
        # Keep one visual blank line between user content and the managed block.
        $separator = if ($content.EndsWith($newline)) { $newline } else { $newline + $newline }
        $newContent = $content + $separator + $block + $newline
    }

    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $temp = Join-Path $dir ([System.IO.Path]::GetRandomFileName())
    $enc = [System.Text.UTF8Encoding]::new($hasBom)
    [System.IO.File]::WriteAllText($temp, $newContent, $enc)

    $backup = $path + '.bak'
    try {
        if ($exists) {
            [System.IO.File]::Replace($temp, $path, $backup, $true)
        } else {
            [System.IO.File]::Move($temp, $path)
        }
    } catch {
        if (Test-Path -LiteralPath $temp -ErrorAction SilentlyContinue) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        throw (New-JenvErrorRecord -Id 'JEnv.Profile.UpdateFailed' `
            -Message "Failed to write profile '$path': $($_.Exception.Message)" `
            -Category WriteError -TargetObject $path)
    }
    return [pscustomobject]@{ PSTypeName = 'JEnv.ProfileResult'; Action = 'Installed'; Path = $path }
}

# Remove the managed block from the profile (idempotent; preserves the rest).
function Remove-JenvProfileBootstrap {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param([Parameter()][string]$Path)

    $path = Get-JenvProfilePath -Path $Path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ PSTypeName = 'JEnv.ProfileResult'; Action = 'Unchanged'; Path = $path }
    }

    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    $newline = if ($content -match "`r`n") { "`r`n" } else { "`n" }
    $state = Test-JenvProfileBlockState -Content $content
    if ($state -eq 'Absent') {
        return [pscustomobject]@{ PSTypeName = 'JEnv.ProfileResult'; Action = 'Unchanged'; Path = $path }
    }
    if ($state -ne 'Present') {
        throw (New-JenvErrorRecord -Id 'JEnv.Profile.UpdateFailed' `
            -Message "Profile '$path' has a malformed jenv-windows block ($state); refusing fuzzy removal." `
            -Category InvalidOperation -TargetObject $path)
    }
    if (Test-JenvProfileSigned -Path $path) {
        throw (New-JenvErrorRecord -Id 'JEnv.Profile.UpdateFailed' `
            -Message "Profile '$path' is Authenticode-signed; jenv will not modify it." `
            -Category SecurityError -TargetObject $path)
    }

    if (-not $PSCmdlet.ShouldProcess($path, 'Remove jenv-windows bootstrap block')) { return $null }

    $beginIndex = $content.IndexOf($script:JEnvProfileBegin, [System.StringComparison]::Ordinal)
    $endIndex = $content.IndexOf($script:JEnvProfileEnd, $beginIndex, [System.StringComparison]::Ordinal)
    $afterIndex = $endIndex + $script:JEnvProfileEnd.Length

    # Remove the block, its trailing newline, and at most the one blank line
    # inserted immediately before it. Never normalize unrelated whitespace.
    if ($content.Substring($afterIndex).StartsWith($newline)) {
        $afterIndex += $newline.Length
    }
    $before = $content.Substring(0, $beginIndex)
    $doubleNewline = $newline + $newline
    if ($before.EndsWith($doubleNewline)) {
        $before = $before.Substring(0, $before.Length - $newline.Length)
    }
    $newContent = $before + $content.Substring($afterIndex)

    $dir = Split-Path $path -Parent
    $temp = Join-Path $dir ([System.IO.Path]::GetRandomFileName())
    $enc = [System.Text.UTF8Encoding]::new($hasBom)
    [System.IO.File]::WriteAllText($temp, $newContent, $enc)
    $backup = $path + '.bak'
    try {
        [System.IO.File]::Replace($temp, $path, $backup, $true)
    } catch {
        if (Test-Path -LiteralPath $temp -ErrorAction SilentlyContinue) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        throw (New-JenvErrorRecord -Id 'JEnv.Profile.UpdateFailed' `
            -Message "Failed to write profile '$path': $($_.Exception.Message)" `
            -Category WriteError -TargetObject $path)
    }
    return [pscustomobject]@{ PSTypeName = 'JEnv.ProfileResult'; Action = 'Removed'; Path = $path }
}
