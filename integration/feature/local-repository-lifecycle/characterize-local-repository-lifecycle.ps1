# Characterization test for the current raw-launcher local repository lifecycle.
# Unlike the target regression, this test records the currently observed behavior:
# raw daemon classpath provenance and OS-specific deletion while daemon/workers live.
$ErrorActionPreference = 'Stop'
$isWindowsPlatform = $IsWindows -or $env:OS -eq 'Windows_NT'
$isPosixPlatform = -not $isWindowsPlatform
$launcherName = if ($isWindowsPlatform) { 'mill.bat' } else { 'mill' }
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$bootstrapMill = Join-Path $repoRoot $launcherName
$rawMill = Join-Path $repoRoot 'out/dist/raw/executable.dest' $launcherName
$localRepo = Join-Path $repoRoot 'out/dist/raw/localRepo.dest'
$localRepoMarker = 'localrepo.dest'

function Get-MillProcesses {
    if ($isWindowsPlatform) {
        $all = Get-CimInstance Win32_Process -Filter "Name = 'java.exe' OR Name = 'javaw.exe'"
        foreach ($p in $all) {
            if ($p.CommandLine -like '*mill.daemon.MillDaemonMain*') {
                [pscustomobject]@{ Id = [int]$p.ProcessId; Kind = 'daemon'; CommandLine = $p.CommandLine }
            } elseif ($p.CommandLine -like '*mill.javalib.worker.MillJvmWorkerMain*') {
                [pscustomobject]@{ Id = [int]$p.ProcessId; Kind = 'worker'; CommandLine = $p.CommandLine }
            }
        }
    } else {
        foreach ($line in @(& ps -eo pid=,args=)) {
            if ($line -match '^\s*(\d+)\s+(.*)$') {
                $id = [int]$Matches[1]
                $commandLine = $Matches[2]
                if ($commandLine.Contains('mill.daemon.MillDaemonMain')) {
                    [pscustomobject]@{ Id = $id; Kind = 'daemon'; CommandLine = $commandLine }
                } elseif ($commandLine.Contains('mill.javalib.worker.MillJvmWorkerMain')) {
                    [pscustomobject]@{ Id = $id; Kind = 'worker'; CommandLine = $commandLine }
                }
            }
        }
    }
}

function Invoke-Mill([string] $Launcher, [string[]] $MillArgs, [string] $Label) {
    Write-Host ([Environment]::NewLine + "=== $Label ===")
    Write-Host "Command: $Launcher $($MillArgs -join ' ')"
    $output = @(& $Launcher @MillArgs 2>&1 | ForEach-Object { $_.ToString() })
    $code = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    return [pscustomobject]@{ ExitCode = $code; Output = $output }
}

function Stop-MillProcesses([string] $Launcher, [string] $Label) {
    $before = @(Get-MillProcesses)
    if ($before.Count -eq 0) { return }
    [void](Invoke-Mill $Launcher @('shutdown') "$Label / shutdown")
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $remaining = @(Get-MillProcesses | Where-Object { $_.Id -in @($before | ForEach-Object Id) })
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($remaining.Count -gt 0) {
        throw "Mill processes did not exit during $Label cleanup: $((@($remaining | ForEach-Object Id)) -join ', ')"
    }
}

function Assert-SameProcesses([int[]] $ExpectedIds, [string] $Phase) {
    $actual = @(Get-MillProcesses | ForEach-Object { [int]$_.Id })
    $missing = @($ExpectedIds | Where-Object { $_ -notin $actual })
    if ($missing.Count -gt 0) {
        throw "Characterization invalid: original daemon/worker PIDs exited during $Phase: $($missing -join ', ')"
    }
    Write-Host "PASS: original daemon and worker PIDs remain alive after $Phase."
}

