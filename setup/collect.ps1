# Collect live machine config into this repo. Run before committing config changes.
$ErrorActionPreference = "Stop"
$setupDir = $PSScriptRoot

function Copy-IfExists($src, $dest) {
    if (-not (Test-Path $src)) { Write-Warning "missing: $src"; return }
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
    Copy-Item $src $dest -Force
    Write-Host "collected: $src"
}

# VSCodium
$codiumUser = Join-Path $env:APPDATA "VSCodium\User"
Copy-IfExists (Join-Path $codiumUser "settings.json")    (Join-Path $setupDir "vscodium\settings.json")
Copy-IfExists (Join-Path $codiumUser "keybindings.json") (Join-Path $setupDir "vscodium\keybindings.json")
Copy-IfExists (Join-Path $codiumUser "mcp.json")         (Join-Path $setupDir "vscodium\mcp.json")
$codium = Get-Command codium -ErrorAction SilentlyContinue
if ($codium) {
    codium --list-extensions | Sort-Object | Set-Content -Encoding utf8 (Join-Path $setupDir "vscodium\extensions.txt")
    Write-Host "collected: extension list"
}

# Glissa
Copy-IfExists (Join-Path $env:USERPROFILE ".glissa\config.json") (Join-Path $setupDir "glissa\config.json")

# Repos referenced by glissa projects (folder relative to USERPROFILE = origin url)
$glissaCfg = Join-Path $env:USERPROFILE ".glissa\config.json"
if (Test-Path $glissaCfg) {
    $paths = (Get-Content $glissaCfg -Raw | ConvertFrom-Json).projects.path | Sort-Object -Unique
    $entries = foreach ($p in $paths) {
        if (-not (Test-Path (Join-Path $p ".git"))) { continue }
        $url = git -C $p config --get remote.origin.url
        if (-not $url) { Write-Warning "no origin remote, skipping: $p"; continue }
        $rel = $p -replace [regex]::Escape($env:USERPROFILE + "\"), ""
        "$rel=$url"
    }
    $entries | Sort-Object | Set-Content -Encoding utf8 (Join-Path $setupDir "repos.txt")
    Write-Host "collected: glissa repos"
}

# Git
Copy-IfExists (Join-Path $env:USERPROFILE ".gitconfig") (Join-Path $setupDir "git\.gitconfig")

# Windows Terminal
$wt = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
Copy-IfExists $wt (Join-Path $setupDir "terminal\settings.json")

# npm global packages (names only, skip npm itself)
$npmList = npm ls -g --depth=0 --parseable 2>$null
if ($npmList) {
    $names = $npmList | Where-Object { $_ -match "node_modules" } | ForEach-Object {
        $rel = $_ -replace ".*node_modules[\\/]", ""
        $rel -replace "\\", "/"
    } | Where-Object { $_ -and $_ -ne "npm" } | Sort-Object -Unique
    $names | Set-Content -Encoding utf8 (Join-Path $setupDir "npm-globals.txt")
    Write-Host "collected: npm globals"
}

Write-Host "done. Review changes with: git -C $env:USERPROFILE\.claude status"
