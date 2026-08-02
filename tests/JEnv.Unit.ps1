#requires -Version 7.4
Set-StrictMode -Version Latest

# Pester 5/6 unit tests for jenv-windows Phase A.
# Run:  Invoke-Pester -Path ./tests/JEnv.Unit.ps1 -Output Detailed
# Requires Pester 5+ (Install-Module Pester -Scope CurrentUser).

# Import at the top level so the module is available during Pester 6 discovery
# (InModuleScope is resolved at discovery time, before BeforeAll runs).
$script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\JEnv\JEnv.psd1')).Path
Remove-Module JEnv -ErrorAction SilentlyContinue
Import-Module $script:ModulePath -Force

BeforeAll {
    $script:__JENV_ROOT = $env:JENV_ROOT
    $script:__JENV_VERSION = $env:JENV_VERSION
    $script:__JAVA_HOME = $env:JAVA_HOME
    $script:__PATH = $env:PATH
    $script:__PWD = (Get-Location).Path
}

AfterAll {
    $env:JENV_ROOT = $script:__JENV_ROOT
    $env:JENV_VERSION = $script:__JENV_VERSION
    $env:JAVA_HOME = $script:__JAVA_HOME
    $env:PATH = $script:__PATH
    Set-Location -LiteralPath $script:__PWD
    Remove-Module JEnv -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
Describe 'Paths' {
    InModuleScope JEnv {
        It 'normalizes trailing separators but keeps a drive root' {
            ConvertTo-JenvNormalizedPath -Path 'C:\foo\bar\' | Should -Be 'C:\foo\bar'
            ConvertTo-JenvNormalizedPath -Path 'C:\' | Should -Be 'C:\'
        }
        It 'treats empty as empty' {
            ConvertTo-JenvNormalizedPath -Path '' | Should -Be ([string]::Empty)
        }
        It 'compares paths case-insensitively and ignores trailing separators' {
            Test-JenvPathsEqual -ReferencePath 'C:\Foo\bar' -DifferencePath 'c:\foo\bar\' | Should -BeTrue
        }
        It 'Get-JenvRoot rejects relative paths' {
            $env:JENV_ROOT = 'relative\path'
            { Get-JenvRoot } | Should -Throw -ErrorId 'JEnv.Registry.Invalid'
        }
        It 'Get-JenvRoot rejects CR/LF' {
            $env:JENV_ROOT = "C:\evil`nfoo"
            { Get-JenvRoot } | Should -Throw -ErrorId 'JEnv.Registry.Invalid'
        }
        It 'Test-JenvHomePathSafe rejects empty/;/CR/LF' {
            Test-JenvHomePathSafe -HomePath '' | Should -BeFalse
            Test-JenvHomePathSafe -HomePath 'C:\a;b' | Should -BeFalse
            Test-JenvHomePathSafe -HomePath "C:\a`nb" | Should -BeFalse
            Test-JenvHomePathSafe -HomePath 'C:\Program Files\Java' | Should -BeTrue
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'JdkProbe / metadata' {
    InModuleScope JEnv {
        It 'parses a release file (quoted values, comments, junk lines)' {
            $txt = @"
# comment
JAVA_VERSION="1.8.0_442"
IMPLEMENTOR="Amazon.com Inc."
OS_ARCH="x86_64"
junk line without equals
"@
            $p = Read-JenvReleaseFile -Content $txt
            $p['JAVA_VERSION'] | Should -Be '1.8.0_442'
            $p['IMPLEMENTOR'] | Should -Be 'Amazon.com Inc.'
            $p['OS_ARCH'] | Should -Be 'x86_64'
            $p.Contains('junk line without equals') | Should -BeFalse
        }
        It 'parses java property output' {
            $txt = "    java.version = 17.0.12`n    java.vendor = Eclipse Adoptium`n    os.arch = amd64`n"
            $p = Parse-JenvPropertyOutput -Text $txt
            $p['java.version'] | Should -Be '17.0.12'
            $p['os.arch'] | Should -Be 'amd64'
        }
        It 'normalizes Corretto 8 metadata' {
            $m = ConvertTo-JenvJdkMetadata -Release ([ordered]@{ JAVA_VERSION = '1.8.0_442'; IMPLEMENTOR = 'Amazon.com Inc.'; OS_ARCH = 'x86_64' })
            $m.NormalizedVersion | Should -Be '1.8.0.442'
            $m.Major | Should -Be 8
            $m.VendorId | Should -Be 'corretto'
            $m.Architecture | Should -Be 'x64'
        }
        It 'normalizes Temurin 17 metadata and strips build metadata' {
            $m = ConvertTo-JenvJdkMetadata -Release ([ordered]@{ JAVA_VERSION = '17.0.12+7'; IMPLEMENTOR = 'Eclipse Adoptium'; OS_ARCH = 'amd64' })
            $m.NormalizedVersion | Should -Be '17.0.12'
            $m.Major | Should -Be 17
            $m.VendorId | Should -Be 'temurin'
        }
        It 'maps vendors and architectures' {
            (ConvertTo-JenvVendorId -Vendor 'Azul Zulu').ToString() | Should -Be 'zulu'
            (ConvertTo-JenvVendorId -Vendor 'BellSoft Liberica').ToString() | Should -Be 'liberica'
            (ConvertTo-JenvVendorId -Vendor 'SapMachine').ToString() | Should -Be 'sapmachine'
            (ConvertTo-JenvArchitecture -OsArch 'aarch64').ToString() | Should -Be 'arm64'
            (ConvertTo-JenvArchitecture -OsArch 'i386').ToString() | Should -Be 'x86'
        }
        It 'builds canonical ids' {
            $m = [pscustomobject]@{ VendorId = 'microsoft'; Architecture = 'arm64'; NormalizedVersion = '21.0.4' }
            Get-JenvCanonicalId -Metadata $m | Should -Be 'microsoftarm64-21.0.4'
            $m2 = [pscustomobject]@{ VendorId = 'corretto'; Architecture = 'x64'; NormalizedVersion = '1.8.0.442' }
            Get-JenvCanonicalId -Metadata $m2 | Should -Be 'corretto64-1.8.0.442'
        }
        It 'generates candidate aliases (Corretto 8)' {
            $m = [pscustomobject]@{ NormalizedVersion = '1.8.0.442'; Major = 8 }
            $a = Get-JenvCandidateAliases -Metadata $m -CanonicalId 'corretto64-1.8.0.442'
            ($a -join ',') | Should -Be 'corretto64-1.8.0.442,1.8.0.442,1.8,8'
        }
        It 'generates candidate aliases (single component 21)' {
            $m = [pscustomobject]@{ NormalizedVersion = '21'; Major = 21 }
            $a = Get-JenvCandidateAliases -Metadata $m -CanonicalId 'openjdk64-21'
            ($a -join ',') | Should -Be 'openjdk64-21,21'
        }
        It 'treats a PowerShell-expression-looking release value as text only' {
            $p = Read-JenvReleaseFile -Content 'JAVA_VERSION="$(Get-Content secret)"'
            $p['JAVA_VERSION'] | Should -Be '$(Get-Content secret)'
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'VersionResolver' {
    InModuleScope JEnv {
        BeforeEach {
            $env:JENV_ROOT = (Join-Path ([System.IO.Path]::GetTempPath()) ('jenv-vr-' + [System.IO.Path]::GetRandomFileName()))
            New-Item -ItemType Directory -Force -Path $env:JENV_ROOT | Out-Null
            Remove-Item Env:\JENV_VERSION -ErrorAction SilentlyContinue
        }
        AfterEach { Remove-Item -Recurse -Force $env:JENV_ROOT -ErrorAction SilentlyContinue }

        It 'validates version expressions' {
            Test-JenvVersionExpression -Expression '17' | Should -BeTrue
            Test-JenvVersionExpression -Expression 'corretto64-1.8.0.442' | Should -BeTrue
            Test-JenvVersionExpression -Expression 'system' | Should -BeTrue
            Test-JenvVersionExpression -Expression '' | Should -BeFalse
            Test-JenvVersionExpression -Expression ' has spaces' | Should -BeFalse
        }

        It 'reads a version file with LF/CRLF/trailing newline' {
            $f = Join-Path $env:JENV_ROOT 'vf.txt'
            Set-Content -LiteralPath $f -Value "17`n" -NoNewline
            (Read-JenvVersionFile -Path $f) | Should -Be '17'
            Set-Content -LiteralPath $f -Value "17`r`n" -NoNewline
            (Read-JenvVersionFile -Path $f) | Should -Be '17'
        }
        It 'rejects empty / multiline / bad version files (fail-fast)' {
            $f = Join-Path $env:JENV_ROOT 'vf.txt'
            Set-Content -LiteralPath $f -Value '' -NoNewline
            { Read-JenvVersionFile -Path $f } | Should -Throw -ErrorId 'JEnv.VersionFile.Invalid'
            Set-Content -LiteralPath $f -Value "17`n21`n" -NoNewline
            { Read-JenvVersionFile -Path $f } | Should -Throw -ErrorId 'JEnv.VersionFile.Invalid'
            Set-Content -LiteralPath $f -Value 'bad expr!' -NoNewline
            { Read-JenvVersionFile -Path $f } | Should -Throw -ErrorId 'JEnv.VersionFile.Invalid'
        }

        It 'walks parent directories for .java-version' {
            $root = Join-Path $env:JENV_ROOT 'proj'
            $deep = Join-Path $root 'a\b\c'
            New-Item -ItemType Directory -Force -Path $deep | Out-Null
            Set-Content -LiteralPath (Join-Path $root '.java-version') -Value '17' -NoNewline
            (Find-JenvLocalVersionFile -Directory $deep) | Should -Be (Join-Path $root '.java-version')
        }
    }
}

Describe 'VersionResolver precedence and fail-fast' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'helpers.ps1')
        $script:VRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('jenv-prec-' + [System.IO.Path]::GetRandomFileName())
        $env:JENV_ROOT = $script:VRoot
        $script:Jdk8 = Join-Path $script:VRoot 'jdk8'
        $script:Jdk17 = Join-Path $script:VRoot 'jdk17'
        New-FakeJdk -Base $script:Jdk8 -Version '1.8.0_442' -Implementor 'Amazon.com Inc.' -OsArch 'x86_64'
        New-FakeJdk -Base $script:Jdk17 -Version '17.0.12+7' -Implementor 'Eclipse Adoptium' -OsArch 'amd64'
        Register-JenvJdk -Home $script:Jdk8 | Out-Null
        Register-JenvJdk -Home $script:Jdk17 | Out-Null
        $script:Proj = Join-Path $script:VRoot 'proj'
        New-Item -ItemType Directory -Force -Path $script:Proj | Out-Null
    }
    AfterAll { Remove-Item -Recurse -Force $script:VRoot -ErrorAction SilentlyContinue }

    BeforeEach { Remove-Item Env:\JENV_VERSION -ErrorAction SilentlyContinue }

    It 'resolves to system when nothing is set' {
        Remove-Item -LiteralPath (Join-Path $script:VRoot 'version') -ErrorAction SilentlyContinue
        Set-Location -LiteralPath $script:VRoot
        (Get-JenvCurrent) | Should -Be 'system'
    }
    It 'global wins over system' {
        Set-Content -LiteralPath (Join-Path $script:VRoot 'version') -Value '8' -NoNewline
        Set-Location -LiteralPath $script:VRoot
        (Get-JenvCurrent) | Should -Match 'corretto64-1.8.0.442'
    }
    It 'local wins over global' {
        Set-Content -LiteralPath (Join-Path $script:VRoot 'version') -Value '8' -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Proj '.java-version') -Value '17' -NoNewline
        Set-Location -LiteralPath $script:Proj
        (Get-JenvCurrent) | Should -Match 'temurin64-17.0.12'
    }
    It 'shell wins over local' {
        Set-Content -LiteralPath (Join-Path $script:Proj '.java-version') -Value '17' -NoNewline
        Set-Location -LiteralPath $script:Proj
        $env:JENV_VERSION = '8'
        (Get-JenvCurrent) | Should -Match 'corretto64-1.8.0.442'
    }
    It 'fail-fast: an unregistered shell version errors, does not fall through' {
        $env:JENV_VERSION = '9999'
        { Get-JenvCurrent } | Should -Throw -ErrorId 'JEnv.Version.NotInstalled'
    }
    It 'fail-fast: an invalid local version file errors' {
        Remove-Item Env:\JENV_VERSION -ErrorAction SilentlyContinue
        Set-Content -LiteralPath (Join-Path $script:Proj '.java-version') -Value 'bad!expr' -NoNewline
        Set-Location -LiteralPath $script:Proj
        { Get-JenvCurrent } | Should -Throw -ErrorId 'JEnv.VersionFile.Invalid'
    }
}

# ---------------------------------------------------------------------------
Describe 'Registry' {
    InModuleScope JEnv {
        BeforeEach {
            $env:JENV_ROOT = (Join-Path ([System.IO.Path]::GetTempPath()) ('jenv-reg-' + [System.IO.Path]::GetRandomFileName()))
            New-Item -ItemType Directory -Force -Path $env:JENV_ROOT | Out-Null
        }
        AfterEach { Remove-Item -Recurse -Force $env:JENV_ROOT -ErrorAction SilentlyContinue }

        It 'missing file reads as an empty skeleton' {
            Remove-Item -LiteralPath (Join-Path $env:JENV_ROOT 'versions.json') -ErrorAction SilentlyContinue
            $r = Read-JenvRegistry
            $r.schemaVersion | Should -Be 1
            @($r.jdks.Keys).Count | Should -Be 0
        }
        It 'round-trips a write and bumps revision' {
            Update-JenvRegistry -Mutation { param($r)
                $r.jdks['openjdk64-21'] = [ordered]@{ home = 'C:\jdk'; version = '21'; normalizedVersion = '21'; major = 21; vendor = 'x'; vendorId = 'openjdk'; architecture = 'x64'; registeredAt = 't'; updatedAt = 't' }
                $r.aliases['21'] = 'openjdk64-21'
            }
            Update-JenvRegistry -Mutation { param($r) $r.aliases['latest'] = 'openjdk64-21' }
            $r = Read-JenvRegistry
            $r.jdks.Contains('openjdk64-21') | Should -BeTrue
            $r.aliases['21'] | Should -Be 'openjdk64-21'
            $r.aliases['latest'] | Should -Be 'openjdk64-21'
            $r.revision | Should -Be 2
        }
        It 'rejects corrupt JSON (does not treat as empty)' {
            Set-Content -LiteralPath (Join-Path $env:JENV_ROOT 'versions.json') -Value '{not json' -NoNewline
            { Read-JenvRegistry } | Should -Throw -ErrorId 'JEnv.Registry.Invalid'
        }
        It 'rejects a dangling alias on read' {
            $bad = '{"schemaVersion":1,"revision":0,"jdks":{"a-1":{"home":"C:\\a","version":"1","normalizedVersion":"1","major":1,"vendor":"v","vendorId":"v","architecture":"x64","registeredAt":"t","updatedAt":"t"}},"aliases":{"dangling":"does-not-exist"}}'
            Set-Content -LiteralPath (Join-Path $env:JENV_ROOT 'versions.json') -Value $bad -NoNewline
            { Read-JenvRegistry } | Should -Throw -ErrorId 'JEnv.Registry.Invalid'
        }
        It 'rejects an unsafe home on read' {
            $bad = '{"schemaVersion":1,"revision":0,"jdks":{"a-1":{"home":"C:\\a;b","version":"1","normalizedVersion":"1","major":1,"vendor":"v","vendorId":"v","architecture":"x64","registeredAt":"t","updatedAt":"t"}},"aliases":{}}'
            Set-Content -LiteralPath (Join-Path $env:JENV_ROOT 'versions.json') -Value $bad -NoNewline
            { Read-JenvRegistry } | Should -Throw -ErrorId 'JEnv.Registry.Invalid'
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'JdkCommands add/remove/versions' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'helpers.ps1')
        $script:CRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('jenv-cmd-' + [System.IO.Path]::GetRandomFileName())
        $env:JENV_ROOT = $script:CRoot
        New-Item -ItemType Directory -Force -Path $script:CRoot | Out-Null
        $script:Jdk8 = Join-Path $script:CRoot 'jdk8'
        $script:Jdk17 = Join-Path $script:CRoot 'jdk17'
        New-FakeJdk -Base $script:Jdk8 -Version '1.8.0_442' -Implementor 'Amazon.com Inc.' -OsArch 'x86_64'
        New-FakeJdk -Base $script:Jdk17 -Version '17.0.12+7' -Implementor 'Eclipse Adoptium' -OsArch 'amd64'
    }
    AfterAll { Remove-Item -Recurse -Force $script:CRoot -ErrorAction SilentlyContinue }

    It 'registers a JDK with auto-aliases' {
        $r = Register-JenvJdk -Home $script:Jdk8
        $r.Action | Should -Be 'Added'
        $r.CanonicalId | Should -Be 'corretto64-1.8.0.442'
        ($r.Aliases -join ',') | Should -Be '1.8.0.442,1.8,8'
    }
    It 're-registers the same home as Updated' {
        $r = Register-JenvJdk -Home $script:Jdk8
        $r.Action | Should -Be 'Updated'
    }
    It 'refuses a canonical collision with a different home' {
        $evil = Join-Path $script:CRoot 'jdk8copy'
        New-FakeJdk -Base $evil -Version '1.8.0_442' -Implementor 'Amazon.com Inc.' -OsArch 'x86_64'
        { Register-JenvJdk -Home $evil } | Should -Throw -ErrorId 'JEnv.Alias.Conflict'
    }
    It 'adds an explicit alias without stealing others' {
        $r = Register-JenvJdk -Home $script:Jdk17 -Alias 'work17'
        ($r.Aliases -contains 'work17') | Should -BeTrue
        (Get-JenvJdk -Name '8').CanonicalId | Should -Be 'corretto64-1.8.0.442'
    }
    It 'refuses an explicit alias collision without --force, allows with --force' {
        { Register-JenvJdk -Home $script:Jdk17 -Alias '8' } | Should -Throw -ErrorId 'JEnv.Alias.Conflict'
        $r = Register-JenvJdk -Home $script:Jdk17 -Alias '8' -Force
        ($r.Aliases -contains '8') | Should -BeTrue
        (Get-JenvJdk -Name '8').CanonicalId | Should -Be 'temurin64-17.0.12'
    }
    It 'lists versions sorted by major' {
        $ids = (Get-JenvJdk).CanonicalId
        ($ids -join ',') | Should -Be 'corretto64-1.8.0.442,temurin64-17.0.12'
    }
    It 'refuses to remove the active version without --force' {
        Set-Content -LiteralPath (Join-Path $script:CRoot 'version') -Value '8' -NoNewline
        { Unregister-JenvJdk -Name '8' } | Should -Throw
        Unregister-JenvJdk -Name '8' -Force | Should -Not -BeNullOrEmpty
    }
}
