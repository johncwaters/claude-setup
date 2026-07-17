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

Write-Section "VSCodium extensions"
$extFile = Join-Path $setupDir "vscodium\extensions.txt"
if (-not (Get-Command codium -ErrorAction SilentlyContinue)) { Note-Warned "codium" "not on PATH, skipping extensions" }
if ((Test-Path $extFile) -and (Get-Command codium -ErrorAction SilentlyContinue)) {
    $wanted = Get-Content $extFile | Where-Object { $_ }
    $have = codium --list-extensions
    $missing = @($wanted | Where-Object { $have -notcontains $_ })
    if ($missing.Count -eq 0) { Note-Present "extensions" "all $($wanted.Count) present" }
    foreach ($ext in $missing) {
        Write-Line " .. " Yellow $ext "installing"
        codium --install-extension $ext | Out-Null
        if ($LASTEXITCODE -eq 0) { Note-Installed $ext "installed"; continue }
        Note-Warned $ext "install failed"
    }
}

Write-Host ""
$summaryColor = "Cyan"
if ($counts.warned -gt 0) { $summaryColor = "Yellow" }
Write-Host ("  Done in {0}s: {1} updated, {2} installed, {3} up to date, {4} warnings." -f `
    [math]::Round($sw.Elapsed.TotalSeconds, 1), $counts.applied, $counts.installed, $counts.present, $counts.warned) -ForegroundColor $summaryColor
