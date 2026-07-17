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

# VSCodium extensions
$extFile = Join-Path $setupDir "vscodium\extensions.txt"
$codium = Get-Command codium -ErrorAction SilentlyContinue
if (-not $codium) { Write-Warning "codium not on PATH; install VSCodium then rerun for extensions"; return }
if (Test-Path $extFile) {
    $have = codium --list-extensions
    foreach ($ext in (Get-Content $extFile | Where-Object { $_ })) {
        if ($have -contains $ext) { continue }
        Write-Host "installing extension: $ext"
        codium --install-extension $ext
    }
}

Write-Host "done."
