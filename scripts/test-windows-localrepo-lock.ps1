# Regression test for Windows locking SNAPSHOT artifacts in dist.raw.localRepo.
# Run from the repository root after building the raw Windows executable:
#   pwsh -File scripts/test-windows-localrepo-lock.ps1
#
# A failure to delete mill-contrib-buildinfo_3-SNAPSHOT.jar while Mill
# evaluates dist.raw.localRepo is the regression this test is intended to catch.

$ErrorActionPreference = 'Stop'

if (-not $IsWindows -and $env:OS -ne 'Windows_NT') {
    throw 'This regression test is Windows-only.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$mill = Join-Path $repoRoot 'out\dist\raw\executable.dest\mill.bat'

if (-not (Test-Path $mill -PathType Leaf)) {
    throw "Raw Windows launcher not found: $mill`nBuild it first with the project's bootstrap Mill."
}

function Invoke-MillAndCapture([string[]] $MillArgs) {
    $lines = @(& $mill @MillArgs 2>&1 | ForEach-Object { $_.ToString() })
    $code = $LASTEXITCODE
    $lines | ForEach-Object { Write-Host $_ }
    return @{ ExitCode = $code; Output = ($lines -join "`n") }
}

function Test-LocalRepoLock([string] $Output) {
    # Match the exception type and affected artifact path, not the localized
    # Windows error text (which may be emitted with a different code page).
    return $Output -match '(?is)java\.nio\.file\.FileSystemException:.*dist[\\/]raw[\\/]localRepo\.dest.*mill-contrib-buildinfo_3-SNAPSHOT\.jar'
}

Push-Location $repoRoot
try {
    Write-Host 'Evaluating dist.raw.localRepo (this can itself reproduce the lock)...'
    $result = Invoke-MillAndCapture @('show', 'dist.raw.localRepo')

    if ($result.ExitCode -ne 0) {
        if (Test-LocalRepoLock $result.Output) {
            throw "REPRODUCED: Windows refused to delete the SNAPSHOT JAR while evaluating dist.raw.localRepo.`n$($result.Output)"
        }
        throw "Mill failed for an unrelated reason (exit code $($result.ExitCode)).`n$($result.Output)"
    }

    Write-Host 'Cleaning dist.raw.localRepo in a subsequent Mill invocation...'
    $result = Invoke-MillAndCapture @('clean', 'dist.raw.localRepo')
    if ($result.ExitCode -ne 0) {
        if (Test-LocalRepoLock $result.Output) {
            throw "REPRODUCED: Windows refused to delete the SNAPSHOT JAR while cleaning dist.raw.localRepo.`n$($result.Output)"
        }
        throw "Mill clean failed for an unrelated reason (exit code $($result.ExitCode)).`n$($result.Output)"
    }

    Write-Host 'PASS: dist.raw.localRepo was evaluated and cleaned without a Windows file-lock error.'
}
finally {
    Pop-Location
}
