# Apply repo config to this machine. Run directly or via install.ps1.
param([switch]$SkipInstalls)
$ErrorActionPreference = "Stop"
$setupDir = $PSScriptRoot
$counts = @{ applied = 0; installed = 0; present = 0; warned = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Write-Section([string]$title) {
    Write-Host ""
    Write-Host "  $title" -ForegroundColor Cyan
}
function Write-Line([string]$mark, [ConsoleColor]$color, [string]$label, [string]$note) {
    Write-Host "    [$mark] " -ForegroundColor $color -NoNewline
    Write-Host ("{0,-26}" -f $label) -NoNewline
    Write-Host " $note" -ForegroundColor DarkGray
}
function Note-Applied([string]$label, [string]$note)   { Write-Line " ok " Green    $label $note; $counts.applied++ }
function Note-Installed([string]$label, [string]$note) { Write-Line " ++ " Yellow   $label $note; $counts.installed++ }
function Note-Present([string]$label, [string]$note)   { Write-Line " -- " DarkGray $label $note; $counts.present++ }
function Note-Warned([string]$label, [string]$note)    { Write-Line "warn" Red      $label $note; $counts.warned++ }

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User") + ";" + $env:Path
}

function Copy-Config([string]$label, [string]$src, [string]$dest) {
    if (-not (Test-Path $src)) { Note-Warned $label "not in repo"; return }
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
    if ((Test-Path $dest) -and ((Get-FileHash $src).Hash -eq (Get-FileHash $dest).Hash)) {
        Note-Present $label "up to date"
        return
    }
    Copy-Item $src $dest -Force
    Note-Applied $label "updated"
}

function Install-WingetTool([string]$label, [string]$cmd, [string]$id) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) { Note-Present $label "already installed"; return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Note-Warned $label "winget missing, install manually"; return }
    Write-Line " .. " Yellow $label "installing via winget"
    winget install --id $id -e --silent --accept-source-agreements --accept-package-agreements | Out-Null
    Update-SessionPath
    if (Get-Command $cmd -ErrorAction SilentlyContinue) { Note-Installed $label "installed"; return }
    Note-Warned $label "installed, but open a new shell for PATH"
}

Write-Section "Config"
$codiumUser = Join-Path $env:APPDATA "VSCodium\User"
Copy-Config "VSCodium settings"    (Join-Path $setupDir "vscodium\settings.json")    (Join-Path $codiumUser "settings.json")
Copy-Config "VSCodium keybindings" (Join-Path $setupDir "vscodium\keybindings.json") (Join-Path $codiumUser "keybindings.json")
Copy-Config "VSCodium mcp.json"    (Join-Path $setupDir "vscodium\mcp.json")         (Join-Path $codiumUser "mcp.json")
Copy-Config "glissa config"        (Join-Path $setupDir "glissa\config.json")        (Join-Path $env:USERPROFILE ".glissa\config.json")
Copy-Config "gitconfig"            (Join-Path $setupDir "git\.gitconfig")            (Join-Path $env:USERPROFILE ".gitconfig")
$wtDir = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState"
if (Test-Path $wtDir) { Copy-Config "Windows Terminal" (Join-Path $setupDir "terminal\settings.json") (Join-Path $wtDir "settings.json") }
if (-not (Test-Path $wtDir)) { Note-Warned "Windows Terminal" "not installed, skipping settings" }

