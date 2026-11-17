# Target-requirement coverage:
# - LRL-TAR-03: bootstrap launcher rebuilds localRepo after clean and reuses the daemon/workers.
# - LRL-TAR-05: requested localRepo is created and populated and can be reused.
# LRL-TAR-01/02/04/06/07/08 are covered by focused companion scripts.
$ErrorActionPreference = 'Stop'
$isWindowsPlatform = $IsWindows -or $env:OS -eq 'Windows_NT'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$launcher = Join-Path $repoRoot $(if ($isWindowsPlatform) { 'mill.bat' } else { 'mill' })
$localRepo = Join-Path $repoRoot 'out/dist/raw/localRepo.dest'

function Invoke-Mill([string[]] $MillArgs, [string] $Scenario) {
    Write-Host ([Environment]::NewLine + '=== ' + $Scenario + ' ===')
    Write-Host "Command: $($MillArgs -join ' ')"
    $lines = @(& $launcher @MillArgs 2>&1 | ForEach-Object { $_.ToString() })
    $code = $LASTEXITCODE
    $lines | ForEach-Object { Write-Host $_ }
    if ($code -ne 0) { throw "$Scenario failed with exit code $code" }
}

function Get-MillProcesses {
    if ($isWindowsPlatform) {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name = 'java.exe' OR Name = 'javaw.exe'")) {
            if ($p.CommandLine -like '*mill.daemon.MillDaemonMain*') { [pscustomobject]@{ Id = [int]$p.ProcessId; Kind = 'daemon' } }
            elseif ($p.CommandLine -like '*mill.javalib.worker.MillJvmWorkerMain*') { [pscustomobject]@{ Id = [int]$p.ProcessId; Kind = 'worker' } }
        }
    } else {
        foreach ($line in @(& ps -eo pid=,args=)) {
            $parts = $line.Trim() -split '\s+', 2
            if ($parts.Count -eq 2) {
                if ($parts[1] -like '*mill.daemon.MillDaemonMain*') { [pscustomobject]@{ Id = [int]$parts[0]; Kind = 'daemon' } }
                elseif ($parts[1] -like '*mill.javalib.worker.MillJvmWorkerMain*') { [pscustomobject]@{ Id = [int]$parts[0]; Kind = 'worker' } }
            }
        }
    }
}

function Stop-Mill {
    $processes = @(Get-MillProcesses)
    if ($processes.Count -eq 0) { return }
    $ids = @($processes | ForEach-Object Id)
    try { Invoke-Mill @('shutdown') 'shutdown' } catch {}
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $remaining = @(Get-MillProcesses | Where-Object { $_.Id -in $ids })
        if ($remaining.Count -eq 0) { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Mill processes did not exit during cleanup.'
}

Push-Location $repoRoot
try {
    Invoke-Mill @('clean','dist.raw.localRepo') 'prepare clean state'
    if (Test-Path -LiteralPath $localRepo) { throw 'localRepo still exists after preparation clean.' }

    Invoke-Mill @('show','dist.raw.localRepo') 'initial repository creation'
    if (-not (Test-Path -LiteralPath $localRepo -PathType Container)) { throw 'localRepo was not created.' }
    $initialFiles = @(Get-ChildItem -LiteralPath $localRepo -File -Recurse)
    if ($initialFiles.Count -eq 0) { throw 'initial localRepo is empty.' }
    Write-Host "PASS: initial localRepo contains $($initialFiles.Count) files."

    Invoke-Mill @('clean', '__.compile') 'clear compile outputs to ensure Zinc worker startup'
    Invoke-Mill @('__.compile') 'start daemon and Zinc worker'
    $processes = @(Get-MillProcesses)
    $expectedIds = @($processes | ForEach-Object Id)
    if (@($processes | Where-Object Kind -eq 'daemon').Count -eq 0) { throw 'No daemon after compile.' }
    if (@($processes | Where-Object Kind -eq 'worker').Count -eq 0) { throw 'No Zinc worker after compile.' }

    Invoke-Mill @('clean','dist.raw.localRepo') 'clean before rebuild'
    if (Test-Path -LiteralPath $localRepo) { throw 'localRepo still exists after clean.' }

    Invoke-Mill @('show','dist.raw.localRepo') 'rebuild repository after clean'
    if (-not (Test-Path -LiteralPath $localRepo -PathType Container)) { throw 'rebuild did not recreate localRepo.' }
    $rebuiltFiles = @(Get-ChildItem -LiteralPath $localRepo -File -Recurse)
    if ($rebuiltFiles.Count -eq 0) { throw 'rebuilt localRepo is empty.' }

    Invoke-Mill @('show','dist.raw.localRepo') 'reuse daemon after rebuild'
    $remaining = @(Get-MillProcesses | Where-Object { $_.Id -in $expectedIds })
    if ($remaining.Count -ne $expectedIds.Count) { throw 'Original daemon/worker processes were replaced during rebuild.' }
    Write-Host "PASS: rebuilt localRepo contains $($rebuiltFiles.Count) files and the original daemon/workers were reused."
} finally {
    try { Stop-Mill } catch { Write-Host "Cleanup warning: $($_.Exception.Message)" }
    Pop-Location
}
