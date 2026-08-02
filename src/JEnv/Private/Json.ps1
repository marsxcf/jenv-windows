Set-StrictMode -Version Latest

# JSON helpers. PowerShell's default ConvertTo-Json truncates at a shallow
# depth, so depth is always explicit here. Registry and version files are
# stored as no-BOM UTF-8 with LF line endings (docs/storage-and-resolution.md section 4).
function ConvertFrom-JenvJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Json)

    # ConvertFrom-Json in newer PowerShell versions may coerce ISO-looking
    # strings into DateTime values. Use System.Text.Json so schema-1 values and
    # unknown forward-compatible properties retain their JSON types exactly.
    function ConvertFrom-JenvJsonElement {
        param([Parameter(Mandatory)][System.Text.Json.JsonElement]$Element)

        switch ($Element.ValueKind) {
            ([System.Text.Json.JsonValueKind]::Object) {
                $map = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
                foreach ($property in $Element.EnumerateObject()) {
                    if ($map.Contains($property.Name)) {
                        throw "Duplicate JSON property '$($property.Name)'."
                    }
                    $map.Add($property.Name, (ConvertFrom-JenvJsonElement -Element $property.Value))
                }
                return $map
            }
            ([System.Text.Json.JsonValueKind]::Array) {
                $items = [System.Collections.Generic.List[object]]::new()
                foreach ($item in $Element.EnumerateArray()) {
                    $items.Add((ConvertFrom-JenvJsonElement -Element $item))
                }
                return (, $items.ToArray())
            }
            ([System.Text.Json.JsonValueKind]::String) { return $Element.GetString() }
            ([System.Text.Json.JsonValueKind]::Number) {
                $integer = [long]0
                if ($Element.TryGetInt64([ref]$integer)) { return $integer }
                $decimal = [decimal]0
                if ($Element.TryGetDecimal([ref]$decimal)) { return $decimal }
                return $Element.GetDouble()
            }
            ([System.Text.Json.JsonValueKind]::True) { return $true }
            ([System.Text.Json.JsonValueKind]::False) { return $false }
            ([System.Text.Json.JsonValueKind]::Null) { return $null }
            default { throw "Unsupported JSON token '$($Element.ValueKind)'." }
        }
    }

    $document = [System.Text.Json.JsonDocument]::Parse($Json)
    try {
        return (ConvertFrom-JenvJsonElement -Element $document.RootElement)
    } finally {
        $document.Dispose()
    }
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
    $bytes = $utf8NoBom.GetBytes($normalized)
    $stream = [System.IO.FileStream]::new(
        $Path,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

# Read a file as text, tolerating BOM or no BOM (UTF-8).
function Read-JenvTextFile {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}
