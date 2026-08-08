# Apply repo config to this machine. Run directly or via install.ps1.
param([switch]$SkipInstalls, [ValidateSet("personal","work")][string]$Profile, [switch]$DryRun, [switch]$Help)
$ErrorActionPreference = "Stop"

function Write-Usage {
    Write-Host "Usage: setup/apply.ps1 [-SkipInstalls] [-Profile personal|work] [-DryRun]"
    Write-Host ""
    Write-Host "Apply repo config to this machine."
}

# A script param block leaves unbound arguments in $args instead of failing, so without
# this a mistyped flag would apply the whole profile anyway. --help is accepted alongside
# -Help because the README documents the same flag for apply.sh.
if ($Help -or ($args -contains "--help")) { Write-Usage; exit 0 }
if ($args.Count -gt 0) {
    Write-Host "apply.ps1: unknown option: $($args -join ' ')"
    Write-Usage
    exit 2
}

$setupDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $setupDir
$counts = @{ applied = 0; installed = 0; present = 0; warned = 0 }
$retrySettingsRender = $false
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
function Note-Skipped([string]$label) { Write-Line " -- " DarkGray $label "skipped ($Profile profile)" }
function Step-Enabled([string]$name) { return $steps -contains $name }

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

# Back up a soon-to-be-overwritten rendered file the first time a machine adopts a
# profile (no marker yet), but only when the destination content would actually change.
function Backup-IfFirstRun([string]$dest, [string]$src) {
    if ($markerExisted) { return }
    if (-not (Test-Path $dest)) { return }
    if (-not (Test-Path $src)) { return }
    if ((Get-FileHash $src).Hash -eq (Get-FileHash $dest).Hash) { return }
    Copy-Item $dest "$dest.pre-profile.bak" -Force
    Note-Applied ("{0} backup" -f (Split-Path $dest -Leaf)) "saved .pre-profile.bak"
}

# Render settings.json from the shared base plus the profile overlay. Only reports
# Applied when the file content actually changed. Defers with a retry flag when node
# is not yet on PATH (it may be installed later in this same run).
function Invoke-SettingsRender {
    $base    = Join-Path $repoRoot "settings.base.json"
    $overlay = Join-Path $repoRoot "profiles\$Profile\settings.overlay.json"
    $dest    = Join-Path $repoRoot "settings.json"
    $render  = Join-Path $setupDir "render-settings.mjs"
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Note-Warned "settings.json" "node not on PATH, will retry after installs"
        $script:retrySettingsRender = $true
        return
    }
    $script:retrySettingsRender = $false
    $existed = Test-Path $dest
    $preHash = $null
    if ($existed) { $preHash = (Get-FileHash $dest).Hash }
    $madeBackup = $false
    if ((-not $markerExisted) -and $existed) {
        Copy-Item $dest "$dest.pre-profile.bak" -Force
        $madeBackup = $true
    }
    # cmd owns the stderr redirect: under EAP=Stop, PS 5.1 turns native stderr into a terminating NativeCommandError
    $renderErr = Join-Path $env:TEMP "claude-settings-render.err"
    cmd /c "node ""$render"" ""$base"" ""$overlay"" ""$dest"" 2>""$renderErr"""
    if ($LASTEXITCODE -ne 0) {
        if ($madeBackup) { Remove-Item "$dest.pre-profile.bak" -Force }
        $note = "render failed"
        $firstErrLine = $null
        if (Test-Path $renderErr) { $firstErrLine = Get-Content $renderErr -TotalCount 1 }
        if ($firstErrLine) { $note = "render failed: $firstErrLine" }
        Remove-Item $renderErr -Force -ErrorAction SilentlyContinue
        Note-Warned "settings.json" $note
        return
    }
    Remove-Item $renderErr -Force -ErrorAction SilentlyContinue
    $postHash = $null
    if (Test-Path $dest) { $postHash = (Get-FileHash $dest).Hash }
    $changed = $preHash -ne $postHash
    if ($madeBackup -and (-not $changed)) {
        Remove-Item "$dest.pre-profile.bak" -Force
        $madeBackup = $false
    }
    if ($madeBackup) { Note-Applied "settings.json backup" "saved .pre-profile.bak" }
    if ($changed) { Note-Applied "settings.json" "rendered"; return }
    Note-Present "settings.json" "up to date"
}

$markerPath = Join-Path $repoRoot ".machine-profile"
$markerExisted = Test-Path $markerPath

