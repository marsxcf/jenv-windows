Set-StrictMode -Version Latest

# JSON helpers. PowerShell's default ConvertTo-Json truncates at a shallow
# depth, so depth is always explicit here. Registry and version files are
# stored as no-BOM UTF-8 with LF line endings (docs/storage-and-resolution.md section 4).
function ConvertFrom-JenvJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Json)
    return ($Json | ConvertFrom-Json -AsHashtable)
}

function ConvertTo-JenvJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter()][int]$Depth = 20
    )
    return ($Object | ConvertTo-Json -Depth $Depth)
}

# Write text as no-BOM UTF-8 with LF line endings.
function Write-JenvTextUtf8NoBom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $normalized = $Content -replace "`r`n", "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $normalized, $utf8NoBom)
}

# Read a file as text, tolerating BOM or no BOM (UTF-8).
function Read-JenvTextFile {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}
