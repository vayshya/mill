# Target-requirement coverage:
# - LRL-TAR-04: raw-launcher scenario verifies handle release and physical deletion only; no rebuild assertion.
# - LRL-TAR-08: raw daemon runtime classpath must not depend on deletable localRepo.
# LRL-TAR-01/02/03/05/06/07 are covered by focused companion scripts.
$ErrorActionPreference = 'Stop'
$isWindowsPlatform = $IsWindows -or $env:OS -eq 'Windows_NT'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$bootstrap = Join-Path $repoRoot $(if ($isWindowsPlatform) { 'mill.bat' } else { 'mill' })
$rawLauncher = Join-Path $repoRoot 'out/dist/raw/executable.dest' $(if ($isWindowsPlatform) { 'mill.bat' } else { 'mill' })
$localRepo = Join-Path $repoRoot 'out/dist/raw/localRepo.dest'

function Invoke-Launcher([string] $Launcher, [string[]] $Args, [string] $Scenario, [bool] $AllowNonZero = $false) {
    Write-Host ([Environment]::NewLine + '=== ' + $Scenario + ' ===')
    Write-Host "Launcher: $Launcher"
    Write-Host "Command: $($Args -join ' ')"
    $lines = @(& $Launcher @Args 2>&1 | ForEach-Object { $_.ToString() })
    $code = $LASTEXITCODE
    $lines | ForEach-Object { Write-Host $_ }
    if ($code -ne 0 -and -not $AllowNonZero) { throw "$Scenario failed with exit code $code" }
    return $code
}

function Get-MillProcesses {
    if ($isWindowsPlatform) {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name = 'java.exe' OR Name = 'javaw.exe'")) {
            if ($p.CommandLine -like '*mill.daemon.MillDaemonMain*') { [pscustomobject]@{ Id=[int]$p.ProcessId; Kind='daemon'; CommandLine=$p.CommandLine } }
            elseif ($p.CommandLine -like '*mill.javalib.worker.MillJvmWorkerMain*') { [pscustomobject]@{ Id=[int]$p.ProcessId; Kind='worker'; CommandLine=$p.CommandLine } }
        }
    } else {
        foreach ($line in @(& ps -eo pid=,args=)) {
            $parts = $line.Trim() -split '\s+', 2
            if ($parts.Count -eq 2) {
                if ($parts[1] -like '*mill.daemon.MillDaemonMain*') { [pscustomobject]@{ Id=[int]$parts[0]; Kind='daemon'; CommandLine=$parts[1] } }
                elseif ($parts[1] -like '*mill.javalib.worker.MillJvmWorkerMain*') { [pscustomobject]@{ Id=[int]$parts[0]; Kind='worker'; CommandLine=$parts[1] } }
            }
        }
    }
}

function Stop-Mill([string] $Launcher) {
    $processes = @(Get-MillProcesses)
    if ($processes.Count -eq 0) { return }
    $ids = @($processes | ForEach-Object Id)
    try { Invoke-Launcher $Launcher @('shutdown') 'shutdown' } catch {}
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
    Invoke-Launcher $bootstrap @('show','dist.raw.executable') 'build raw launcher'
    Stop-Mill $bootstrap
    if (-not (Test-Path -LiteralPath $rawLauncher -PathType Leaf)) { throw "Raw launcher not found: $rawLauncher" }

    $startupCode = Invoke-Launcher $rawLauncher @('show','millVersion') 'raw launcher daemon startup' $true
    if ($startupCode -ne 0) {
        Write-Host "INFO: raw launcher daemon startup returned exit code $startupCode; continuing because the daemon must be inspected independently of the client command result."
    }
    $daemons = @(Get-MillProcesses | Where-Object Kind -eq 'daemon')
    if ($daemons.Count -eq 0) { throw 'No raw-launched daemon was found.' }

    $needle = $localRepo.Replace('\','/').ToLowerInvariant()
    foreach ($daemon in $daemons) {
        if ($daemon.CommandLine.Replace('\','/').ToLowerInvariant().Contains($needle)) {
            throw "Raw daemon PID $($daemon.Id) has a runtime classpath entry below localRepo: $($daemon.CommandLine)"
        }
    }
    Write-Host 'PASS: raw daemon runtime classpath does not reference localRepo.'

    Invoke-Launcher $rawLauncher @('show','dist.raw.localRepo') 'raw launcher repository resolution'
    if (-not (Test-Path -LiteralPath $localRepo -PathType Container)) { throw 'raw launcher did not create localRepo.' }
    if (@(Get-ChildItem -LiteralPath $localRepo -File -Recurse).Count -eq 0) { throw 'raw launcher created an empty localRepo.' }

    $processIds = @(Get-MillProcesses | ForEach-Object Id)
    Invoke-Launcher $rawLauncher @('clean','dist.raw.localRepo') 'raw launcher clean'
    if (Test-Path -LiteralPath $localRepo) { throw 'raw launcher clean did not physically remove localRepo.' }
    $remaining = @(Get-MillProcesses | Where-Object { $_.Id -in $processIds })
    if ($remaining.Count -ne $processIds.Count) { throw 'raw daemon/workers were not kept alive through clean.' }
    Write-Host 'PASS: raw-launcher clean removed localRepo while the original long-lived processes remained alive.'
    Write-Host 'INFO: raw-launcher rebuild after clean is intentionally not tested here; LRL-TAR-04 isolates that unrelated SNAPSHOT resolution path.'
} finally {
    try { Stop-Mill $rawLauncher } catch { Write-Host "Cleanup warning: $($_.Exception.Message)" }
    Pop-Location
}