# Profile resolution: explicit param wins, then the marker file, then an interactive prompt.
$writeMarker = $false
if ($Profile) {
    $writeMarker = $true
}
if ((-not $Profile) -and $markerExisted) {
    $fromMarker = (Get-Content $markerPath -Raw).Trim()
    if ($fromMarker -eq "personal" -or $fromMarker -eq "work") { $Profile = $fromMarker }
    if (-not $Profile) { Write-Host "  .machine-profile has invalid content, ignoring" -ForegroundColor Yellow }
}
while (-not $Profile) {
    try {
        $answer = (Read-Host "Machine profile (personal/work)").Trim()
    } catch {
        throw "Cannot prompt for a machine profile on a non-interactive host. Re-run with -Profile personal or -Profile work."
    }
    if ($answer -eq "personal" -or $answer -eq "work") { $Profile = $answer; $writeMarker = $true }
    if (-not $Profile) { Write-Host "  Enter 'personal' or 'work'." -ForegroundColor Yellow }
}

$profileJsonPath = Join-Path $repoRoot "profiles\$Profile\profile.json"
if (-not (Test-Path $profileJsonPath)) { throw "Profile definition not found: $profileJsonPath" }
try {
    $profileJson = Get-Content $profileJsonPath -Raw | ConvertFrom-Json
} catch {
    throw "Cannot read profile definition ${profileJsonPath}: $($_.Exception.Message)"
}
$steps = @($profileJson.steps)

# Full step catalog in execution order, for the dry-run plan.
$knownSteps = @(
    "vscodium-config", "glissa", "gitconfig", "codex-agents", "terminal",
    "workflow-config", "settings-render", "software", "fonts", "biome",
    "repos", "npm-globals", "python-tools", "vscodium-extensions"
)

