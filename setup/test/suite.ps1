$suiteMode = "fast"
if ($env:SUITE_MODE) { $suiteMode = $env:SUITE_MODE }
$originRepo = "C:\origin.git"
if ($env:CLAUDE_SETUP_TEST_ORIGIN) { $originRepo = $env:CLAUDE_SETUP_TEST_ORIGIN }
$sourceRepo = "C:\src"
if ($env:CLAUDE_SETUP_TEST_SOURCE) { $sourceRepo = $env:CLAUDE_SETUP_TEST_SOURCE }
$passCount = 0
$failCount = 0

function Resolve-ExistingPath([string]$path) {
    return [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $path).Path)
}

function Test-IsUnderPath([string]$candidatePath, [string]$parentPath) {
    $comparison = [StringComparison]::OrdinalIgnoreCase
    $candidateFullPath = [IO.Path]::GetFullPath($candidatePath).TrimEnd('\')
    $parentFullPath = [IO.Path]::GetFullPath($parentPath).TrimEnd('\')
    if ($candidateFullPath.Equals($parentFullPath, $comparison)) { return $true }
    return $candidateFullPath.StartsWith($parentFullPath + "\", $comparison)
}

function Stop-UnsafeRun([string]$reason) {
    Write-Host "REFUSING TO RUN: $reason" -ForegroundColor Red
    exit 1
}

if ($env:CLAUDE_SETUP_TEST_SANDBOX -ne "1") {
    Stop-UnsafeRun "CLAUDE_SETUP_TEST_SANDBOX must be 1"
}
if (-not $env:USERPROFILE) {
    Stop-UnsafeRun "USERPROFILE is not set"
}

$resolvedUserProfile = Resolve-ExistingPath $env:USERPROFILE
$resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
if (-not (Test-IsUnderPath $resolvedUserProfile $resolvedTempRoot)) {
    Stop-UnsafeRun "USERPROFILE must resolve inside the temp directory"
}
if ($env:CLAUDE_SETUP_TEST_REAL_USERPROFILE) {
    $resolvedRealUserProfile = [IO.Path]::GetFullPath($env:CLAUDE_SETUP_TEST_REAL_USERPROFILE).TrimEnd('\')
    if ($resolvedUserProfile.Equals($resolvedRealUserProfile, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-UnsafeRun "USERPROFILE resolves to the real profile"
    }
}
if ($suiteMode -eq "full" -and $env:CLAUDE_SETUP_TEST_CONTAINER -ne "1") {
    Stop-UnsafeRun "full mode is only allowed inside the Windows container"
}

$ErrorActionPreference = "Stop"
$powerShellPath = (Get-Process -Id $PID).Path
$childWorkingDirectory = $resolvedUserProfile

function Pass([string]$label) {
    $script:passCount++
    Write-Host ("  PASS  {0}" -f $label)
}

function Fail([string]$label) {
    $script:failCount++
    Write-Host ("  FAIL  {0}" -f $label)
}

function Phase([string]$title) {
    Write-Host ""
    Write-Host ("=== {0} ===" -f $title)
}

function Assert-Ok([string]$label, [int]$status) {
    if ($status -eq 0) {
        Pass $label
        return
    }
    Fail "$label (exit $status)"
}

function Assert-Status([string]$label, [int]$expected, [int]$actual) {
    if ($expected -eq $actual) {
        Pass $label
        return
    }
    Fail "$label (expected exit $expected, got $actual)"
}

function Assert-File([string]$label, [string]$path) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Pass $label
        return
    }
    Fail "$label (missing $path)"
}

function Assert-NoFile([string]$label, [string]$path) {
    if (-not (Test-Path -LiteralPath $path)) {
        Pass $label
        return
    }
    Fail "$label (unexpected $path)"
}

function Assert-Dir([string]$label, [string]$path) {
    if (Test-Path -LiteralPath $path -PathType Container) {
        Pass $label
        return
    }
    Fail "$label (missing dir $path)"
}

function Assert-Equals([string]$label, [string]$expected, [string]$actual) {
    if ($expected -eq $actual) {
        Pass $label
        return
    }
    Fail "$label (expected '$expected', got '$actual')"
}

function Assert-Match([string]$label, [string]$pattern, [string]$text) {
    if ($text -match $pattern) {
        Pass $label
        return
    }
    Fail "$label (no match for /$pattern/)"
}

function Assert-NoMatch([string]$label, [string]$pattern, [string]$text) {
    if ($text -notmatch $pattern) {
        Pass $label
        return
    }
    Fail "$label (unexpected match for /$pattern/)"
}

# Deliberately duplicated from run-windows.ps1 rather than dot-sourced: this file is
# mounted into the container on its own, with no sibling scripts to import.
function Format-CommandArgument([string]$argument) {
    if ($null -eq $argument) { return '""' }
    if ($argument.Length -eq 0) { return '""' }
    if ($argument -notmatch '[\s"]') { return $argument }

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($character in $argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashCount++
            continue
        }
        if ($character -eq [char]34) {
            [void]$builder.Append("\" * (($backslashCount * 2) + 1))
            [void]$builder.Append('"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$builder.Append("\" * $backslashCount)
            $backslashCount = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashCount -gt 0) {
        [void]$builder.Append("\" * ($backslashCount * 2))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-PowerShellFile([string]$scriptPath, [string[]]$arguments) {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $powerShellPath
    $processArguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath) + $arguments
    $startInfo.Arguments = ($processArguments | ForEach-Object { Format-CommandArgument $_ }) -join " "
    $startInfo.UseShellExecute = $false
    # Children inherit the caller's directory otherwise, and a tool that resolves a
    # cache path relative to it (PowerShell's ModuleAnalysisCache does) drops files
    # into the repo being tested.
    $startInfo.WorkingDirectory = $childWorkingDirectory
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.Close()
    $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $status = $process.ExitCode
    return [pscustomobject]@{ Status = $status; Output = $output }
}

function Invoke-NodeWithInput([string]$scriptPath, [string]$inputText) {
    # The payload goes through a file and a cmd redirect: node on Windows never
    # sees a .NET RedirectStandardInput pipe, so a piped payload silently arrives
    # empty and every hook assertion passes vacuously. The file also carries the
    # non-ASCII payloads as raw UTF-8, past the console codepage.
    $payloadPath = Join-Path $env:TEMP ("hook-payload-" + [guid]::NewGuid().ToString("N") + ".json")
    [IO.File]::WriteAllBytes($payloadPath, [Text.UTF8Encoding]::new($false).GetBytes($inputText))
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $env:ComSpec
    $startInfo.Arguments = "/c node " + (Format-CommandArgument $scriptPath) + " < " + (Format-CommandArgument $payloadPath)
    $startInfo.UseShellExecute = $false
    $startInfo.WorkingDirectory = $childWorkingDirectory
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    # The hook resolves biome from the real npm global root, which the sandbox
    # APPDATA hides. Without this the JSON and TS gates fail open and prove nothing.
    if ($env:CLAUDE_SETUP_TEST_REAL_APPDATA) {
        $startInfo.Environment["APPDATA"] = $env:CLAUDE_SETUP_TEST_REAL_APPDATA
    }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $status = $process.ExitCode
    Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Status = $status; Output = $output.TrimEnd() }
}

function Get-TreeHash([string]$root) {
    # Windows PowerShell 5.1 runs on .NET Framework, which has no GetRelativePath.
    $rootFullPath = [IO.Path]::GetFullPath($root).TrimEnd('\')
    $hashLines = Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue |
        Sort-Object FullName |
        ForEach-Object {
            $relativePath = $_.FullName.Substring($rootFullPath.Length).TrimStart('\')
            "{0} {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm MD5).Hash, $relativePath
        }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($hashLines -join "`n"))
    $md5 = [Security.Cryptography.MD5]::Create()
    return [BitConverter]::ToString($md5.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
}

function Initialize-Checkout([string]$target) {
    New-Item -ItemType Directory -Force $target | Out-Null
    git -C $target init -q -b master
    git -C $target config remote.origin.url $originRepo
    git -C $target config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
    git -C $target fetch -q origin
    git -C $target checkout -q -f -B master origin/master
}

function Assert-RenderedSettings([string]$settingsPath) {
    Assert-File "renders settings.json" $settingsPath
    $rendered = Get-Content -LiteralPath $settingsPath -Raw -ErrorAction SilentlyContinue
    Assert-NoMatch "substitutes every USERPROFILE token" "\{\{HOME\}\}" $rendered
    $renderedProfilePath = ($env:USERPROFILE -replace "\\", "/") + "/.claude"
    Assert-Match "substitutes the sandbox profile directory" ([regex]::Escape($renderedProfilePath)) $rendered
    Assert-Match "renders parseable JSON" "^\s*\{" $rendered
    node -e "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'))" $settingsPath 2>$null
    Assert-Ok "settings.json parses as JSON" $LASTEXITCODE
}

function Test-CommandPresent([string]$commandName) {
    $command = Get-Command $commandName -ErrorAction SilentlyContinue
    if ($command) { return 0 }
    return 1
}

function Write-FakeCodium([string]$binDir, [switch]$EmptyProbe) {
    New-Item -ItemType Directory -Force $binDir | Out-Null
    $codiumPath = Join-Path $binDir "codium.cmd"
    $lines = @("@echo off")
    if (-not $EmptyProbe) {
        $lines += "if ""%~1""==""--list-extensions"" ("
        $lines += "  echo vendor.second"
        $lines += "  echo vendor.first"
        $lines += "  exit /b 0"
        $lines += ")"
    }
    $lines += "exit /b 0"
    Set-Content -LiteralPath $codiumPath -Value $lines -Encoding ascii
}

Write-Host "suite mode: $suiteMode"
Write-Host "PowerShell: $($PSVersionTable.PSVersion)"

$env:GIT_CONFIG_GLOBAL = Join-Path $env:TEMP "suite-gitconfig"
git config --global init.defaultBranch master
git config --global user.name "Suite Runner"
git config --global user.email "suite@example.com"
git config --global --add safe.directory "*"

$fakeBin = Join-Path $env:TEMP "suite-bin"
$env:Path = "$fakeBin;$env:Path"

Phase "argument handling"

$installOutput = Invoke-PowerShellFile (Join-Path $sourceRepo "setup\install.ps1") @("-Profile", "bogus")
Assert-Status "install.ps1 rejects an unknown profile" 1 $installOutput.Status
Assert-Match "install.ps1 names the valid profiles" "personal" $installOutput.Output

$unknownInstallOutput = Invoke-PowerShellFile (Join-Path $sourceRepo "setup\install.ps1") @("-Nonsense")
Assert-Status "install.ps1 rejects an unknown flag" 2 $unknownInstallOutput.Status
Assert-Match "install.ps1 names the rejected flag" "unknown option: -Nonsense" $unknownInstallOutput.Output

$installHelpOutput = Invoke-PowerShellFile (Join-Path $sourceRepo "setup\install.ps1") @("-Help")
Assert-Status "install.ps1 -Help exits clean" 0 $installHelpOutput.Status
Assert-Match "install.ps1 -Help prints usage" "Usage: setup/install.ps1" $installHelpOutput.Output

# The README shows --help for the shell scripts, and carbon units paste it at the
# PowerShell ones too, so both spellings have to reach the same usage text.
$installLongHelpOutput = Invoke-PowerShellFile (Join-Path $sourceRepo "setup\install.ps1") @("--help")
Assert-Status "install.ps1 --help exits clean" 0 $installLongHelpOutput.Status
Assert-Match "install.ps1 --help prints usage" "Usage: setup/install.ps1" $installLongHelpOutput.Output

$missingProfileOutput = Invoke-PowerShellFile (Join-Path $sourceRepo "setup\apply.ps1") @("-Profile")
Assert-Status "apply.ps1 rejects a valueless -Profile" 1 $missingProfileOutput.Status

$unknownApplyOutput = Invoke-PowerShellFile (Join-Path $sourceRepo "setup\apply.ps1") @("-Nonsense")
Assert-Status "apply.ps1 rejects an unknown flag" 2 $unknownApplyOutput.Status
Assert-Match "apply.ps1 names the rejected flag" "unknown option: -Nonsense" $unknownApplyOutput.Output

$applyHelpOutput = Invoke-PowerShellFile (Join-Path $sourceRepo "setup\apply.ps1") @("-Help")
Assert-Status "apply.ps1 -Help exits clean" 0 $applyHelpOutput.Status
Assert-Match "apply.ps1 -Help prints usage" "Usage: setup/apply.ps1" $applyHelpOutput.Output
Assert-NoMatch "apply.ps1 -Help applies nothing" "\[ ok \]" $applyHelpOutput.Output

$applyLongHelpOutput = Invoke-PowerShellFile (Join-Path $sourceRepo "setup\apply.ps1") @("--help")
Assert-Status "apply.ps1 --help exits clean" 0 $applyLongHelpOutput.Status

$nonInteractiveOutput = Invoke-PowerShellFile (Join-Path $sourceRepo "setup\apply.ps1") @("-SkipInstalls")
Assert-Status "apply.ps1 refuses to guess a profile without a redirected host" 1 $nonInteractiveOutput.Status
Assert-Match "apply.ps1 says how to supply the profile" "Re-run with -Profile" $nonInteractiveOutput.Output

$collectUnknownOutput = Invoke-PowerShellFile (Join-Path $sourceRepo "setup\collect.ps1") @("-Nonsense")
Assert-Status "collect.ps1 rejects an unknown flag" 2 $collectUnknownOutput.Status

$collectHelpOutput = Invoke-PowerShellFile (Join-Path $sourceRepo "setup\collect.ps1") @("-Help")
Assert-Status "collect.ps1 -Help exits clean" 0 $collectHelpOutput.Status
Assert-Match "collect.ps1 -Help prints usage" "Usage: setup/collect.ps1" $collectHelpOutput.Output
Assert-NoMatch "collect.ps1 -Help collects nothing" "collected:" $collectHelpOutput.Output

$collectLongHelpOutput = Invoke-PowerShellFile (Join-Path $sourceRepo "setup\collect.ps1") @("--help")
Assert-Status "collect.ps1 --help exits clean" 0 $collectLongHelpOutput.Status

Phase "bootstrap (README one-liner path, personal)"

$claudeHome = Join-Path $env:USERPROFILE ".claude"
$terminalStateDir = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState"
New-Item -ItemType Directory -Force $terminalStateDir | Out-Null
Initialize-Checkout $claudeHome
$bootstrapOutput = Invoke-PowerShellFile (Join-Path $claudeHome "setup\install.ps1") @("-SkipInstalls", "-Profile", "personal")
Write-Host ($bootstrapOutput.Output -replace "(?m)^", "    | ")

Assert-Ok "install.ps1 completes" $bootstrapOutput.Status
Assert-Match "install.ps1 reports the repo it updated" "Repo found at" $bootstrapOutput.Output
Assert-File "renders CLAUDE.md" (Join-Path $claudeHome "CLAUDE.md")
Assert-File "renders commands\commit.md" (Join-Path $claudeHome "commands\commit.md")
Assert-File "writes the profile marker" (Join-Path $claudeHome ".machine-profile")
Assert-Equals "marker records the chosen profile" "personal" (Get-Content -LiteralPath (Join-Path $claudeHome ".machine-profile") -Raw).Trim()
Assert-File "copies VSCodium settings" (Join-Path $env:APPDATA "VSCodium\User\settings.json")
Assert-File "copies VSCodium keybindings" (Join-Path $env:APPDATA "VSCodium\User\keybindings.json")
Assert-File "copies VSCodium mcp.json" (Join-Path $env:APPDATA "VSCodium\User\mcp.json")
Assert-File "copies Codex AGENTS.md" (Join-Path $env:USERPROFILE ".codex\AGENTS.md")
Assert-File "seeds the glissa config" (Join-Path $env:USERPROFILE ".glissa\config.json")
Assert-File "writes Windows Terminal settings" (Join-Path $terminalStateDir "settings.json")
Assert-NoFile "refuses to install the placeholder gitconfig" (Join-Path $env:USERPROFILE ".gitconfig")
Assert-Match "warns about the placeholder identity" "placeholder identity" $bootstrapOutput.Output
Assert-Match "stops before the install steps" "Installs skipped" $bootstrapOutput.Output
Assert-RenderedSettings (Join-Path $claudeHome "settings.json")

$commitDoc = Get-Content -LiteralPath (Join-Path $claudeHome "commands\commit.md") -Raw
Assert-NoMatch "commit.md carries no Windows-only runner assumption" "compiled-commit\\runner\.py" $commitDoc
Assert-Match "commit.md points at the portable runner path" "compiled-commit/runner\.py" $commitDoc

Phase "idempotency"

$rerunOutput = Invoke-PowerShellFile (Join-Path $claudeHome "setup\apply.ps1") @("-SkipInstalls")
Write-Host ($rerunOutput.Output -replace "(?m)^", "    | ")
Assert-Ok "second apply completes" $rerunOutput.Status
Assert-Match "second apply changes nothing" "Done in [0-9.]+s: 0 updated" $rerunOutput.Output
Assert-NoMatch "second apply installs nothing" "\[ \+\+ \]" $rerunOutput.Output
Assert-File "second apply keeps Windows Terminal settings" (Join-Path $terminalStateDir "settings.json")
Assert-NoFile "no backup on an unchanged rerun" (Join-Path $claudeHome "CLAUDE.md.pre-profile.bak")

Phase "dry run"

$beforeHash = Get-TreeHash $claudeHome
$dryRunOutput = Invoke-PowerShellFile (Join-Path $claudeHome "setup\apply.ps1") @("-DryRun")
$afterHash = Get-TreeHash $claudeHome
Assert-Ok "dry run completes" $dryRunOutput.Status
Assert-Match "dry run says it wrote nothing" "nothing written" $dryRunOutput.Output
Assert-Match "dry run lists a planned step" "vscodium-config +run" $dryRunOutput.Output
Assert-Equals "dry run leaves the tree untouched" $beforeHash $afterHash

Phase "work profile"

$workRoot = Join-Path $env:TEMP "workhome"
$workProfile = Join-Path $workRoot "profile"
$workAppData = Join-Path $workRoot "appdata"
$workLocalAppData = Join-Path $workRoot "localappdata"
New-Item -ItemType Directory -Force $workProfile, $workAppData, $workLocalAppData | Out-Null
Initialize-Checkout (Join-Path $workProfile ".claude")
$savedUserProfile = $env:USERPROFILE
$savedAppData = $env:APPDATA
$savedLocalAppData = $env:LOCALAPPDATA
$env:USERPROFILE = $workProfile
$env:APPDATA = $workAppData
$env:LOCALAPPDATA = $workLocalAppData
$workOutput = Invoke-PowerShellFile (Join-Path $workProfile ".claude\setup\apply.ps1") @("-SkipInstalls", "-Profile", "work")
$workStatus = $workOutput.Status
$workCollectOutput = Invoke-PowerShellFile (Join-Path $workProfile ".claude\setup\collect.ps1") @()
$env:USERPROFILE = $savedUserProfile
$env:APPDATA = $savedAppData
$env:LOCALAPPDATA = $savedLocalAppData
Assert-Ok "work profile apply completes" $workStatus
Assert-Match "work profile skips glissa" "glissa config.*skipped \(work profile\)" $workOutput.Output
Assert-Match "work profile skips gitconfig" "gitconfig.*skipped \(work profile\)" $workOutput.Output
Assert-Match "work profile skips the terminal step" "Windows Terminal.*skipped \(work profile\)" $workOutput.Output
Assert-NoFile "work profile writes no glissa config" (Join-Path $workProfile ".glissa\config.json")
Assert-NoFile "work profile installs no gitconfig" (Join-Path $workProfile ".gitconfig")
Assert-Ok "work profile collect completes" $workCollectOutput.Status
Assert-Match "work profile collect stops after VSCodium" "personal-profile only" $workCollectOutput.Output
Assert-Match "work profile converges retired plugins" "plugin removals\s+none present" $workOutput.Output

Phase "retired plugin teardown"

# The npm global bin dir is resolved through `npm prefix -g`, so the fixture stubs npm
# ahead of the real one on PATH. Without that, shim teardown would reach the real
# machine's npm prefix.
function Write-FakeNpm([string]$binDir, [string]$prefixDir) {
    New-Item -ItemType Directory -Force $binDir | Out-Null
    $lines = @(
        "@echo off",
        "if ""%~1""==""prefix"" (",
        "  echo $prefixDir",
        "  exit /b 0",
        ")",
        "exit /b 0"
    )
    Set-Content -LiteralPath (Join-Path $binDir "npm.cmd") -Value $lines -Encoding ascii
}

# A checkout whose profile runs only plugins-remove, so settings-render cannot rewrite
# settings.json and mask what this step did to it.
function Initialize-RetirementCheckout([string]$claudeDir) {
    Initialize-Checkout $claudeDir
    Set-Content -LiteralPath (Join-Path $claudeDir "profiles\work\profile.json") `
        -Value '{ "steps": ["plugins-remove"] }' -Encoding ascii
}

function Write-RetirementFixture([string]$claudeDir, [string]$homeDir, [string]$npmPrefix, [string]$siblingPluginId) {
    $settings = @{
        model = "claude-fable-5[1m]"
        enabledPlugins = [ordered]@{ "oh-my-claudecode@omc" = $true; "keeper@keepmarket" = $true }
        extraKnownMarketplaces = [ordered]@{
            omc = @{ source = @{ source = "git"; url = "https://example.invalid/omc.git" } }
            keepmarket = @{ source = @{ source = "github"; repo = "example/keeper" } }
        }
    }
    Set-Content -LiteralPath (Join-Path $claudeDir "settings.json") -Value ($settings | ConvertTo-Json -Depth 10) -Encoding ascii

    $pluginsDir = Join-Path $claudeDir "plugins"
    New-Item -ItemType Directory -Force $pluginsDir | Out-Null
    $installedPlugins = [ordered]@{
        "oh-my-claudecode@omc" = @(@{ scope = "user"; version = "4.15.10" })
        "keeper@keepmarket" = @(@{ scope = "user"; version = "1.0.0" })
    }
    if ($siblingPluginId) { $installedPlugins[$siblingPluginId] = @(@{ scope = "user"; version = "2.0.0" }) }
    Set-Content -LiteralPath (Join-Path $pluginsDir "installed_plugins.json") `
        -Value (@{ version = 2; plugins = $installedPlugins } | ConvertTo-Json -Depth 10) -Encoding ascii
    $marketplaces = [ordered]@{
        omc = @{ source = @{ source = "git"; url = "https://example.invalid/omc.git" } }
        keepmarket = @{ source = @{ source = "github"; repo = "example/keeper" } }
    }
    Set-Content -LiteralPath (Join-Path $pluginsDir "known_marketplaces.json") `
        -Value ($marketplaces | ConvertTo-Json -Depth 10) -Encoding ascii

    $seededDirs = @(
        (Join-Path $pluginsDir "cache\omc\oh-my-claudecode\4.15.10"),
        (Join-Path $pluginsDir "cache\omc\sibling\2.0.0"),
        (Join-Path $pluginsDir "marketplaces\omc"),
        (Join-Path $pluginsDir "data\oh-my-claudecode-omc"),
        (Join-Path $pluginsDir "oh-my-claudecode"),
        (Join-Path $pluginsDir "cache\keepmarket"),
        (Join-Path $pluginsDir "marketplaces\keepmarket"),
        (Join-Path $claudeDir ".omc"),
        (Join-Path $homeDir ".omc"),
        (Join-Path $homeDir ".keepstate")
    )
    New-Item -ItemType Directory -Force $seededDirs | Out-Null

    New-Item -ItemType Directory -Force $npmPrefix | Out-Null
    foreach ($shim in @("omc", "omc.cmd", "omc.ps1", "omc-cli", "omc-cli.cmd", "omc-cli.ps1", "glissa.cmd")) {
        Set-Content -LiteralPath (Join-Path $npmPrefix $shim) -Value "shim" -Encoding ascii
    }
}

$retireRoot = Join-Path $env:TEMP "retirehome"
$retireHome = Join-Path $retireRoot "profile"
$retireAppData = Join-Path $retireRoot "appdata"
$retireNpmPrefix = Join-Path $retireRoot "npmprefix"
$retireStubBin = Join-Path $retireRoot "stubbin"
$retireClaude = Join-Path $retireHome ".claude"
New-Item -ItemType Directory -Force $retireHome, $retireAppData | Out-Null
Initialize-RetirementCheckout $retireClaude
Write-RetirementFixture $retireClaude $retireHome $retireNpmPrefix ""
Write-FakeNpm $retireStubBin $retireNpmPrefix

$savedUserProfile = $env:USERPROFILE
$savedAppData = $env:APPDATA
$savedPath = $env:Path
$env:USERPROFILE = $retireHome
$env:APPDATA = $retireAppData
$env:Path = "$retireStubBin;$env:Path"
$retireFirst = Invoke-PowerShellFile (Join-Path $retireClaude "setup\apply.ps1") @("-SkipInstalls", "-Profile", "work")
$retireSecond = Invoke-PowerShellFile (Join-Path $retireClaude "setup\apply.ps1") @("-SkipInstalls", "-Profile", "work")
$env:USERPROFILE = $savedUserProfile
$env:APPDATA = $savedAppData
$env:Path = $savedPath

Assert-Ok "retirement apply completes" $retireFirst.Status
Assert-Match "retirement apply reports the removal" "oh-my-claudecode@omc\s+removed" $retireFirst.Output

$retiredPluginsDir = Join-Path $retireClaude "plugins"
Assert-NoFile "removes the cached marketplace plugin dir" (Join-Path $retiredPluginsDir "cache\omc")
Assert-NoFile "removes the marketplace checkout" (Join-Path $retiredPluginsDir "marketplaces\omc")
Assert-NoFile "removes the plugin data dir" (Join-Path $retiredPluginsDir "data\oh-my-claudecode-omc")
Assert-NoFile "removes the stray plugin dir" (Join-Path $retiredPluginsDir "oh-my-claudecode")
Assert-NoFile "removes the profile state dir" (Join-Path $retireClaude ".omc")
Assert-NoFile "removes the home state dir" (Join-Path $retireHome ".omc")
foreach ($shim in @("omc", "omc.cmd", "omc.ps1", "omc-cli", "omc-cli.cmd", "omc-cli.ps1")) {
    Assert-NoFile "removes the $shim npm shim" (Join-Path $retireNpmPrefix $shim)
}
Assert-Dir "keeps an unrelated cached marketplace" (Join-Path $retiredPluginsDir "cache\keepmarket")
Assert-Dir "keeps an unrelated marketplace checkout" (Join-Path $retiredPluginsDir "marketplaces\keepmarket")
Assert-Dir "keeps an unrelated state dir" (Join-Path $retireHome ".keepstate")
Assert-File "keeps an unrelated npm shim" (Join-Path $retireNpmPrefix "glissa.cmd")

$retiredSettings = Get-Content -LiteralPath (Join-Path $retireClaude "settings.json") -Raw | ConvertFrom-Json
Assert-NoMatch "strips the retired plugin from enabledPlugins" "oh-my-claudecode@omc" ($retiredSettings.enabledPlugins.PSObject.Properties.Name -join " ")
Assert-NoMatch "strips the retired marketplace from extraKnownMarketplaces" "^omc$" ($retiredSettings.extraKnownMarketplaces.PSObject.Properties.Name -join "`n")
Assert-Match "keeps an unrelated enabled plugin" "keeper@keepmarket" ($retiredSettings.enabledPlugins.PSObject.Properties.Name -join " ")
Assert-Match "keeps an unrelated marketplace" "keepmarket" ($retiredSettings.extraKnownMarketplaces.PSObject.Properties.Name -join " ")
Assert-Equals "keeps unrelated settings keys" "claude-fable-5[1m]" $retiredSettings.model

$retiredInstalled = Get-Content -LiteralPath (Join-Path $retiredPluginsDir "installed_plugins.json") -Raw | ConvertFrom-Json
Assert-NoMatch "strips the retired plugin from installed_plugins" "oh-my-claudecode@omc" ($retiredInstalled.plugins.PSObject.Properties.Name -join " ")
Assert-Match "keeps an unrelated installed plugin" "keeper@keepmarket" ($retiredInstalled.plugins.PSObject.Properties.Name -join " ")
Assert-Equals "keeps the installed_plugins schema version" "2" ([string]$retiredInstalled.version)

$retiredMarkets = Get-Content -LiteralPath (Join-Path $retiredPluginsDir "known_marketplaces.json") -Raw | ConvertFrom-Json
Assert-NoMatch "strips the retired marketplace from known_marketplaces" "^omc$" ($retiredMarkets.PSObject.Properties.Name -join "`n")
Assert-Match "keeps an unrelated known marketplace" "keepmarket" ($retiredMarkets.PSObject.Properties.Name -join " ")

Assert-Ok "second retirement apply completes" $retireSecond.Status
Assert-Match "second apply finds nothing to remove" "plugin removals\s+none present" $retireSecond.Output
Assert-NoMatch "second apply removes nothing again" "oh-my-claudecode@omc\s+removed" $retireSecond.Output
Assert-NoMatch "second apply raises no warnings" "\[warn\]" $retireSecond.Output

# A marketplace hosting a plugin that is staying must survive, registry entry included.
$siblingRoot = Join-Path $env:TEMP "retiresibling"
$siblingHome = Join-Path $siblingRoot "profile"
$siblingAppData = Join-Path $siblingRoot "appdata"
$siblingNpmPrefix = Join-Path $siblingRoot "npmprefix"
$siblingStubBin = Join-Path $siblingRoot "stubbin"
$siblingClaude = Join-Path $siblingHome ".claude"
New-Item -ItemType Directory -Force $siblingHome, $siblingAppData | Out-Null
Initialize-RetirementCheckout $siblingClaude
Write-RetirementFixture $siblingClaude $siblingHome $siblingNpmPrefix "sibling@omc"
Write-FakeNpm $siblingStubBin $siblingNpmPrefix

$savedUserProfile = $env:USERPROFILE
$savedAppData = $env:APPDATA
$savedPath = $env:Path
$env:USERPROFILE = $siblingHome
$env:APPDATA = $siblingAppData
$env:Path = "$siblingStubBin;$env:Path"
$siblingOutput = Invoke-PowerShellFile (Join-Path $siblingClaude "setup\apply.ps1") @("-SkipInstalls", "-Profile", "work")
$env:USERPROFILE = $savedUserProfile
$env:APPDATA = $savedAppData
$env:Path = $savedPath

Assert-Ok "sibling-marketplace apply completes" $siblingOutput.Status
$siblingInstalled = Get-Content -LiteralPath (Join-Path $siblingClaude "plugins\installed_plugins.json") -Raw | ConvertFrom-Json
Assert-NoMatch "still strips the retired plugin" "oh-my-claudecode@omc" ($siblingInstalled.plugins.PSObject.Properties.Name -join " ")
Assert-Match "keeps the sibling plugin on the same marketplace" "sibling@omc" ($siblingInstalled.plugins.PSObject.Properties.Name -join " ")
$siblingMarkets = Get-Content -LiteralPath (Join-Path $siblingClaude "plugins\known_marketplaces.json") -Raw | ConvertFrom-Json
Assert-Match "keeps a marketplace another plugin still needs" "omc" ($siblingMarkets.PSObject.Properties.Name -join " ")
$siblingPluginsDir = Join-Path $siblingClaude "plugins"
Assert-NoFile "removes only the retired plugin's cache entry" (Join-Path $siblingPluginsDir "cache\omc\oh-my-claudecode")
Assert-Dir "keeps the sibling plugin's cache entry" (Join-Path $siblingPluginsDir "cache\omc\sibling")
Assert-Dir "keeps the shared marketplace checkout" (Join-Path $siblingPluginsDir "marketplaces\omc")
$siblingSettings = Get-Content -LiteralPath (Join-Path $siblingClaude "settings.json") -Raw | ConvertFrom-Json
Assert-Match "keeps the shared marketplace in settings" "omc" ($siblingSettings.extraKnownMarketplaces.PSObject.Properties.Name -join " ")

Phase "collect.ps1 round trip"

$testRepo = Join-Path $env:USERPROFILE "work\testrepo"
git clone -q $originRepo $testRepo
New-Item -ItemType Directory -Force (Join-Path $env:USERPROFILE "nonrepo") | Out-Null

$codiumUser = Join-Path $env:APPDATA "VSCodium\User"
New-Item -ItemType Directory -Force $codiumUser | Out-Null
Set-Content -LiteralPath (Join-Path $codiumUser "settings.json") -Value '{"editor.fontSize": 42}' -Encoding ascii
Set-Content -LiteralPath (Join-Path $codiumUser "keybindings.json") -Value '[{"key": "ctrl+k"}]' -Encoding ascii
Set-Content -LiteralPath (Join-Path $codiumUser "mcp.json") -Value '{"servers": {}}' -Encoding ascii
Write-FakeCodium $fakeBin

$glissaConfig = [pscustomobject]@{
    projects = @(
        [pscustomobject]@{ id = "a"; path = $testRepo },
        [pscustomobject]@{ id = "b"; path = (Join-Path $env:USERPROFILE "nonrepo") }
    )
} | ConvertTo-Json -Depth 4
Set-Content -LiteralPath (Join-Path $env:USERPROFILE ".glissa\config.json") -Value $glissaConfig -Encoding ascii

$gitConfig = @(
    "[user]",
    "    name = Real Carbon Unit",
    "    email = real@example.com",
    "[alias]",
    "    name = rev-parse --abbrev-ref HEAD",
    "[core]",
    "    autocrlf = false"
)
Set-Content -LiteralPath (Join-Path $env:USERPROFILE ".gitconfig") -Value $gitConfig -Encoding ascii

$collectOutput = Invoke-PowerShellFile (Join-Path $claudeHome "setup\collect.ps1") @()
Write-Host ($collectOutput.Output -replace "(?m)^", "    | ")
Assert-Ok "collect.ps1 completes" $collectOutput.Status

Assert-Match "collects VSCodium settings" '"editor.fontSize": 42' (Get-Content -LiteralPath (Join-Path $claudeHome "setup\vscodium\settings.json") -Raw)
Assert-Equals "sorts the extension list" "vendor.first`r`nvendor.second" (Get-Content -LiteralPath (Join-Path $claudeHome "setup\vscodium\extensions.txt") -Raw).Trim()
$expectedRepoLine = ("work\testrepo={0}" -f $originRepo)
Assert-Equals "derives repos.txt from the glissa project list" $expectedRepoLine (Get-Content -LiteralPath (Join-Path $claudeHome "setup\repos.txt") -Raw).Trim()

$collectedGitConfig = Get-Content -LiteralPath (Join-Path $claudeHome "setup\git\.gitconfig") -Raw
Assert-NoMatch "scrubs the real name" "Real Carbon Unit" $collectedGitConfig
Assert-NoMatch "scrubs the real email" "real@example.com" $collectedGitConfig
Assert-Match "writes the placeholder name" "name = Your Name" $collectedGitConfig
Assert-Match "writes the placeholder email" "email = you@example.com" $collectedGitConfig
Assert-Match "leaves an alias called name alone" "name = rev-parse" $collectedGitConfig
Assert-Match "keeps unrelated sections" "autocrlf = false" $collectedGitConfig
Assert-Match "keeps the placeholder header" "before running the apply script" $collectedGitConfig

Write-FakeCodium $fakeBin -EmptyProbe
$emptyProbeOutput = Invoke-PowerShellFile (Join-Path $claudeHome "setup\collect.ps1") @()
Assert-Match "empty extension probe is still reported" "collected: extension list" $emptyProbeOutput.Output
# Set-Content with an empty pipeline is a no-op on PowerShell 5.1, so the tracked
# list survives a probe that returns nothing, matching the Linux guard.
Assert-Equals "keeps the tracked list on an empty probe" "vendor.first`r`nvendor.second" (Get-Content -LiteralPath (Join-Path $claudeHome "setup\vscodium\extensions.txt") -Raw).Trim()
Remove-Item -LiteralPath (Join-Path $fakeBin "codium.cmd") -Force

Phase "profile marker is case insensitive"

Set-Content -LiteralPath (Join-Path $claudeHome ".machine-profile") -Value "Work" -Encoding ascii
$markerOutput = Invoke-PowerShellFile (Join-Path $claudeHome "setup\apply.ps1") @("-SkipInstalls")
Assert-Match "a capitalised marker still selects the work profile" "skipped \(Work profile\)" $markerOutput.Output
$markerCollectOutput = Invoke-PowerShellFile (Join-Path $claudeHome "setup\collect.ps1") @()
Assert-Match "collect.ps1 reads the marker the same way" "personal-profile only" $markerCollectOutput.Output
Set-Content -LiteralPath (Join-Path $claudeHome ".machine-profile") -Value "personal" -Encoding ascii

if ($suiteMode -eq "full") {
    Phase "full apply (installs enabled)"

    git -C $claudeHome checkout -q -- setup\vscodium setup\git
    Set-Content -LiteralPath (Join-Path $claudeHome "setup\repos.txt") -Value ("work\clonedrepo={0}" -f $originRepo) -Encoding ascii

    $fullOutput = Invoke-PowerShellFile (Join-Path $claudeHome "setup\apply.ps1") @()
    Write-Host ($fullOutput.Output -replace "(?m)^", "    | ")
    Assert-Ok "full apply completes" $fullOutput.Status

    $env:Path = "$env:APPDATA\npm;$env:Path"
    Assert-Ok "installs node" (Test-CommandPresent "node")
    Assert-Ok "installs npm" (Test-CommandPresent "npm")
    Assert-RenderedSettings (Join-Path $claudeHome "settings.json")
    Assert-File "clones the repo listed in repos.txt" (Join-Path $env:USERPROFILE "work\clonedrepo\.git\config")
    Assert-Equals "creates develop in the cloned repo" "develop" (git -C (Join-Path $env:USERPROFILE "work\clonedrepo") rev-parse --abbrev-ref develop 2>$null)
    Assert-File "installs the fonts" (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts\CommitMono-400-Regular.otf")
    Assert-NoMatch "biome never reports installed and failed together" "biome +npm install failed" $fullOutput.Output

    $npmGlobalList = npm ls -g --depth=0 --parseable 2>$null | Out-String
    Assert-Match "installs the tracked npm globals" "node_modules[\\/]typescript" $npmGlobalList
    Assert-NoMatch "no npm package is reported as a plain failure" "npm install failed" $fullOutput.Output

    python -m pip --version 2>$null | Out-Null
    Assert-Ok "installs pip alongside python" $LASTEXITCODE
    python -c "import ruff" 2>$null
    Assert-Ok "installs ruff for the python gate" $LASTEXITCODE
    python -c "import yaml" 2>$null
    Assert-Ok "installs pyyaml" $LASTEXITCODE

    Phase "full apply is idempotent"

    $secondFullOutput = Invoke-PowerShellFile (Join-Path $claudeHome "setup\apply.ps1") @()
    Assert-Ok "second full apply completes" $secondFullOutput.Status
    Assert-Match "second full apply installs nothing" "Done in [0-9.]+s: 0 updated, 0 installed" $secondFullOutput.Output
}

Phase "validate-file hook"

$hookScript = Join-Path $claudeHome "hooks\validate-file.mjs"
node --check $hookScript
Assert-Ok "hook parses" $LASTEXITCODE

$goodJson = '{"tool_name":"Write","tool_input":{"file_path":"a.json","content":"{\"a\":1}"}}'
$badJson = '{"tool_name":"Write","tool_input":{"file_path":"a.json","content":"{bad}"}}'
$jsonc = '{"tool_name":"Write","tool_input":{"file_path":"tsconfig.json","content":"{\n  // comment\n  \"compilerOptions\": {}\n}"}}'
$longDashChar = [string][char]0x2014
$dashed = "{""tool_name"":""Write"",""tool_input"":{""file_path"":""a.md"",""content"":""one $longDashChar two""}}"

Assert-Equals "valid JSON is allowed" "" (Invoke-NodeWithInput $hookScript $goodJson).Output
Assert-Equals "JSONC in tsconfig.json is allowed" "" (Invoke-NodeWithInput $hookScript $jsonc).Output
Assert-Match "invalid JSON is denied" '"permissionDecision":\s*"deny"' (Invoke-NodeWithInput $hookScript $badJson).Output
Assert-Match "a long dash is denied" '"permissionDecision":\s*"deny"' (Invoke-NodeWithInput $hookScript $dashed).Output

$emojiChar = [string][char]0x2705
$emojiWrite = "{""tool_name"":""Write"",""tool_input"":{""file_path"":""a.md"",""content"":""one $emojiChar two""}}"
Assert-Match "a new emoji is denied" '"permissionDecision":\s*"deny"' (Invoke-NodeWithInput $hookScript $emojiWrite).Output

$oversized = "y" * 20000
$grownPath = (Join-Path ([System.IO.Path]::GetTempPath()) "absent-dir/AGENTS.md").Replace('\', '/')
$grown = "{""tool_name"":""Write"",""tool_input"":{""file_path"":""$grownPath"",""content"":""$oversized""}}"
Assert-Match "growing AGENTS.md past its cap is denied" '"permissionDecision":\s*"deny"' (Invoke-NodeWithInput $hookScript $grown).Output

# Runs in both modes: the runner hands the hook the real npm global root, so the
# biome and ruff engines are reachable from a host sandbox run too.
$goodTs = '{"tool_name":"Write","tool_input":{"file_path":"a.ts","content":"const value: number = 1;"}}'
$badTs = '{"tool_name":"Write","tool_input":{"file_path":"a.ts","content":"const value: number = ;"}}'
$goodPy = '{"tool_name":"Write","tool_input":{"file_path":"a.py","content":"def f():\n    return 1\n"}}'
$badPy = '{"tool_name":"Write","tool_input":{"file_path":"a.py","content":"def f(:\n"}}'
Assert-Equals "valid TS is allowed" "" (Invoke-NodeWithInput $hookScript $goodTs).Output
$badTsResult = (Invoke-NodeWithInput $hookScript $badTs).Output
Assert-Match "invalid TS is denied" '"permissionDecision":\s*"deny"' $badTsResult
Assert-Match "the TS denial locates the error" "line 1, column" $badTsResult
Assert-Equals "valid Python is allowed" "" (Invoke-NodeWithInput $hookScript $goodPy).Output
$badPyResult = (Invoke-NodeWithInput $hookScript $badPy).Output
Assert-Match "invalid Python is denied" '"permissionDecision":\s*"deny"' $badPyResult
Assert-Match "the Python denial locates the error" "line 1" $badPyResult

Write-Host ""
Write-Host ("{0} passed, {1} failed ({2} mode)" -f $passCount, $failCount, $suiteMode)
if ($failCount -gt 0) {
    exit 1
}
exit 0
