# Cross-platform regression test for locking SNAPSHOT artifacts in dist.raw.localRepo.
# Build the raw executable first:
#   ./mill dist.raw.executable
# Then run:
#   pwsh -File scripts/test-windows-localrepo-lock.ps1

$ErrorActionPreference = 'Stop'
$isWindowsPlatform = $IsWindows -or $env:OS -eq 'Windows_NT'
$launcherName = if ($isWindowsPlatform) { 'mill.bat' } else { 'mill' }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$mill = Join-Path $repoRoot (Join-Path 'out/dist/raw/executable.dest' $launcherName)

if (-not (Test-Path $mill -PathType Leaf)) {
    throw "Raw platform launcher not found: $mill`nBuild it first with ./mill dist.raw.executable."
}

function Invoke-MillAndCapture([string[]] $MillArgs) {
    $lines = @(& $mill @MillArgs 2>&1 | ForEach-Object { $_.ToString() })
    $code = $LASTEXITCODE
    $lines | ForEach-Object { Write-Host $_ }
    return @{ ExitCode = $code; Output = ($lines -join "`n") }
}

function Test-LocalRepoLock([string] $Output) {
    # Match the exception type and affected artifact path, not localized OS text.
    return $Output -match '(?is)java\.nio\.file\.FileSystemException:.*dist[\\/]raw[\\/]localRepo\.dest.*mill-contrib-buildinfo_3-SNAPSHOT\.jar'
}

Push-Location $repoRoot
try {
    Write-Host "Evaluating dist.raw.localRepo on $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)..."
    $result = Invoke-MillAndCapture @('show', 'dist.raw.localRepo')

    if ($result.ExitCode -ne 0) {
        if (Test-LocalRepoLock $result.Output) {
            throw "REPRODUCED: the SNAPSHOT JAR could not be removed while evaluating dist.raw.localRepo.`n$($result.Output)"
        }
        throw "Mill failed while evaluating dist.raw.localRepo (exit code $($result.ExitCode)).`n$($result.Output)"
    }

    Write-Host 'Cleaning dist.raw.localRepo in a subsequent Mill invocation...'
    $result = Invoke-MillAndCapture @('clean', 'dist.raw.localRepo')
    if ($result.ExitCode -ne 0) {
        if (Test-LocalRepoLock $result.Output) {
            throw "REPRODUCED: the SNAPSHOT JAR could not be removed while cleaning dist.raw.localRepo.`n$($result.Output)"
        }
        throw "Mill clean failed (exit code $($result.ExitCode)).`n$($result.Output)"
    }

    Write-Host 'PASS: dist.raw.localRepo was evaluated and cleaned without a file-lock error.'
}
finally {
    Pop-Location
}
