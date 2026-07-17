# ================================================================
# Core.Tests.ps1
# ----------------------------------------------------------------
# Pester unit tests for AutoInstaller.Core.ps1
#
# How to run (no administrator rights needed, works on Windows PowerShell 5.1 and PowerShell 7):
#   Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0   # once
#   Invoke-Pester -Path .\tests\Core.Tests.ps1 -Output Detailed
#
# This dot-sources AutoInstaller.Core.ps1 on its own and never triggers the side effects of
# auto-installer.ps1 itself (admin elevation, winget calls, console control).
# ================================================================

BeforeAll {
    $script:CorePath = Join-Path $PSScriptRoot "..\AutoInstaller.Core.ps1"
    . $script:CorePath

    # Keep Write-Log from touching disk; also exercises Core.ps1's own guard for a missing LOG_FILE.
    $script:LOG_FILE = $null
}

Describe "Get-VisualWidth" {
    It "returns the character count for ASCII strings" {
        Get-VisualWidth "Chrome" | Should -Be 6
    }

    It "returns 0 for empty/null input" {
        Get-VisualWidth "" | Should -Be 0
        Get-VisualWidth $null | Should -Be 0
    }

    It "counts full-width Korean characters as 2 cells each (regression case from the v0.0.8 fix)" {
        # "카카오톡" is 4 characters (String.Length) but should occupy 8 display cells.
        Get-VisualWidth "카카오톡" | Should -Be 8
    }

    It "computes correct width for mixed Korean/English text" {
        # "이름"(4) + " "(1) + "Id"(2) = 7
        Get-VisualWidth "이름 Id" | Should -Be 7
    }
}

Describe "Get-VisualPadRight" {
    It "pads ASCII strings to the target width using character count" {
        (Get-VisualPadRight "abc" 10).Length | Should -Be 10
    }

    It "pads full-width strings using visual width, not character count" {
        # "카카오톡" occupies 8 visual cells; padding to 12 should add 4 spaces (not 8)
        $result = Get-VisualPadRight "카카오톡" 12
        $result.Length | Should -Be (4 + 4)
        Get-VisualWidth $result | Should -Be 12
    }
}

Describe "Get-VisualSubstring" {
    It "splits Name/Id columns from a winget-list-style header by visual width" {
        # idStartWidth is derived from Get-VisualWidth directly, so this is deterministic
        # regardless of how many spaces separate the columns.
        $namePart = "카카오톡"
        $idPart = "Kakao.KakaoTalk"
        $idStartWidth = Get-VisualWidth $namePart
        $line = $namePart + (" " * 14) + $idPart + (" " * 7) + "1.2.3"
        $nameToken = Get-VisualSubstring -String $line -StartWidth 0 -LengthWidth $idStartWidth
        $nameToken | Should -Be $namePart
    }

    It "returns an empty string when the start width is out of range" {
        Get-VisualSubstring -String "abc" -StartWidth 100 -LengthWidth 10 | Should -Be ""
    }

    It "returns an empty string for null/empty input" {
        Get-VisualSubstring -String "" -StartWidth 0 -LengthWidth 5 | Should -Be ""
    }
}

Describe "Get-FailReason" {
    It "recognizes the package-not-found pattern" {
        Get-FailReason "No package found matching input criteria" | Should -Be "Package not found"
    }

    It "recognizes the Korean 'package not found' pattern (still emitted by winget on Korean locales)" {
        Get-FailReason "패키지를 찾을 수 없습니다" | Should -Be "Package not found"
    }

    It "extracts the code number from an exit-code pattern" {
        Get-FailReason "Installer failed with exit code: 1603" | Should -Match "1603"
    }

    It "extracts negative exit codes too (v0.0.10 fix)" {
        Get-FailReason "Installer failed with exit code: -1978335189" | Should -Match "-1978335189"
    }

    It "returns the default message for unrecognized text" {
        Get-FailReason "some completely unrelated text" | Should -Be "Unknown error"
    }

    It "returns the default message for empty input" {
        Get-FailReason "" | Should -Be "Unknown error"
    }
}

