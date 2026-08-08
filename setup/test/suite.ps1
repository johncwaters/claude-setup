$suiteMode = "fast"
if ($env:SUITE_MODE) { $suiteMode = $env:SUITE_MODE }
$originRepo = "C:\origin.git"
if ($env:CLAUDE_SETUP_TEST_ORIGIN) { $originRepo = $env:CLAUDE_SETUP_TEST_ORIGIN }
$sourceRepo = "C:\suite\src"
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
Assert-Status "install.ps1 rejects an unknown flag" 1 $unknownInstallOutput.Status

$missingProfileOutput = Invoke-PowerShellFile (Join-Path $sourceRepo "setup\apply.ps1") @("-Profile")
Assert-Status "apply.ps1 rejects a valueless -Profile" 1 $missingProfileOutput.Status

$nonInteractiveOutput = Invoke-PowerShellFile (Join-Path $sourceRepo "setup\apply.ps1") @("-SkipInstalls")
Assert-Status "apply.ps1 refuses to guess a profile without a redirected host" 1 $nonInteractiveOutput.Status
Assert-Match "apply.ps1 says how to supply the profile" "Re-run with -Profile" $nonInteractiveOutput.Output

$collectUnknownOutput = Invoke-PowerShellFile (Join-Path $sourceRepo "setup\collect.ps1") @("-Nonsense")
Assert-Status "collect.ps1 rejects an unknown flag" 2 $collectUnknownOutput.Status

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
