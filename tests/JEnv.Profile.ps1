#requires -Version 7.4
Set-StrictMode -Version Latest

# Pester 5/6 tests for Phase C: Profile bootstrap install/uninstall and the
# prompt hook (chaining, auto-switch, idempotency).

$script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\JEnv\JEnv.psd1')).Path
Remove-Module JEnv -ErrorAction SilentlyContinue
Import-Module $script:ModulePath -Force

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    $script:__JENV_ROOT = $env:JENV_ROOT
    $script:__JENV_VERSION = $env:JENV_VERSION
    $script:__JAVA_HOME = $env:JAVA_HOME
    $script:__PATH = $env:PATH
    $script:__Prompt = (Get-Command -Name prompt -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock

    $script:PRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('jenv-prof-' + [System.IO.Path]::GetRandomFileName())
    $env:JENV_ROOT = $script:PRoot
    $script:Jdk8 = Join-Path $script:PRoot 'j8'
    $script:Jdk17 = Join-Path $script:PRoot 'j17'
    New-FakeJdk -Base $script:Jdk8 -Version '1.8.0_442' -Implementor 'Amazon.com Inc.' -OsArch 'x86_64'
    New-FakeJdk -Base $script:Jdk17 -Version '17.0.12+7' -Implementor 'Eclipse Adoptium' -OsArch 'amd64'
    Register-JenvJdk -Home $script:Jdk8 | Out-Null
    Register-JenvJdk -Home $script:Jdk17 | Out-Null

    $script:Prof = Join-Path $script:PRoot 'profile.ps1'
}

AfterAll {
    if ($script:__Prompt) { Set-Item -Path 'Function:\global:prompt' -Value $script:__Prompt }
    $env:JENV_ROOT = $script:__JENV_ROOT
    $env:JENV_VERSION = $script:__JENV_VERSION
    $env:JAVA_HOME = $script:__JAVA_HOME
    $env:PATH = $script:__PATH
    Remove-Item -Recurse -Force $script:PRoot -ErrorAction SilentlyContinue
    Remove-Module JEnv -ErrorAction SilentlyContinue
}

Describe 'Profile bootstrap' {
    AfterEach { Remove-Item -LiteralPath $script:Prof -Force -ErrorAction SilentlyContinue }

    It 'installs the block' {
        (& (Get-Module JEnv) { param($p) (Add-JenvProfileBootstrap -Path $p).Action } $script:Prof) | Should -Be 'Installed'
        (Get-Content -LiteralPath $script:Prof -Raw) | Should -Match 'jenv-windows initialize'
    }
    It 'is idempotent on a second install' {
        & (Get-Module JEnv) { param($p) Add-JenvProfileBootstrap -Path $p } $script:Prof | Out-Null
        (& (Get-Module JEnv) { param($p) (Add-JenvProfileBootstrap -Path $p).Action } $script:Prof) | Should -Be 'Unchanged'
    }
    It 'refuses a partial marker' {
        Set-Content -LiteralPath $script:Prof -Value "# >>> jenv-windows initialize >>>`nImport-Module JEnv" -NoNewline
        { & (Get-Module JEnv) { param($p) Add-JenvProfileBootstrap -Path $p } $script:Prof } | Should -Throw -ErrorId 'JEnv.Profile.UpdateFailed'
    }
    It 'uninstalls the block' {
        & (Get-Module JEnv) { param($p) Add-JenvProfileBootstrap -Path $p } $script:Prof | Out-Null
        (& (Get-Module JEnv) { param($p) (Remove-JenvProfileBootstrap -Path $p).Action } $script:Prof) | Should -Be 'Removed'
        (Get-Content -LiteralPath $script:Prof -Raw) | Should -Not -Match 'jenv-windows initialize'
    }
    It 'preserves unrelated LF whitespace during uninstall' {
        $original = "function before { 'x' }`n`n`nfunction after { 'y' }`n"
        [System.IO.File]::WriteAllText($script:Prof, $original, [System.Text.UTF8Encoding]::new($false))
        & (Get-Module JEnv) { param($p) Add-JenvProfileBootstrap -Path $p } $script:Prof | Out-Null
        & (Get-Module JEnv) { param($p) Remove-JenvProfileBootstrap -Path $p } $script:Prof | Out-Null
        [System.IO.File]::ReadAllText($script:Prof) | Should -Be $original
    }
    It 'uninstall is idempotent when absent' {
        (& (Get-Module JEnv) { param($p) (Remove-JenvProfileBootstrap -Path $p).Action } $script:Prof) | Should -Be 'Unchanged'
    }
}

Describe 'Prompt hook' {
    BeforeEach {
        Remove-Item Env:\JENV_VERSION -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $script:PRoot 'version') -ErrorAction SilentlyContinue
        Set-Item -Path 'Function:\global:prompt' -Value { 'SENTINEL> ' }
        InModuleScope JEnv { $script:JEnvSession = $null }
    }
    AfterEach {
        InModuleScope JEnv { Disable-JenvPromptHook }
        Set-Item -Path 'Function:\global:prompt' -Value { 'SENTINEL> ' }
    }

    It 'chains onto the existing prompt and installs the hook' {
        InModuleScope JEnv {
            Enable-JenvPromptHook
            $s = Get-JenvSessionState
            $s.PromptInstalled | Should -BeTrue
            ($null -ne $s.PreviousPrompt) | Should -BeTrue
            ((Get-Command prompt).Definition -match 'JenvResolutionFingerprint') | Should -BeTrue
        }
    }
    It 'auto-switches JAVA_HOME when the resolution fingerprint changes' {
        InModuleScope JEnv {
            # initialize against global 8, then mark initialized
            jenv global 8 | Out-Null
            Sync-JenvEnvironment -Force
            (Get-JenvSessionState).Initialized = $true
            Set-Item -Path 'Function:\global:prompt' -Value { 'SENTINEL> ' }
            Enable-JenvPromptHook
        }
        $proj = Join-Path $script:PRoot 'proj'
        New-Item -ItemType Directory -Force -Path $proj | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.java-version') -Value '17' -NoNewline
        $env:JAVA_HOME | Should -Be $script:Jdk8
        Set-Location -LiteralPath $proj
        InModuleScope JEnv { __JenvPrompt | Out-Null }
        $env:JAVA_HOME | Should -Be $script:Jdk17
        Set-Location -LiteralPath $script:PRoot
    }
    It 'does not re-sync when the fingerprint is unchanged' {
        InModuleScope JEnv {
            jenv global 8 | Out-Null
            Sync-JenvEnvironment -Force
            $s = Get-JenvSessionState
            $s.Initialized = $true
            Enable-JenvPromptHook
            $s.LastFingerprint = (Get-JenvResolutionFingerprint)
            # changing JAVA_HOME directly must NOT be reverted by an unchanged-fingerprint hook
            $env:JAVA_HOME = 'C:\user-set'
            __JenvPrompt | Out-Null
            $env:JAVA_HOME | Should -Be 'C:\user-set'
        }
    }
    It 'reinstalls the hook after another prompt replaces it' {
        InModuleScope JEnv {
            Enable-JenvPromptHook
            Set-Item -Path 'Function:\global:prompt' -Value { 'THEME> ' }
            (Test-JenvPromptHookInstalled) | Should -BeFalse
            Enable-JenvPromptHook
            (Test-JenvPromptHookInstalled) | Should -BeTrue
            (__JenvPrompt) | Should -Be 'THEME> '
        }
    }
}