if ($SkipInstalls) {
    Write-Host ""
    Write-Host ("  Done in {0}s: {1} updated, {2} up to date, {3} warnings. Installs skipped." -f `
        [math]::Round($sw.Elapsed.TotalSeconds, 1), $counts.applied, $counts.present, $counts.warned) -ForegroundColor Cyan
    return
}

Write-Section "Tools"
Install-WingetTool "git"      "git"    "Git.Git"
Install-WingetTool "GitHub CLI" "gh"   "GitHub.cli"
Install-WingetTool "Node.js"  "node"   "OpenJS.NodeJS"
Install-WingetTool "VSCodium" "codium" "VSCodium.VSCodium"
if (Get-Command claude -ErrorAction SilentlyContinue) { Note-Present "Claude Code" "already installed" }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Line " .. " Yellow "Claude Code" "running native installer"
    $null = Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
    Update-SessionPath
    if (Get-Command claude -ErrorAction SilentlyContinue) { Note-Installed "Claude Code" "installed" }
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Note-Warned "Claude Code" "not on PATH yet, open a new shell" }
}

Write-Section "Fonts"
$fontDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
$fontReg = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
New-Item -ItemType Directory -Force $fontDir | Out-Null
foreach ($font in (Get-ChildItem (Join-Path $setupDir "fonts") -File -ErrorAction SilentlyContinue)) {
    $target = Join-Path $fontDir $font.Name
    if (Test-Path $target) { Note-Present $font.BaseName "installed"; continue }
    Copy-Item $font.FullName $target
    New-ItemProperty -Path $fontReg -Name "$($font.BaseName) (OpenType)" -Value $target -PropertyType String -Force | Out-Null
    Note-Installed $font.BaseName "installed"
}

# glissa requires a develop branch in every project repo
function Sync-DevelopBranch([string]$label, [string]$dest) {
    git -C $dest rev-parse --verify -q refs/heads/develop | Out-Null
    $hasLocal = $LASTEXITCODE -eq 0
    git -C $dest rev-parse --verify -q refs/remotes/origin/develop | Out-Null
    $hasRemote = $LASTEXITCODE -eq 0
    if (-not $hasLocal -and $hasRemote) {
        git -C $dest branch -q --track develop origin/develop
        Note-Installed "$label develop" "tracking origin/develop"
        return
    }
    if (-not $hasLocal) {
        git -C $dest branch -q develop
        git -C $dest push -q -u origin develop
        if ($LASTEXITCODE -ne 0) { Note-Warned "$label develop" "created locally, push failed"; return }
        Note-Installed "$label develop" "created and pushed"
        return
    }
    if (-not $hasRemote) {
        git -C $dest push -q -u origin develop
        if ($LASTEXITCODE -ne 0) { Note-Warned "$label develop" "local only, push failed"; return }
        Note-Applied "$label develop" "pushed to origin"
        return
    }
    if ((git -C $dest symbolic-ref --short -q HEAD) -eq "develop") { return }
    git -C $dest fetch -q origin develop:develop
    if ($LASTEXITCODE -ne 0) { Note-Warned "$label develop" "diverged from origin, resolve manually" }
}

# repos fail at runtime without this: missing node_modules after clone, missing new
# deps after pull ("Cannot find module 'sharp'"), and a missing electron binary
# ("Electron uninstall") when electron's postinstall was skipped or interrupted
function Install-RepoDeps([string]$label, [string]$dest) {
    if (-not (Test-Path (Join-Path $dest "package.json"))) { return }
    $mgr = "npm"
    if (Test-Path (Join-Path $dest "pnpm-lock.yaml")) { $mgr = "pnpm" }
    if (Test-Path (Join-Path $dest "yarn.lock")) { $mgr = "yarn" }
    # invoke the .cmd shim: npm.ps1 rebuilds args from the raw invocation line, which
    # mangles variable command names and splatted args
    $mgrCmd = Get-Command "$mgr.cmd" -ErrorAction SilentlyContinue
    if (-not $mgrCmd) { $mgrCmd = Get-Command $mgr -ErrorAction SilentlyContinue }
    if (-not $mgrCmd) { Note-Warned "$label deps" "$mgr not on PATH"; return }
    $installArgs = @{
        npm  = @("install", "--no-audit", "--no-fund", "--loglevel=error")
        pnpm = @("install", "--reporter=silent")
        yarn = @("install", "--silent")
    }[$mgr]
    Write-Line " .. " Yellow "$label deps" "$mgr install"
    Push-Location $dest
    & $mgrCmd.Source @installArgs | Out-Null
    $installOk = $LASTEXITCODE -eq 0
    Pop-Location
    if (-not $installOk) { Note-Warned "$label deps" "$mgr install failed"; return }
    Note-Present "$label deps" "installed"

    $electronDir = Join-Path $dest "node_modules\electron"
    if (-not (Test-Path $electronDir)) { return }
    if (Test-Path (Join-Path $electronDir "dist\electron.exe")) { return }
    Write-Line " .. " Yellow "$label electron" "downloading binary"
    node (Join-Path $electronDir "install.js") | Out-Null
    if (Test-Path (Join-Path $electronDir "dist\electron.exe")) { Note-Installed "$label electron" "binary installed"; return }
    Note-Warned "$label electron" "binary download failed, run: node node_modules/electron/install.js"
}

Write-Section "Repos"
$repoFile = Join-Path $setupDir "repos.txt"
if (-not (Test-Path $repoFile)) { Note-Warned "repos" "repos.txt not in repo" }
if ((Test-Path $repoFile) -and (Get-Command git -ErrorAction SilentlyContinue)) {
    foreach ($line in (Get-Content $repoFile | Where-Object { $_ -match "=" })) {
        $rel, $url = $line -split "=", 2
        $dest = Join-Path $env:USERPROFILE $rel.Trim()
        $label = Split-Path $dest -Leaf
        if (-not (Test-Path $dest)) {
            Write-Line " .. " Yellow $label "cloning"
            git clone -q $url.Trim() $dest
            if ($LASTEXITCODE -ne 0) { Note-Warned $label "clone failed"; continue }
            Note-Installed $label "cloned"
            Sync-DevelopBranch $label $dest
            Install-RepoDeps $label $dest
            continue
        }
        if (-not (Test-Path (Join-Path $dest ".git"))) { Note-Warned $label "exists but is not a git repo"; continue }
        git -C $dest pull --ff-only -q
        if ($LASTEXITCODE -ne 0) { Note-Warned $label "pull failed (dirty or diverged), resolve manually"; continue }
        Note-Present $label "synced"
        Sync-DevelopBranch $label $dest
        Install-RepoDeps $label $dest
    }
}

Write-Section "npm globals"
$npmGlobals = Join-Path $setupDir "npm-globals.txt"
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { Note-Warned "npm" "not on PATH, skipping packages" }
if ((Test-Path $npmGlobals) -and (Get-Command npm -ErrorAction SilentlyContinue)) {
    $wanted = Get-Content $npmGlobals | Where-Object { $_ }
    $have = npm ls -g --depth=0 --parseable 2>$null |
        Where-Object { $_ -match "node_modules" } |
        ForEach-Object { ($_ -replace ".*node_modules[\\/]", "") -replace "\\", "/" }
    $missing = @($wanted | Where-Object { $have -notcontains $_ })
    if ($missing.Count -eq 0) { Note-Present "packages" "all $($wanted.Count) present" }
    foreach ($pkg in $missing) {
        Write-Line " .. " Yellow $pkg "npm install -g"
        npm install -g $pkg --loglevel=error | Out-Null
        if ($LASTEXITCODE -eq 0) { Note-Installed $pkg "installed"; continue }
        Note-Warned $pkg "npm install failed"
    }
}

# retired tools (e.g. oh-my-claude-sisyphus) are uninstalled on sync so machines converge
$npmRemovals = Join-Path $setupDir "npm-globals-remove.txt"
if ((Test-Path $npmRemovals) -and (Get-Command npm -ErrorAction SilentlyContinue)) {
    $unwanted = Get-Content $npmRemovals | Where-Object { $_ }
    $installed = npm ls -g --depth=0 --parseable 2>$null |
        Where-Object { $_ -match "node_modules" } |
        ForEach-Object { ($_ -replace ".*node_modules[\\/]", "") -replace "\\", "/" }
    $present = @($unwanted | Where-Object { $installed -contains $_ })
    if ($present.Count -eq 0) { Note-Present "npm removals" "none present" }
    foreach ($pkg in $present) {
        Write-Line " .. " Yellow $pkg "npm uninstall -g"
        npm uninstall -g $pkg --loglevel=error | Out-Null
        if ($LASTEXITCODE -eq 0) { Note-Applied $pkg "removed"; continue }
        Note-Warned $pkg "npm uninstall failed"
    }
}

# validate-file hook's python gate needs ruff; the release skill's linter needs pyyaml
Write-Section "Python tools"
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { Note-Warned "python" "not on PATH, skipping pip tools" }
if (Get-Command python -ErrorAction SilentlyContinue) {
    foreach ($mod in @("ruff", "yaml")) {
        $pkg = @{ ruff = "ruff"; yaml = "pyyaml" }[$mod]
        # cmd owns the redirects: under EAP=Stop, PS 5.1 turns native stderr into a terminating NativeCommandError
        cmd /c "python -c ""import $mod"" >nul 2>&1"
        if ($LASTEXITCODE -eq 0) { Note-Present $pkg "already installed"; continue }
        Write-Line " .. " Yellow $pkg "pip install"
        cmd /c "python -m pip install $pkg --quiet >nul 2>&1"
        if ($LASTEXITCODE -eq 0) { Note-Installed $pkg "installed"; continue }
        Note-Warned $pkg "pip install failed"
    }
}

Write-Section "VSCodium extensions"
$extFile = Join-Path $setupDir "vscodium\extensions.txt"
if (-not (Get-Command codium -ErrorAction SilentlyContinue)) { Note-Warned "codium" "not on PATH, skipping extensions" }
if ((Test-Path $extFile) -and (Get-Command codium -ErrorAction SilentlyContinue)) {
    $wanted = Get-Content $extFile | Where-Object { $_ }
    $have = codium --list-extensions
    $missing = @($wanted | Where-Object { $have -notcontains $_ })
    $extra = @($have | Where-Object { $wanted -notcontains $_ })
    if ($missing.Count -eq 0 -and $extra.Count -eq 0) { Note-Present "extensions" "all $($wanted.Count) in sync" }
    foreach ($ext in $missing) {
        Write-Line " .. " Yellow $ext "installing"
        codium --install-extension $ext | Out-Null
        if ($LASTEXITCODE -eq 0) { Note-Installed $ext "installed"; continue }
        Note-Warned $ext "install failed"
    }
    foreach ($ext in $extra) {
        Write-Line " .. " Yellow $ext "uninstalling (not in extensions.txt)"
        codium --uninstall-extension $ext | Out-Null
        if ($LASTEXITCODE -eq 0) { Note-Applied $ext "removed"; continue }
        Note-Warned $ext "uninstall failed"
    }
}

Write-Host ""
$summaryColor = "Cyan"
if ($counts.warned -gt 0) { $summaryColor = "Yellow" }
Write-Host ("  Done in {0}s: {1} updated, {2} installed, {3} up to date, {4} warnings." -f `
    [math]::Round($sw.Elapsed.TotalSeconds, 1), $counts.applied, $counts.installed, $counts.present, $counts.warned) -ForegroundColor $summaryColor
