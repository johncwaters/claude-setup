param(
    [ValidateSet("host", "container")][string]$Mode = "host",
    [switch]$Full,
    [switch]$Keep
)

$ErrorActionPreference = "Stop"

function Write-Usage {
    Write-Host "Usage: setup/test/run-windows.ps1 [-Mode host|container] [-Full] [-Keep]"
}

if ($Full -and $Mode -eq "host") {
    Write-Error "run-windows.ps1: -Full is refused in host mode; use -Mode container on a Windows-container host."
    exit 2
}

$testDir = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $testDir)
$workDir = Join-Path ([IO.Path]::GetTempPath()) ("claude-setup-win-" + [guid]::NewGuid().ToString("N"))
$suiteMode = "fast"
if ($Full) { $suiteMode = "full" }

function Copy-WorkingTreeSnapshot([string]$sourceRoot, [string]$snapshotRoot) {
    New-Item -ItemType Directory -Force $snapshotRoot | Out-Null
    $trackedFiles = git -C $sourceRoot ls-files --cached --others --exclude-standard
    if ($LASTEXITCODE -ne 0) { throw "git ls-files failed" }
    foreach ($trackedFile in $trackedFiles) {
        if (-not $trackedFile) { continue }
        $sourcePath = Join-Path $sourceRoot $trackedFile
        $destinationPath = Join-Path $snapshotRoot $trackedFile
        New-Item -ItemType Directory -Force (Split-Path $destinationPath) | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }
}

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

function Invoke-ChildProcess([string]$filePath, [string[]]$arguments, [hashtable]$environment, [string]$workingDirectory) {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $filePath
    $startInfo.Arguments = ($arguments | ForEach-Object { Format-CommandArgument $_ }) -join " "
    $startInfo.UseShellExecute = $false
    # Keeps anything the suite spawns from writing relative paths into the repo.
    $startInfo.WorkingDirectory = $workingDirectory
    foreach ($key in $environment.Keys) {
        $startInfo.Environment[$key] = [string]$environment[$key]
    }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.WaitForExit()
    return $process.ExitCode
}

try {
    Write-Host "snapshotting the working tree"
    $sourceSnapshot = Join-Path $workDir "src"
    $contextDir = Join-Path $workDir "context"
    New-Item -ItemType Directory -Force $contextDir | Out-Null
    Copy-WorkingTreeSnapshot $repoRoot $sourceSnapshot

    git -C $sourceSnapshot init -q -b master
    if ($LASTEXITCODE -ne 0) { throw "git init failed" }
    git -C $sourceSnapshot add -A
    if ($LASTEXITCODE -ne 0) { throw "git add failed" }
    git -C $sourceSnapshot -c user.name="Suite Snapshot" -c user.email="suite@example.com" commit -q -m "working tree snapshot"
    if ($LASTEXITCODE -ne 0) { throw "git commit failed" }

    $originRepo = Join-Path $workDir "origin.git"
    git clone -q --bare $sourceSnapshot $originRepo
    if ($LASTEXITCODE -ne 0) { throw "git clone --bare failed" }

    $suiteSnapshot = Join-Path $workDir "suite.ps1"
    Copy-Item -LiteralPath (Join-Path $testDir "suite.ps1") -Destination $suiteSnapshot -Force

    $sandboxRoot = Join-Path $workDir "sandbox"
    $sandboxProfile = Join-Path $sandboxRoot "profile"
    $sandboxAppData = Join-Path $sandboxRoot "appdata"
    $sandboxLocalAppData = Join-Path $sandboxRoot "localappdata"
    $sandboxTemp = Join-Path $sandboxRoot "temp"
    New-Item -ItemType Directory -Force $sandboxProfile, $sandboxAppData, $sandboxLocalAppData, $sandboxTemp | Out-Null

    if ($Mode -eq "container") {
        $imageTag = "claude-setup-test:windows"
        $dockerfilePath = Join-Path $testDir "Dockerfile.windows"
        Write-Host "building $imageTag"
        docker build -q -f $dockerfilePath -t $imageTag $contextDir | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "docker build failed" }
        Write-Host "running the $suiteMode suite"
        docker run --rm `
            -e "SUITE_MODE=$suiteMode" `
            -e "CLAUDE_SETUP_TEST_SANDBOX=1" `
            -e "CLAUDE_SETUP_TEST_CONTAINER=1" `
            -e "CLAUDE_SETUP_TEST_ORIGIN=C:\origin.git" `
            -e "CLAUDE_SETUP_TEST_SOURCE=C:\suite\src" `
            -e "CLAUDE_SETUP_TEST_REAL_USERPROFILE=$env:USERPROFILE" `
            -e "USERPROFILE=C:\sandbox\profile" `
            -e "APPDATA=C:\sandbox\appdata" `
            -e "LOCALAPPDATA=C:\sandbox\localappdata" `
            -e "TEMP=C:\sandbox" `
            -e "TMP=C:\sandbox" `
            -v "${originRepo}:C:\origin.git:ro" `
            -v "${sourceSnapshot}:C:\suite\src:ro" `
            -v "${suiteSnapshot}:C:\suite\suite.ps1:ro" `
            -v "${sandboxRoot}:C:\sandbox" `
            $imageTag
        exit $LASTEXITCODE
    }

    $powerShellPath = (Get-Process -Id $PID).Path
    Write-Host "running the host sandbox suite"
    $childEnvironment = @{
        SUITE_MODE = $suiteMode
        CLAUDE_SETUP_TEST_SANDBOX = "1"
        CLAUDE_SETUP_TEST_ORIGIN = $originRepo
        CLAUDE_SETUP_TEST_SOURCE = $sourceSnapshot
        CLAUDE_SETUP_TEST_REAL_USERPROFILE = $env:USERPROFILE
        CLAUDE_SETUP_TEST_REAL_APPDATA = $env:APPDATA
        USERPROFILE = $sandboxProfile
        APPDATA = $sandboxAppData
        LOCALAPPDATA = $sandboxLocalAppData
        TEMP = $sandboxRoot
        TMP = $sandboxRoot
    }
    $exitCode = Invoke-ChildProcess $powerShellPath @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $suiteSnapshot) $childEnvironment $sandboxRoot
    exit $exitCode
}
finally {
    if ($Keep) {
        Write-Host "work dir kept at $workDir"
    }
    if (-not $Keep) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
