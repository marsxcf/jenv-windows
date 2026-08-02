Set-StrictMode -Version Latest

# `jenv doctor`: diagnose the installation and current environment. Read-only.
# See docs/command-reference.md section 14. Returns JEnv.DiagnosticResult objects; the
# facade renders them and fails the command if any check is ERROR.
function Test-JenvInstallation {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter()][string]$Root = (Get-JenvRoot))

    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    function Add-Check([string]$Name, [string]$Status, [string]$Message) {
        $results.Add([pscustomobject]@{ PSTypeName = 'JEnv.DiagnosticResult'; Name = $Name; Status = $Status; Message = $Message })
    }

    # Platform
    if (-not $IsWindows) {
        Add-Check 'Platform' 'ERROR' 'jenv-windows requires Windows.'
    } elseif ($PSEdition -ne 'Core') {
        Add-Check 'Platform' 'ERROR' 'jenv-windows requires PowerShell 7 (PSEdition Core).'
    } elseif ($PSVersionTable.PSVersion -lt [version]'7.4.0') {
        Add-Check 'Platform' 'ERROR' "PowerShell $($PSVersionTable.PSVersion) is older than 7.4."
    } else {
        Add-Check 'Platform' 'OK' "Windows, PowerShell $($PSVersionTable.PSVersion), $($PSEdition)."
    }

    # Root
    $resolvedRoot = $null
    try {
        $resolvedRoot = Get-JenvRoot
        if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
            Add-Check 'Root' 'WARN' "JENV_ROOT '$resolvedRoot' does not exist yet (created on first write)."
        } else {
            $testFile = Join-Path $resolvedRoot ([System.IO.Path]::GetRandomFileName())
            try {
                Set-Content -LiteralPath $testFile -Value 'x' -NoNewline -ErrorAction Stop
                Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
                Add-Check 'Root' 'OK' "JENV_ROOT = $resolvedRoot"
            } catch {
                Add-Check 'Root' 'ERROR' "JENV_ROOT '$resolvedRoot' is not writable."
                return $results.ToArray()
            }
        }
    } catch {
        Add-Check 'Root' 'ERROR' $_.Exception.Message
        return $results.ToArray()
    }

    # Registry
    $reg = $null
    try {
        $reg = Read-JenvRegistry -Root $resolvedRoot
        Add-Check 'Registry' 'OK' "versions.json valid; $(@($reg.jdks.Keys).Count) JDK(s) registered."
    } catch {
        Add-Check 'Registry' 'ERROR' "versions.json is invalid: $($_.Exception.Message)"
        return $results.ToArray()
    }

    # Registered JDKs (java.exe + javac.exe present)
    $dead = 0
    foreach ($id in @($reg.jdks.Keys)) {
        $rec = $reg.jdks[$id]
        $javaExe = Join-Path $rec.home 'bin\java.exe'
        $javacExe = Join-Path $rec.home 'bin\javac.exe'
        if (-not (Test-Path -LiteralPath $javaExe -PathType Leaf) -or -not (Test-Path -LiteralPath $javacExe -PathType Leaf)) {
            $dead++
            Add-Check "Jdk:$id" 'WARN' "Missing bin\java.exe or bin\javac.exe at '$($rec.home)'. Run 'jenv remove $id'."
        }
    }
    if ($dead -eq 0 -and @($reg.jdks.Keys).Count -gt 0) { Add-Check 'RegisteredJdks' 'OK' 'All registered JDK homes are intact.' }
    elseif (@($reg.jdks.Keys).Count -eq 0) { Add-Check 'RegisteredJdks' 'WARN' 'No JDKs registered. Run `jenv add <jdk-home>`.' }

    # Resolution
    $resolved = $null
    try {
        $resolved = Resolve-JenvVersion -Root $resolvedRoot -Registry $reg
        if ($resolved.OriginKind -eq 'System') {
            Add-Check 'Resolution' 'OK' 'Active selection: system.'
        } else {
            Add-Check 'Resolution' 'OK' "Active selection: $($resolved.CanonicalId) (set by $($resolved.OriginKind))."
        }
    } catch {
        Add-Check 'Resolution' 'ERROR' "Active selection is invalid: $($_.Exception.Message)"
    }

    # JAVA_HOME / JDK_HOME consistency (only meaningful for a managed selection)
    if ($resolved -and $resolved.OriginKind -ne 'System') {
        if (Test-JenvPathsEqual -ReferencePath $env:JAVA_HOME -DifferencePath $resolved.Home) {
            Add-Check 'JavaHome' 'OK' 'JAVA_HOME matches the selection.'
        } else {
            Add-Check 'JavaHome' 'WARN' "JAVA_HOME is '$env:JAVA_HOME' but selection is '$($resolved.Home)'. Run 'jenv refresh'."
        }
        if (Test-JenvPathsEqual -ReferencePath $env:JDK_HOME -DifferencePath $resolved.Home) {
            Add-Check 'JdkHome' 'OK' 'JDK_HOME matches the selection.'
        } else {
            Add-Check 'JdkHome' 'WARN' "JDK_HOME is '$env:JDK_HOME' but selection is '$($resolved.Home)'."
        }
    } else {
        Add-Check 'JavaHome' 'OK' 'No managed JAVA_HOME (system).'
        Add-Check 'JdkHome' 'OK' 'No managed JDK_HOME (system).'
    }

    # PATH: managed bin first + not duplicated
    if ($resolved -and $resolved.OriginKind -ne 'System') {
        $targetBin = Join-Path $resolved.Home 'bin'
        $entries = if ($env:PATH) { @($env:PATH -split ';') } else { @() }
        $firstOk = ($entries.Count -gt 0) -and (Test-JenvPathsEqual -ReferencePath $entries[0] -DifferencePath $targetBin)
        $dupCount = @($entries | Where-Object { Test-JenvPathsEqual -ReferencePath $_ -DifferencePath $targetBin }).Count
        if ($firstOk -and $dupCount -le 1) {
            Add-Check 'Path' 'OK' 'Managed bin is first on PATH and not duplicated.'
        } else {
            Add-Check 'Path' 'WARN' "Managed bin on PATH $dupCount time(s). Run 'jenv refresh'."
        }
    } else {
        Add-Check 'Path' 'OK' 'No managed bin on PATH (system).'
    }

    # JavaCommand
    if ($resolved -and $resolved.OriginKind -ne 'System') {
        $cmd = Get-Command java -ErrorAction SilentlyContinue
        if ($cmd -and (Test-JenvPathsEqual -ReferencePath $cmd.Source -DifferencePath (Join-Path $resolved.Home 'bin\java.exe'))) {
            Add-Check 'JavaCommand' 'OK' "'java' resolves to the selected JDK."
        } else {
            Add-Check 'JavaCommand' 'WARN' "'java' does not resolve to the selected JDK. Run 'jenv refresh'."
        }
    } else {
        Add-Check 'JavaCommand' 'OK' 'System java.'
    }

    # PromptHook
    $state = $null
    try { $state = Get-JenvSessionState } catch { }
    if ($state -and $state.PromptInstalled) {
        Add-Check 'PromptHook' 'OK' 'Prompt hook is installed.'
    } else {
        Add-Check 'PromptHook' 'WARN' "Prompt hook not installed in this session. Run 'jenv init'."
    }

    return $results.ToArray()
}