if ($DryRun) {
    Write-Section "Dry run"
    Write-Host ("    profile: {0}" -f $Profile) -ForegroundColor Cyan
    foreach ($s in $knownSteps) {
        $state = "skip"
        if (Step-Enabled $s) { $state = "run" }
        Write-Line " -- " DarkGray $s $state
        if ($s -eq "workflow-config") {
            Write-Host ("        CLAUDE.md: {0} -> {1}" -f (Join-Path $repoRoot "profiles\$Profile\CLAUDE.md"), (Join-Path $repoRoot "CLAUDE.md")) -ForegroundColor DarkGray
            Write-Host ("        commit.md: {0} -> {1}" -f (Join-Path $repoRoot "profiles\$Profile\commit.md"), (Join-Path $repoRoot "commands\commit.md")) -ForegroundColor DarkGray
        }
        if ($s -eq "settings-render") {
            Write-Host ("        {0} + {1} -> {2}" -f (Join-Path $repoRoot "settings.base.json"), (Join-Path $repoRoot "profiles\$Profile\settings.overlay.json"), (Join-Path $repoRoot "settings.json")) -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "  Dry run only, nothing written." -ForegroundColor Cyan
    exit 0
}

if ($writeMarker) { Set-Content -Path $markerPath -Value $Profile -Encoding ascii }

Write-Section "Config"
if (Step-Enabled "vscodium-config") {
    $codiumUser = Join-Path $env:APPDATA "VSCodium\User"
    Copy-Config "VSCodium settings"    (Join-Path $setupDir "vscodium\settings.json")    (Join-Path $codiumUser "settings.json")
    Copy-Config "VSCodium keybindings" (Join-Path $setupDir "vscodium\keybindings.json") (Join-Path $codiumUser "keybindings.json")
    Copy-Config "VSCodium mcp.json"    (Join-Path $setupDir "vscodium\mcp.json")         (Join-Path $codiumUser "mcp.json")
}
if (-not (Step-Enabled "vscodium-config")) { Note-Skipped "VSCodium config" }
if (Step-Enabled "glissa") {
    # Seed only: ~/.glissa/config.json holds live runtime state (projects, resume ids) that
    # glissa hot-reloads on change; overwriting it kills sessions for projects added since
    # the repo snapshot. Copy only to bootstrap a fresh machine.
    $glissaDest = Join-Path $env:USERPROFILE ".glissa\config.json"
    $glissaExists = Test-Path $glissaDest
    if ($glissaExists) { Note-Present "glissa config" "exists, runtime state kept" }
    if (-not $glissaExists) {
        # config.json is gitignored (it holds live project ids and absolute paths), so a
        # fresh clone seeds from the tracked example and the user edits the paths after.
        $glissaSrc = Join-Path $setupDir "glissa\config.json"
        if (-not (Test-Path $glissaSrc)) {
            $glissaSrc = Join-Path $setupDir "glissa\config.example.json"
            Note-Warned "glissa config" "no config.json, seeding from config.example.json (edit project paths)"
        }
        Copy-Config "glissa config" $glissaSrc $glissaDest
    }
}
if (-not (Step-Enabled "glissa")) { Note-Skipped "glissa config" }
if (Step-Enabled "gitconfig") {
    # The tracked gitconfig ships a placeholder identity so a fresh clone cannot make
    # someone commit under the repo owner's name. Refuse to install it until it is edited.
    $gitConfigSrc = Join-Path $setupDir "git\.gitconfig"
    $gitConfigIsPlaceholder = $false
    if (Test-Path $gitConfigSrc) {
        $gitConfigText = Get-Content $gitConfigSrc -Raw
        if ($gitConfigText -match "you@example\.com" -or $gitConfigText -match "Your Name") { $gitConfigIsPlaceholder = $true }
    }
    if ($gitConfigIsPlaceholder) { Note-Warned "gitconfig" "placeholder identity, edit setup/git/.gitconfig first" }
    if (-not $gitConfigIsPlaceholder) {
        Copy-Config "gitconfig"        $gitConfigSrc                                     (Join-Path $env:USERPROFILE ".gitconfig")
    }
}
if (-not (Step-Enabled "gitconfig")) { Note-Skipped "gitconfig" }
if (Step-Enabled "codex-agents") {
    Copy-Config "Codex AGENTS.md"      (Join-Path $setupDir "..\AGENTS.md")              (Join-Path $env:USERPROFILE ".codex\AGENTS.md")
}
if (-not (Step-Enabled "codex-agents")) { Note-Skipped "Codex AGENTS.md" }
if (Step-Enabled "terminal") {
    $wtDir = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState"
    if (Test-Path $wtDir) { Copy-Config "Windows Terminal" (Join-Path $setupDir "terminal\settings.json") (Join-Path $wtDir "settings.json") }
    if (-not (Test-Path $wtDir)) { Note-Warned "Windows Terminal" "not installed, skipping settings" }
}
if (-not (Step-Enabled "terminal")) { Note-Skipped "Windows Terminal" }

Write-Section "Workflow"
if (Step-Enabled "workflow-config") {
    $claudeSrc  = Join-Path $repoRoot "profiles\$Profile\CLAUDE.md"
    $claudeDest = Join-Path $repoRoot "CLAUDE.md"
    Backup-IfFirstRun $claudeDest $claudeSrc
    Copy-Config "CLAUDE.md" $claudeSrc $claudeDest
    $commitSrc  = Join-Path $repoRoot "profiles\$Profile\commit.md"
    $commitDest = Join-Path $repoRoot "commands\commit.md"
    Backup-IfFirstRun $commitDest $commitSrc
    Copy-Config "commit.md" $commitSrc $commitDest
}
if (-not (Step-Enabled "workflow-config")) { Note-Skipped "workflow config" }
if (Step-Enabled "settings-render") { Invoke-SettingsRender }
if (-not (Step-Enabled "settings-render")) { Note-Skipped "settings.json" }

if ($SkipInstalls) {
    Write-Host ""
    Write-Host ("  Done in {0}s: {1} updated, {2} up to date, {3} warnings. Installs skipped." -f `
        [math]::Round($sw.Elapsed.TotalSeconds, 1), $counts.applied, $counts.present, $counts.warned) -ForegroundColor Cyan
    return
}

Write-Section "Tools"
if (-not (Step-Enabled "software")) { Note-Skipped "Tools" }
if (Step-Enabled "software") {
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
}

# node may have just been installed above; retry a settings render that was deferred
if ($retrySettingsRender) { Invoke-SettingsRender }

Write-Section "Fonts"
if (-not (Step-Enabled "fonts")) { Note-Skipped "Fonts" }
if (Step-Enabled "fonts") {
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
}

Write-Section "Hook deps"
if (-not (Step-Enabled "biome")) { Note-Skipped "biome" }
if (Step-Enabled "biome") {
    if (Get-Command biome -ErrorAction SilentlyContinue) { Note-Present "biome" "already installed" }
    if (-not (Get-Command biome -ErrorAction SilentlyContinue)) {
        if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { Note-Warned "biome" "npm not on PATH" }
        if (Get-Command npm -ErrorAction SilentlyContinue) {
            Write-Line " .. " Yellow "biome" "npm install -g @biomejs/biome"
            npm install -g @biomejs/biome --loglevel=error | Out-Null
            if ($LASTEXITCODE -eq 0) { Note-Installed "biome" "installed" }
            if ($LASTEXITCODE -ne 0) { Note-Warned "biome" "npm install failed" }
        }
    }
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
if (-not (Step-Enabled "repos")) { Note-Skipped "Repos" }
if (Step-Enabled "repos") {
    # repos.txt is gitignored (private clone urls), so a fresh clone falls back to the
    # tracked example, which lists only public repos.
    $repoFile = Join-Path $setupDir "repos.txt"
    if (-not (Test-Path $repoFile)) {
        $repoFile = Join-Path $setupDir "repos.example.txt"
        if (Test-Path $repoFile) { Note-Warned "repos" "no repos.txt, using repos.example.txt" }
    }
    if (-not (Test-Path $repoFile)) { Note-Warned "repos" "no repos.txt or repos.example.txt" }
    if ((Test-Path $repoFile) -and (Get-Command git -ErrorAction SilentlyContinue)) {
        foreach ($line in (Get-Content $repoFile | Where-Object { $_ -match "=" -and $_ -notmatch "^\s*#" })) {
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
}

Write-Section "npm globals"
if (-not (Step-Enabled "npm-globals")) { Note-Skipped "npm globals" }
if (Step-Enabled "npm-globals") {
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
}

# validate-file hook's python gate needs ruff; the release skill's linter needs pyyaml
Write-Section "Python tools"
if (-not (Step-Enabled "python-tools")) { Note-Skipped "Python tools" }
if (Step-Enabled "python-tools") {
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) { Note-Warned "python" "not on PATH, skipping pip tools" }
    if (Get-Command python -ErrorAction SilentlyContinue) {
        foreach ($mod in @("ruff", "yaml")) {
            $pkg = @{ ruff = "ruff"; yaml = "pyyaml" }[$mod]
            # cmd owns the redirects: under EAP=Stop, PS 5.1 turns native stderr into a terminating NativeCommandError
            cmd /c "python -c ""import $mod"" >nul 2>&1"
            if ($LASTEXITCODE -eq 0) { Note-Present $pkg "already installed"; continue }
            Write-Line " .. " Yellow $pkg "pip install"
            # cmd owns the redirects here too, same NativeCommandError trap as the probe above
            cmd /c "python -m pip install $pkg --quiet >nul 2>&1"
            if ($LASTEXITCODE -eq 0) { Note-Installed $pkg "installed"; continue }
            Note-Warned $pkg "pip install failed"
        }
    }
}

Write-Section "VSCodium extensions"
if (-not (Step-Enabled "vscodium-extensions")) { Note-Skipped "VSCodium extensions" }
if (Step-Enabled "vscodium-extensions") {
    # exact sync removes extras (personal default); additive never uninstalls, so
    # machine-specific extensions (e.g. sideloaded work tooling) survive on work machines
    $extSync = "exact"
    if ($profileJson.vscodiumExtensionSync) { $extSync = $profileJson.vscodiumExtensionSync }
    $extFile = Join-Path $setupDir "vscodium\extensions.txt"
    if (-not (Get-Command codium -ErrorAction SilentlyContinue)) { Note-Warned "codium" "not on PATH, skipping extensions" }
    if ((Test-Path $extFile) -and (Get-Command codium -ErrorAction SilentlyContinue)) {
        $wanted = Get-Content $extFile | Where-Object { $_ }
        $have = codium --list-extensions
        $missing = @($wanted | Where-Object { $have -notcontains $_ })
        $extra = @($have | Where-Object { $wanted -notcontains $_ })
        if ($extSync -eq "exact" -and $missing.Count -eq 0 -and $extra.Count -eq 0) { Note-Present "extensions" "all $($wanted.Count) in sync" }
        if ($extSync -ne "exact" -and $missing.Count -eq 0) { Note-Present "extensions" "all $($wanted.Count) present" }
        foreach ($ext in $missing) {
            Write-Line " .. " Yellow $ext "installing"
            codium --install-extension $ext | Out-Null
            if ($LASTEXITCODE -eq 0) { Note-Installed $ext "installed"; continue }
            Note-Warned $ext "install failed"
        }
        if ($extSync -eq "exact") {
            foreach ($ext in $extra) {
                Write-Line " .. " Yellow $ext "uninstalling (not in extensions.txt)"
                codium --uninstall-extension $ext | Out-Null
                if ($LASTEXITCODE -eq 0) { Note-Applied $ext "removed"; continue }
                Note-Warned $ext "uninstall failed"
            }
        }
        if ($extSync -ne "exact" -and $extra.Count -gt 0) { Note-Present "extensions extra" "$($extra.Count) kept (additive sync)" }
    }
}

Write-Host ""
$summaryColor = "Cyan"
if ($counts.warned -gt 0) { $summaryColor = "Yellow" }
Write-Host ("  Done in {0}s: {1} updated, {2} installed, {3} up to date, {4} warnings." -f `
    [math]::Round($sw.Elapsed.TotalSeconds, 1), $counts.applied, $counts.installed, $counts.present, $counts.warned) -ForegroundColor $summaryColor
