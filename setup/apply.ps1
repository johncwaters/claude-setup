# Apply repo config to this machine. Run after git pull on a new or existing machine.
param([switch]$SkipInstalls)
$ErrorActionPreference = "Stop"
$setupDir = $PSScriptRoot

function Copy-IfExists($src, $dest) {
    if (-not (Test-Path $src)) { Write-Warning "not in repo: $src"; return }
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
    Copy-Item $src $dest -Force
    Write-Host "applied: $dest"
}

# VSCodium
$codiumUser = Join-Path $env:APPDATA "VSCodium\User"
Copy-IfExists (Join-Path $setupDir "vscodium\settings.json")    (Join-Path $codiumUser "settings.json")
Copy-IfExists (Join-Path $setupDir "vscodium\keybindings.json") (Join-Path $codiumUser "keybindings.json")
Copy-IfExists (Join-Path $setupDir "vscodium\mcp.json")         (Join-Path $codiumUser "mcp.json")

# Glissa
Copy-IfExists (Join-Path $setupDir "glissa\config.json") (Join-Path $env:USERPROFILE ".glissa\config.json")

# Git
Copy-IfExists (Join-Path $setupDir "git\.gitconfig") (Join-Path $env:USERPROFILE ".gitconfig")

# Windows Terminal
$wtDir = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState"
if (Test-Path $wtDir) { Copy-IfExists (Join-Path $setupDir "terminal\settings.json") (Join-Path $wtDir "settings.json") }

if ($SkipInstalls) { Write-Host "done (installs skipped)."; return }

# Base tools via winget
$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) { Write-Warning "winget missing; skipping all tool installs"; return }
$tools = @(
    @{ cmd = "git";  id = "Git.Git" },
    @{ cmd = "gh";   id = "GitHub.cli" },
    @{ cmd = "node"; id = "OpenJS.NodeJS" }
)
$installedAny = $false
foreach ($t in $tools) {
    if (Get-Command $t.cmd -ErrorAction SilentlyContinue) { continue }
    Write-Host "installing $($t.id) via winget"
    winget install --id $t.id -e --accept-source-agreements --accept-package-agreements
    $installedAny = $true
}
if ($installedAny) {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

# Claude Code (native installer)
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "installing Claude Code"
    Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "User") + ";" + $env:Path
}

# Fonts (per-user install)
$fontDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
$fontReg = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
New-Item -ItemType Directory -Force $fontDir | Out-Null
foreach ($font in (Get-ChildItem (Join-Path $setupDir "fonts") -File -ErrorAction SilentlyContinue)) {
    $target = Join-Path $fontDir $font.Name
    if (Test-Path $target) { continue }
    Copy-Item $font.FullName $target
    New-ItemProperty -Path $fontReg -Name "$($font.BaseName) (OpenType)" -Value $target -PropertyType String -Force | Out-Null
    Write-Host "installed font: $($font.Name)"
}

# npm globals
$npmGlobals = Join-Path $setupDir "npm-globals.txt"
if (Test-Path $npmGlobals) {
    $wanted = Get-Content $npmGlobals | Where-Object { $_ }
    $installed = npm ls -g --depth=0 --parseable 2>$null | Where-Object { $_ -match "node_modules" } | ForEach-Object { ($_ -replace ".*node_modules[\\/]", "") -replace "\\", "/" }
    foreach ($pkg in $wanted) {
        if ($installed -contains $pkg) { continue }
        Write-Host "installing: $pkg"
        npm install -g $pkg
    }
}

# VSCodium (winget install if missing)
$codium = Get-Command codium -ErrorAction SilentlyContinue
if (-not $codium) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { Write-Warning "codium and winget both missing; install VSCodium manually then rerun"; return }
    Write-Host "installing VSCodium via winget"
    winget install --id VSCodium.VSCodium -e --accept-source-agreements --accept-package-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    $codium = Get-Command codium -ErrorAction SilentlyContinue
}
if (-not $codium) { Write-Warning "codium still not on PATH; open a new shell and rerun for extensions"; return }

# VSCodium extensions
$extFile = Join-Path $setupDir "vscodium\extensions.txt"
if (Test-Path $extFile) {
    $have = codium --list-extensions
    foreach ($ext in (Get-Content $extFile | Where-Object { $_ })) {
        if ($have -contains $ext) { continue }
        Write-Host "installing extension: $ext"
        codium --install-extension $ext
    }
}

Write-Host "done."
