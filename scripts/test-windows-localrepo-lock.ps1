# Reproduces the Windows lock on artifacts in dist.raw.localRepo.
#
# Run from the repository root after building the raw executable:
#   ./out/dist/raw/executable.dest/mill.bat show dist.raw.executable
#   pwsh -File scripts/test-windows-localrepo-lock.ps1
#
# The generated Windows launcher adds dist.raw.localRepo.dest to
# COURSIER_REPOSITORIES. Loading the build definition then opens its SNAPSHOT
# dependencies from that repository. Cleaning the repository from the same
# Mill process must not fail because one of those JARs is still open.

$ErrorActionPreference = 'Stop'

if (-not $IsWindows -and $env:OS -ne 'Windows_NT') {
    throw 'This regression test is Windows-only.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$mill = Join-Path $repoRoot 'out\dist\raw\executable.dest\mill.bat'

if (-not (Test-Path $mill -PathType Leaf)) {
    throw "Raw Windows launcher not found: $mill`nBuild it first with the project's bootstrap Mill."
}

Push-Location $repoRoot
try {
    Write-Host 'Preparing the local test repository...'
    & $mill show dist.raw.localRepo
    if ($LASTEXITCODE -ne 0) {
        throw "Could not prepare dist.raw.localRepo (exit code $LASTEXITCODE)."
    }

    Write-Host 'Cleaning dist.raw.localRepo from a JVM that has loaded the build...'
    $output = & $mill clean dist.raw.localRepo 2>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }

    if ($exitCode -ne 0) {
        $joined = $output -join "`n"
        if ($joined -match 'being used by another process|занят другим процессом|used by another process|FileSystemException') {
            throw "REPRODUCED: dist.raw.localRepo cannot be cleaned while its SNAPSHOT JAR is open.`n$joined"
        }
        throw "The clean command failed for an unexpected reason (exit code $exitCode).`n$joined"
    }

    Write-Host 'PASS: dist.raw.localRepo was cleaned while the Mill launcher was running.'
}
finally {
    Pop-Location
}
