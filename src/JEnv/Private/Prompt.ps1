Set-StrictMode -Version Latest

# The prompt hook for automatic directory switching. Assigned to global:prompt;
# it recomputes the environment only when a resolution fingerprint changes and
# otherwise delegates to the original prompt. See docs/powershell-integration.md section 6.

# A cheap digest of the inputs to version resolution. If it is unchanged since
# the last sync, the prompt hook skips re-syncing (the cached path, <10 ms).
function Get-JenvResolutionFingerprint {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][string]$Root = (Get-JenvRoot))

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('v='); [void]$sb.Append($env:JENV_VERSION); [void]$sb.Append('|')
    [void]$sb.Append('d='); [void]$sb.Append((Get-JenvLocationPath)); [void]$sb.Append('|')

    if (Test-JenvCurrentLocationIsFileSystem) {
        $local = Find-JenvLocalVersionFile -Directory (Get-JenvLocationPath)
        if ($local) {
            $fi = Get-Item -LiteralPath $local
            [void]$sb.Append('l='); [void]$sb.Append($local); [void]$sb.Append(':')
            [void]$sb.Append($fi.Length); [void]$sb.Append(':'); [void]$sb.Append($fi.LastWriteTimeUtc.Ticks)
        }
    }
    [void]$sb.Append('|')
    $reg = Get-JenvRegistryPath -Root $Root
    if (Test-Path -LiteralPath $reg -PathType Leaf) {
        $fi = Get-Item -LiteralPath $reg
        [void]$sb.Append('r='); [void]$sb.Append($fi.LastWriteTimeUtc.Ticks)
    }
    return $sb.ToString()
}

function Test-JenvIsInteractiveHost {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        if ($null -eq $Host.UI) { return $false }
        if ([System.Console]::IsOutputRedirected) { return $false }
        return $true
    } catch { return $false }
}

# The hook body. Assigned to global:prompt. Never writes to the success stream
# (would corrupt the prompt); errors are swallowed to Write-Debug.
function __JenvPrompt {
    try {
        $state = Get-JenvSessionState
        if ($state.Initialized) {
            $fp = Get-JenvResolutionFingerprint
            if (-not [string]::Equals($fp, $state.LastFingerprint, [System.StringComparison]::Ordinal)) {
                try { Sync-JenvEnvironment -Force } catch { Write-Debug "jenv sync failed: $_" }
                $state.LastFingerprint = $fp
            }
        }
    } catch { Write-Debug "jenv prompt hook error: $_" }

    $st = Get-JenvSessionState
    if ($st.PreviousPrompt) {
        & $st.PreviousPrompt
    } else {
        "PS $($executionContext.SessionState.Path.CurrentLocation.Path)$('>' * ($nestedPromptLevel + 1)) "
    }
}

function Enable-JenvPromptHook {
    [CmdletBinding()]
    param()
    $state = Get-JenvSessionState
    if ($state.PromptInstalled) { return }

    # Read the current prompt via Get-Command (visible from module scope, unlike
    # Get-Item Function:\global:prompt which may resolve to the module's view).
    $cur = Get-Command -Name prompt -CommandType Function -ErrorAction SilentlyContinue
    if ($cur -and ($cur.Definition -notmatch 'JenvResolutionFingerprint|__JenvPrompt')) {
        $state.PreviousPrompt = $cur.ScriptBlock
    }
    $state.PromptHook = ${function:__JenvPrompt}
    Set-Item -Path 'Function:\global:prompt' -Value $state.PromptHook
    $state.PromptInstalled = $true
}

function Disable-JenvPromptHook {
    [CmdletBinding()]
    param()
    $state = Get-JenvSessionState
    if (-not $state.PromptInstalled) { return }

    # Only restore if the current prompt is still our hook (do not clobber a
    # prompt another tool installed after us).
    $cur = Get-Command -Name prompt -CommandType Function -ErrorAction SilentlyContinue
    if ($cur -and $cur.Definition -match '__JenvPrompt') {
        if ($state.PreviousPrompt) {
            Set-Item -Path 'Function:\global:prompt' -Value $state.PreviousPrompt
        }
    }
    $state.PromptInstalled = $false
    $state.PromptHook = $null
    $state.PreviousPrompt = $null
}
