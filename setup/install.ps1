# One-command machine bootstrap: clone or update claude-setup, then apply it.
param(
    [switch]$SkipInstalls,
    [ValidateSet("personal","work")][string]$Profile,
    [string]$Root = (Join-Path $env:USERPROFILE ".claude"),
    [switch]$Help
)
$ErrorActionPreference = "Stop"
$repoUrl = "https://github.com/johncwaters/claude-setup.git"

function Write-Usage {
    Write-Host "Usage: setup/install.ps1 [-SkipInstalls] [-Profile personal|work] [-Root <dir>] [-Help]"
    Write-Host ""
    Write-Host "Clone or update claude-setup, then apply it."
}

# A script param block leaves unbound arguments in $args instead of failing, so without
# this a mistyped flag would bootstrap the machine anyway. --help is accepted alongside
# -Help because the README documents the same flag for install.sh.
if ($Help -or ($args -contains "--help")) { Write-Usage; exit 0 }
if ($args.Count -gt 0) {
    Write-Host "install.ps1: unknown option: $($args -join ' ')"
    Write-Usage
    exit 2
}

Write-Host ""
Write-Host "  +--------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |   claude-setup  ::  machine bootstrap      |" -ForegroundColor Cyan
Write-Host "  +--------------------------------------------+" -ForegroundColor Cyan

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "  git is required. Run first:" -ForegroundColor Red
    Write-Host "    winget install -e --id Git.Git" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
$isRepo = Test-Path (Join-Path $Root ".git")
if ($isRepo) {
    Write-Host "  Repo found at $Root, pulling latest" -ForegroundColor Cyan
    git -C $Root pull --ff-only -q
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  git pull failed; resolve manually in $Root then rerun" -ForegroundColor Red
        exit 1
    }
}
if (-not $isRepo) {
    Write-Host "  Cloning into $Root (browser may open for GitHub sign-in)" -ForegroundColor Cyan
    New-Item -ItemType Directory -Force $Root | Out-Null
    git -C $Root init -q -b master
    git -C $Root remote add origin $repoUrl
    git -C $Root fetch -q origin
    git -C $Root checkout -q -f master
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  clone failed; check GitHub access then rerun" -ForegroundColor Red
        exit 1
    }
}
Write-Host "  At commit $(git -C $Root rev-parse --short HEAD)" -ForegroundColor DarkGray

$applyArgs = @{ SkipInstalls = $SkipInstalls }
if ($Profile) { $applyArgs.Profile = $Profile }
& (Join-Path $Root "setup\apply.ps1") @applyArgs
