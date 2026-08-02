#requires -Version 7.4
Set-StrictMode -Version Latest

# Pester 5/6 tests for the Phase B session integration: PATH ownership model,
# shell/local/global sync, and `jenv exec` environment isolation.

$script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\JEnv\JEnv.psd1')).Path
Remove-Module JEnv -ErrorAction SilentlyContinue
Import-Module $script:ModulePath -Force

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    $script:__JENV_ROOT = $env:JENV_ROOT
    $script:__JENV_VERSION = $env:JENV_VERSION
    $script:__JAVA_HOME = $env:JAVA_HOME
    $script:__JDK_HOME = $env:JDK_HOME
    $script:__PATH = $env:PATH

    $script:SRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('jenv-sess-' + [System.IO.Path]::GetRandomFileName())
    $env:JENV_ROOT = $script:SRoot
    $script:Jdk8 = Join-Path $script:SRoot 'j8'
    $script:Jdk17 = Join-Path $script:SRoot 'j17'
    New-FakeJdk -Base $script:Jdk8 -Version '1.8.0_442' -Implementor 'Amazon.com Inc.' -OsArch 'x86_64'
    New-FakeJdk -Base $script:Jdk17 -Version '17.0.12+7' -Implementor 'Eclipse Adoptium' -OsArch 'amd64'
    Register-JenvJdk -Home $script:Jdk8 | Out-Null
    Register-JenvJdk -Home $script:Jdk17 | Out-Null

    # Capture a clean PATH (no jenv-managed bins yet) for per-test isolation.
    $script:CleanPath = $env:PATH
}

AfterAll {
    $env:JENV_ROOT = $script:__JENV_ROOT
    $env:JENV_VERSION = $script:__JENV_VERSION
    $env:JAVA_HOME = $script:__JAVA_HOME
    $env:JDK_HOME = $script:__JDK_HOME
    $env:PATH = $script:__PATH
    Remove-Item -Recurse -Force $script:SRoot -ErrorAction SilentlyContinue
    Remove-Module JEnv -ErrorAction SilentlyContinue
}

Describe 'PATH ownership model' {
    BeforeEach {
        $env:PATH = $script:CleanPath
        Remove-Item Env:\JENV_VERSION -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $script:SRoot 'version') -ErrorAction SilentlyContinue
        & (Get-Module JEnv) { $script:JEnvSession = $null }
    }

    It 'Build-JenvManagedPath prepends target, removes old+target, preserves others' {
        InModuleScope JEnv {
            $result = Build-JenvManagedPath -CurrentPath 'OLD;A;B;TARGET;C' -OldManagedBin 'OLD' -TargetBin 'TARGET'
            ($result -split ';') -join '|' | Should -Be 'TARGET|A|B|C'
        }
    }
    It 'Build-JenvManagedPath preserves empty PATH entries' {
        InModuleScope JEnv {
            $result = Build-JenvManagedPath -CurrentPath 'A;;B;OLD' -OldManagedBin 'OLD' -TargetBin 'T'
            ($result -split ';') -join '|' | Should -Be 'T|A||B'
        }
    }
    It 'switching leaves no residue and keeps one managed bin' {
        jenv global 8 | Out-Null
        ($env:JAVA_HOME) | Should -Be $script:Jdk8
        jenv global 17 | Out-Null
        ($env:PATH -split ';')[0] | Should -Be (Join-Path $script:Jdk17 'bin')
        @($env:PATH -split ';' | Where-Object { $_ -like '*\j8\bin' -or $_ -like '*\j17\bin' }).Count | Should -Be 1
        jenv global 8 | Out-Null
        @($env:PATH -split ';' | Where-Object { $_ -like '*\j8\bin' -or $_ -like '*\j17\bin' }).Count | Should -Be 1
    }
    It 'preserves PATH entries added by other tools after init' {
        jenv global 8 | Out-Null
        $env:PATH += ';C:\other-tool\bin'
        jenv global 17 | Out-Null
        ($env:PATH -split ';') -contains 'C:\other-tool\bin' | Should -BeTrue
    }
    It 'system restore removes the managed bin' {
        jenv shell 17 | Out-Null
        ($env:PATH -split ';')[0] | Should -Be (Join-Path $script:Jdk17 'bin')
        jenv shell --unset | Out-Null
        @($env:PATH -split ';' | Where-Object { $_ -like '*\j8\bin' -or $_ -like '*\j17\bin' }).Count | Should -Be 0
    }
}

Describe 'scoped selection and sync' {
    BeforeEach {
        $env:PATH = $script:CleanPath
        Remove-Item Env:\JENV_VERSION -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $script:SRoot 'version') -ErrorAction SilentlyContinue
        & (Get-Module JEnv) { $script:JEnvSession = $null }
        Set-Location -LiteralPath $script:SRoot
    }

    It 'shell sets JENV_VERSION and syncs' {
        jenv shell 17 | Out-Null
        $env:JENV_VERSION | Should -Be '17'
        ($env:JAVA_HOME) | Should -Be $script:Jdk17
        (Get-JenvCurrent) | Should -Match 'temurin64-17.0.12'
    }
    It 'global writes the global version file' {
        jenv global 8 | Out-Null
        (Get-Content -LiteralPath (Join-Path $script:SRoot 'version') -Raw).Trim() | Should -Be '8'
    }
    It 'local takes precedence over global' {
        jenv global 17 | Out-Null
        jenv local 8 | Out-Null
        (Get-JenvCurrent) | Should -Match 'corretto64-1.8.0.442'
        jenv local --unset | Out-Null
        (Get-JenvCurrent) | Should -Match 'temurin64-17.0.12'
    }
}

Describe 'jenv exec isolation' {
    BeforeEach {
        $env:PATH = $script:CleanPath
        Remove-Item Env:\JENV_VERSION -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $script:SRoot 'version') -ErrorAction SilentlyContinue
        & (Get-Module JEnv) { $script:JEnvSession = $null }
    }

    It 'applies an explicit version transiently and restores the caller env' {
        jenv global 8 | Out-Null
        $before = $env:JAVA_HOME
        $seen = jenv exec --version 17 -- pwsh -NoProfile -Command '$env:JAVA_HOME'
        $seen | Should -Be $script:Jdk17
        $env:JAVA_HOME | Should -Be $before
    }
    It 'preserves $LASTEXITCODE of the target command' {
        jenv exec --version 8 -- pwsh -NoProfile -Command 'exit 42'
        $LASTEXITCODE | Should -Be 42
    }
    It 'uses the current resolution when no --version is given' {
        jenv global 17 | Out-Null
        $seen = jenv exec -- pwsh -NoProfile -Command "if (`$env:PATH -match ([regex]::Escape((Join-Path `$env:JAVA_HOME 'bin')))) { 'yes' } else { 'no' }"
        $seen | Should -Be 'yes'
    }
}
