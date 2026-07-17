# One-command machine bootstrap: clone or update claude-setup, then apply it.
param(
    [switch]$SkipInstalls,
    [string]$Root = (Join-Path $env:USERPROFILE ".claude")
)
$ErrorActionPreference = "Stop"
$repoUrl = "https://github.com/johncwaters/claude-setup.git"

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

& (Join-Path $Root "setup\apply.ps1") -SkipInstalls:$SkipInstalls
