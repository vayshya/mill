# Characterization coverage:
# - LRL-CHAR-01: record Windows Coursier-cache-mediated classpath provenance.
# - LRL-CHAR-02: record the Windows raw-launcher startup-command anomaly.
# - LRL-CHAR-03: record Linux daemon/worker classpath observations.
# - LRL-CHAR-04: record original daemon/worker survival during clean.
# - LRL-CHAR-05: record the OS-specific clean outcome.
# - LRL-CHAR-06: record macOS outcome independently without assuming success.
# Characterization test for the current raw-launcher local repository lifecycle.
# Unlike the target regression, this test records the currently observed behavior:
# raw daemon classpath provenance and OS-specific deletion while daemon/workers live.
$ErrorActionPreference = 'Stop'
$isWindowsPlatform = $IsWindows -or $env:OS -eq 'Windows_NT'
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

function Report-SameProcesses([int[]] $ExpectedIds, [string] $Phase) {
    $actual = @(Get-MillProcesses | ForEach-Object { [int]$_.Id })
    $missing = @($ExpectedIds | Where-Object { $_ -notin $actual })
    $alive = @($ExpectedIds | Where-Object { $_ -in $actual })
    $expectedText = $ExpectedIds -join ','
    $aliveText = $alive -join ','
    $missingText = $missing -join ','
    Write-Host "CHAR-04 observation after ${Phase}: expectedPids=$expectedText; alivePids=$aliveText; exitedPids=$missingText"
    return [pscustomobject]@{ Expected = $ExpectedIds; Alive = $alive; Exited = $missing }
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
    Write-Host "CHAR-02 observation: rawLauncherExitCode=$($rawStartup.ExitCode) (the daemon process is inspected independently)."
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
        Write-Host "CHAR-01 observation: daemonPid=$($daemon.Id); classpathProvenance=$kind"
        Write-Host "  $($daemon.CommandLine)"
    }

    Write-Host "CHAR-01 summary: daemonCount=$($daemons.Count); anyLocalRepoMarker=$daemonMentionsLocalRepo"
    # Keep subsequent observations attached to the daemon started by the raw launcher.
    # The startup command exit code is recorded separately and does not gate these observations.
    $rawDaemonIds = @($daemons | ForEach-Object { [int]$_.Id })
    $compile = Invoke-Mill $rawMill @('__.compile') 'raw client compile to start Zinc workers'
    Write-Host "Raw compile client exit code: $($compile.ExitCode) (processes are inspected independently)."
    $stillRawDaemons = @(Get-MillProcesses | Where-Object { $_.Kind -eq 'daemon' -and $_.Id -in $rawDaemonIds })
    Write-Host "CHAR-04 observation after raw compile: originalRawDaemonAlive=$($stillRawDaemons.Count -gt 0)"
    $processes = @(Get-MillProcesses)
    $daemons = @($processes | Where-Object Kind -eq 'daemon')
    $workers = @($processes | Where-Object Kind -eq 'worker')

    $workerMentionsLocalRepo = $false
    Write-Host "CHAR-03/04 process inventory: daemonCount=$($daemons.Count); zincWorkerCount=$($workers.Count)"
    foreach ($worker in $workers) {
        $normalized = $worker.CommandLine.Replace('\', '/').ToLowerInvariant()
        $mentions = $normalized.Contains($localRepoMarker)
        if ($mentions) { $workerMentionsLocalRepo = $true }
        $kind = if ($mentions) { 'localRepo marker present' } else { 'no localRepo marker visible' }
        Write-Host "CHAR-03 observation: workerPid=$($worker.Id); classpathProvenance=$kind"
        Write-Host "  $($worker.CommandLine)"
    }

    Write-Host "CHAR-03 summary: anyWorkerLocalRepoMarker=$workerMentionsLocalRepo"
    $originalIds = @($processes | ForEach-Object { [int]$_.Id })
    $clean = Invoke-Mill $rawMill @('clean', 'dist.raw.localRepo') 'raw client clean while its daemon and Zinc workers are alive'
    $processSurvival = Report-SameProcesses $originalIds 'clean'

    $repoExistsAfterClean = Test-Path -LiteralPath $localRepo -PathType Container
    $platform = if ($isWindowsPlatform) { 'Windows' } elseif ($IsMacOS) { 'macOS' } else { 'Linux-or-other-POSIX' }
    Write-Host "CHAR-05 observation: platform=$platform; cleanExitCode=$($clean.ExitCode); localRepoExistsAfterClean=$repoExistsAfterClean"
    if ($IsMacOS) {
        Write-Host "CHAR-06 observation: macOS cleanExitCode=$($clean.ExitCode); localRepoExistsAfterClean=$repoExistsAfterClean; originalProcessesAlive=$($processSurvival.Exited.Count -eq 0)"
    }
    Write-Host 'CHARACTERIZATION SUMMARY: measured outcomes are reported without assuming a predetermined result.'
} finally {
    try { Stop-MillProcesses $rawMill 'raw characterization' } catch { Write-Host "Cleanup warning: $($_.Exception.Message)" }
    if (Test-Path -LiteralPath $localRepo) {
        try { [void](Invoke-Mill $bootstrapMill @('clean', 'dist.raw.localRepo') 'cleanup localRepo after characterization') }
        catch { Write-Host "Repository cleanup warning: $($_.Exception.Message)" }
    }
    try { Stop-MillProcesses $bootstrapMill 'post-characterization repository cleanup' } catch { Write-Host "Final cleanup warning: $($_.Exception.Message)" }
    Pop-Location
}
