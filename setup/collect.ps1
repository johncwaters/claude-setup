# Collect live machine config into this repo. Run before committing config changes.
param([switch]$Help)
$ErrorActionPreference = "Stop"

function Write-Usage {
    Write-Host "Usage: setup/collect.ps1 [-Help]"
    Write-Host ""
    Write-Host "Collect live machine config into this repo."
}

# Without this guard a mistyped flag was silently ignored and the full collection ran
# anyway, unlike collect.sh which rejects it. --help is accepted alongside -Help because
# the README documents the same flag for collect.sh.
if ($Help -or ($args -contains "--help")) { Write-Usage; exit 0 }
if ($args.Count -gt 0) {
    Write-Host "collect.ps1: unknown option: $($args -join ' ')"
    Write-Usage
    exit 2
}
$setupDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $PSScriptRoot
$markerPath = Join-Path $repoRoot ".machine-profile"
$machineProfile = "personal"
if (Test-Path $markerPath) { $machineProfile = (Get-Content $markerPath -Raw).Trim() }
if (-not (Test-Path $markerPath)) { Write-Warning "no .machine-profile marker, assuming personal" }

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

if ($machineProfile -eq "work") {
    Write-Host "note: glissa, repos, gitconfig, terminal, and npm-globals collection are personal-profile only; workflow edits (CLAUDE.md, settings.json, skills) are committed directly from ~/.claude, not collected."
    return
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

# Git. The tracked gitconfig is public, so the [user] identity is replaced with the same
# placeholders apply.ps1 refuses to install; everything else in the file is collected as is.
$gitConfigSrc = Join-Path $env:USERPROFILE ".gitconfig"
if (-not (Test-Path $gitConfigSrc)) { Write-Warning "missing: $gitConfigSrc" }
if (Test-Path $gitConfigSrc) {
    $section = ""
    $scrubbed = @(
        "# Placeholder identity. Edit these two values before running the apply script: while the",
        "# placeholders are present the gitconfig step refuses to copy this file to ~/.gitconfig,",
        "# so nobody commits under someone else's name."
    )
    $scrubbed += foreach ($line in (Get-Content $gitConfigSrc)) {
        if ($line -match '^\s*\[\s*([^\]\s]+)') { $section = $Matches[1].ToLower() }
        if ($section -eq "user" -and $line -match '^\s*name\s*=')  { "`tname = Your Name"; continue }
        if ($section -eq "user" -and $line -match '^\s*email\s*=') { "`temail = you@example.com"; continue }
        $line
    }
    # WriteAllText keeps the tracked file BOM-free with LF endings, so collect runs do not
    # rewrite it as a spurious diff (Set-Content -Encoding utf8 emits BOM+CRLF on PS 5.1).
    [IO.File]::WriteAllText((Join-Path $setupDir "git\.gitconfig"), (($scrubbed -join "`n") + "`n"))
    Write-Host "collected (identity scrubbed): $gitConfigSrc"
}

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