Push-Location $repoRoot
try {
    Write-Host "OS: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
    if (-not (Test-Path -LiteralPath $bootstrapMill -PathType Leaf)) {
        throw "Bootstrap launcher not found: $bootstrapMill"
    }

    [void](Invoke-Mill $bootstrapMill @('show', 'dist.raw.executable') 'build raw executable')
    if (-not (Test-Path -LiteralPath $rawMill -PathType Leaf)) {
        throw "Raw launcher not found: $rawMill"
    }
    Stop-MillProcesses $bootstrapMill 'bootstrap build isolation'

     $rawStartup = Invoke-Mill $rawMill @('show', 'millVersion') 'raw daemon startup'
    Write-Host "Raw launcher client exit code: $($rawStartup.ExitCode) (the daemon process is inspected independently)."
    $daemons = @(Get-MillProcesses | Where-Object Kind -eq 'daemon')
    if ($daemons.Count -eq 0) { throw 'Raw launcher did not leave a Mill daemon process running.' }

    $daemonMentionsLocalRepo = $false
    foreach ($daemon in $daemons) {
        $normalized = $daemon.CommandLine.Replace('\', '/').ToLowerInvariant()
        $mentions = $normalized.Contains($localRepoMarker)
        if ($mentions) { $daemonMentionsLocalRepo = $true }
        $cacheMediated = $normalized.Contains('/coursier/cache/v1/file/') -and $mentions
        $kind = if ($cacheMediated) { 'Coursier file-cache path containing localRepo marker' }
                elseif ($mentions) { 'direct/localRepo path' }
                else { 'no localRepo marker visible in command line' }
        Write-Host "daemon PID=$($daemon.Id): $kind"
        Write-Host "  $($daemon.CommandLine)"
    }
    if (-not $daemonMentionsLocalRepo) {
        throw 'Characterization changed: no raw daemon command line exposed a localRepo artifact path.'
    }

        # Use the bootstrap launcher as a client after the raw launcher has started the daemon.
    # On Windows the raw launcher command itself can return exit code 1 even though its daemon
    # is running; using it for subsequent commands would conflate that launcher failure with clean.
    $rawDaemonIds = @($daemons | ForEach-Object { [int]$_.Id })
    $compile = Invoke-Mill $bootstrapMill @('__.compile') 'bootstrap client compile to start Zinc workers'
    if ($compile.ExitCode -ne 0) { throw "Could not start Zinc workers through the existing daemon; exit code $($compile.ExitCode)." }
    $stillRawDaemons = @(Get-MillProcesses | Where-Object { $_.Kind -eq 'daemon' -and $_.Id -in $rawDaemonIds })
    if ($stillRawDaemons.Count -eq 0) { throw 'The raw-launched daemon was replaced before the worker/clean observation.' }
    $processes = @(Get-MillProcesses)
    $daemons = @($processes | Where-Object Kind -eq 'daemon')
    $workers = @($processes | Where-Object Kind -eq 'worker')
    if ($daemons.Count -eq 0) { throw 'Raw daemon exited before the live-process clean observation.' }
    if ($workers.Count -eq 0) { throw 'No Zinc worker process was found; the worker lifecycle was not characterized.' }

    foreach ($worker in $workers) {
        $normalized = $worker.CommandLine.Replace('\', '/').ToLowerInvariant()
        $kind = if ($normalized.Contains($localRepoMarker)) { 'localRepo marker present' } else { 'no localRepo marker visible' }
        Write-Host "worker PID=$($worker.Id): $kind"
        Write-Host "  $($worker.CommandLine)"
    }

    $originalIds = @($processes | ForEach-Object { [int]$_.Id })
    $clean = Invoke-Mill $bootstrapMill @('clean', 'dist.raw.localRepo') 'bootstrap client clean while raw daemon and Zinc workers are alive'
    Assert-SameProcesses $originalIds 'clean'

    if ($isWindowsPlatform) {
        if ($clean.ExitCode -eq 0 -or -not (Test-Path -LiteralPath $localRepo -PathType Container)) {
            throw "Characterization changed: expected the observed Windows clean failure with localRepo retained; exit=$($clean.ExitCode), exists=$(Test-Path -LiteralPath $localRepo)."
        }
        Write-Host 'PASS: observed Windows behavior — clean fails and localRepo remains while the original processes are alive.'
    } elseif ($isPosixPlatform) {
        if ($clean.ExitCode -ne 0 -or (Test-Path -LiteralPath $localRepo)) {
            throw "Characterization changed: expected POSIX unlink behavior; exit=$($clean.ExitCode), exists=$(Test-Path -LiteralPath $localRepo)."
        }
        Write-Host 'PASS: observed POSIX behavior — clean removes localRepo while the original processes are alive.'
    }
} finally {
    try { Stop-MillProcesses $bootstrapMill 'raw characterization' } catch { Write-Host "Cleanup warning: $($_.Exception.Message)" }
    if (Test-Path -LiteralPath $localRepo) {
        try { [void](Invoke-Mill $bootstrapMill @('clean', 'dist.raw.localRepo') 'cleanup localRepo after characterization') }
        catch { Write-Host "Repository cleanup warning: $($_.Exception.Message)" }
    }
    Pop-Location
}
