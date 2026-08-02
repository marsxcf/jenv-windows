#requires -Version 7.4
Set-StrictMode -Version Latest

# Shared test helpers. Dot-source inside a Describe's BeforeAll so the functions
# are visible to that block under Pester 6's isolated scoping.

function New-FakeJdk {
    param([string]$Base, [string]$Version, [string]$Implementor, [string]$OsArch)
    New-Item -ItemType Directory -Force -Path (Join-Path $Base 'bin') | Out-Null
    Set-Content -LiteralPath (Join-Path $Base 'bin\java.exe') -Value '' -NoNewline
    Set-Content -LiteralPath (Join-Path $Base 'bin\javac.exe') -Value '' -NoNewline
    $rel = (@("JAVA_VERSION=`"$Version`"", "IMPLEMENTOR=`"$Implementor`"", "OS_ARCH=`"$OsArch`"") -join "`n")
    [System.IO.File]::WriteAllText((Join-Path $Base 'release'), $rel, [System.Text.UTF8Encoding]::new($false))
}