Describe "Test-IsAppInstalled" {
    BeforeEach {
        # Fresh fake install state for every test so tests don't leak state into each other
        $script:installedIds = @{
            "google.chrome"                = $true
            "python.python.3.12"           = $true
            "microsoft.microsoftpcmanager" = $true
            "notion.notioncalendar"        = $true
        }
        $script:installedNames = @{
            "google chrome" = $true
            "카카오톡"       = $true
            "pc manager"    = $true
        }
        $script:APP_CUSTOM_MAPPINGS = @{
            "9pm860492szd"    = @("microsoft.microsoftpcmanager", "pc manager", "windows pc manager")
            "kakao.kakaotalk" = @("카카오톡", "kakaotalk", "KakaoTalk")
        }
    }

    It "returns false when AppId is empty" {
        Test-IsAppInstalled -AppId "" | Should -BeFalse
    }

    It "stage 1: returns true for an exact ID match" {
        Test-IsAppInstalled -AppId "Google.Chrome" | Should -BeTrue
    }

    It "stage 2: detects via custom mapping (Store ID -> winget display name)" {
        Test-IsAppInstalled -AppId "9PM860492SZD" | Should -BeTrue
    }

    It "stage 2: detects KakaoTalk via its actual Korean display name (regression guard for the upstream translation bug that replaced '카카오톡' with the English literal 'KakaoTalk')" {
        Test-IsAppInstalled -AppId "Kakao.KakaoTalk" | Should -BeTrue
    }

    It "stage 3: detects a different Python minor version via prefix match" {
        # Catalog ID is Python.Python.3.13 but the installed one is 3.12
        Test-IsAppInstalled -AppId "Python.Python.3.13" | Should -BeTrue
    }

    It "stage 4: detects a two-segment match when the base ID itself is installed" {
        Test-IsAppInstalled -AppId "Google.Chrome.Beta" | Should -BeTrue
    }

    It "stage 4 regression guard: does NOT match Notion.Notion against an installed Notion.NotionCalendar (v0.0.10 segment-boundary fix)" {
        Test-IsAppInstalled -AppId "Notion.Notion" | Should -BeFalse
    }

    It "stage 5: detects via exact name match" {
        Test-IsAppInstalled -AppId "PC Manager" | Should -BeTrue
    }

    It "stage 5 regression guard: does not match on tokens shorter than 5 characters (v0.0.10 fix)" {
        # "pc" is a substring of "pc manager" but is only 2 characters, so it must NOT match.
        Test-IsAppInstalled -AppId "pc" | Should -BeFalse
    }

    It "returns false for a completely unrelated app" {
        Test-IsAppInstalled -AppId "Totally.Unknown.App.Xyz" | Should -BeFalse
    }

    Context "Malware Zero portable path detection (stage 6)" {
        It "returns true when the path exists" {
            Mock Test-Path { $true } -ParameterFilter { $Path -like "*mzk*" }
            Test-IsAppInstalled -AppId "Malware Zero" | Should -BeTrue
        }

        It "returns false when the path does not exist" {
            Mock Test-Path { $false }
            Test-IsAppInstalled -AppId "Malware Zero" | Should -BeFalse
        }
    }

    Context "Fallback-match WARN logging" {
        It "logs a WARN when the two-segment fallback (stage 4) fires" {
            Mock Write-Log {}
            Test-IsAppInstalled -AppId "Google.Chrome.Beta" | Out-Null
            Should -Invoke Write-Log -Times 1 -ParameterFilter { $Level -eq "WARN" -and $Message -like "*fallback:4*" }
        }

        It "does not log a WARN for an exact stage-1 match" {
            Mock Write-Log {}
            Test-IsAppInstalled -AppId "Google.Chrome" | Out-Null
            Should -Invoke Write-Log -Times 0 -ParameterFilter { $Level -eq "WARN" }
        }
    }
}
