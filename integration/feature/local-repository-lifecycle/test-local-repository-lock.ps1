# Cross-platform regression test for open handles in dist.raw.localRepo.
# Successful unlink on Unix is not sufficient: inspect OS-level handles on every OS.
$ErrorActionPreference = 'Stop'
$isWindowsPlatform = $IsWindows -or $env:OS -eq 'Windows_NT'
$launcherName = if ($isWindowsPlatform) { 'mill.bat' } else { 'mill' }
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$bootstrapMill = Join-Path $repoRoot $launcherName
$rawMill = Join-Path $repoRoot 'out/dist/raw/executable.dest' $launcherName
$localRepo = Join-Path $repoRoot 'out/dist/raw/localRepo.dest'
$failures = [System.Collections.Generic.List[string]]::new()
if (-not (Test-Path -LiteralPath $bootstrapMill -PathType Leaf)) { throw "Bootstrap launcher not found: $bootstrapMill" }

function Write-LocalRepoLockDiagnostics([string] $Scenario) {
    if (-not (Test-Path -LiteralPath $localRepo -PathType Container)) { return }
    Write-Host "Lock diagnostics for ${Scenario}:"
    $files = @(Get-ChildItem -LiteralPath $localRepo -File -Recurse | Select-Object -First 20)
    $reported = 0
    foreach ($file in $files) {
        try {
            $pids = @(Get-LockingProcessIds $file.FullName)
            if ($pids.Count -gt 0) {
                $reported++
                Write-Host "  $($file.FullName) (locking PIDs: $($pids -join ', '))"
                Write-Host (Format-LockingProcesses $pids)
            }
        } catch {
            Write-Host "  $($file.FullName) (lock diagnostics unavailable: $($_.Exception.Message))"
        }
    }
    if ($reported -eq 0) {
        Write-Host "  No open files found in the first $($files.Count) files inspected."
    }
}

function Invoke-Mill([string] $Launcher, [string[]] $MillArgs, [string] $Scenario) {
    Write-Host ([Environment]::NewLine + '=== ' + $Scenario + ' ===')
    Write-Host "Launcher: $Launcher"
    Write-Host "Command: $($MillArgs -join ' ')"
    $lines = @(& $Launcher @MillArgs 2>&1 | ForEach-Object { $_.ToString() })
    $code = $LASTEXITCODE
    $lines | ForEach-Object { Write-Host $_ }
    if ($code -ne 0) {
        Write-LocalRepoLockDiagnostics $Scenario
        throw "$Scenario failed with exit code $code"
    }
    Write-Host "PASS: $Scenario"
    return $code
}

function Get-WindowsLockingProcessIds([string] $Path) {
    if (-not ('MillFileLockProbe' -as [type])) {
        $source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class MillFileLockProbe {
    [StructLayout(LayoutKind.Sequential)]
    private struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string strServiceShortName;
        public int ApplicationType; public uint AppStatus; public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmStartSession(out uint sessionHandle, int flags, StringBuilder sessionKey);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmRegisterResources(uint sessionHandle, uint fileCount,
        [In, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] files,
        uint appCount, IntPtr apps, uint serviceCount, IntPtr services);
    [DllImport("rstrtmgr.dll")]
    private static extern int RmGetList(uint sessionHandle, out uint needed, ref uint count,
        [In, Out] RM_PROCESS_INFO[] affectedApps, ref uint rebootReasons);
    [DllImport("rstrtmgr.dll")] private static extern int RmEndSession(uint sessionHandle);
    public static int[] GetLockingProcessIds(string path) {
        uint session; StringBuilder key = new StringBuilder(33);
        int rc = RmStartSession(out session, 0, key);
        if (rc != 0) throw new InvalidOperationException("RmStartSession failed: " + rc);
        try {
            rc = RmRegisterResources(session, 1, new string[] { path }, 0, IntPtr.Zero, 0, IntPtr.Zero);
            if (rc != 0) throw new InvalidOperationException("RmRegisterResources failed: " + rc);
            uint needed, count = 0, reasons = 0;
            rc = RmGetList(session, out needed, ref count, null, ref reasons);
            if (rc == 0 || needed == 0) return new int[0];
            if (rc != 234) throw new InvalidOperationException("RmGetList failed: " + rc);
            RM_PROCESS_INFO[] infos = new RM_PROCESS_INFO[needed]; count = needed;
            rc = RmGetList(session, out needed, ref count, infos, ref reasons);
            if (rc != 0) throw new InvalidOperationException("RmGetList failed: " + rc);
            List<int> pids = new List<int>();
            for (int i = 0; i < count; i++) pids.Add(infos[i].Process.dwProcessId);
            return pids.ToArray();
        } finally { RmEndSession(session); }
    }
}
'@
        Add-Type -TypeDefinition $source -Language CSharp
    }
    return @([MillFileLockProbe]::GetLockingProcessIds($Path))
}
function Get-LockingProcessIds([string] $Path) {
    if ($isWindowsPlatform) { return @(Get-WindowsLockingProcessIds $Path) }
    $lsof = Get-Command lsof -ErrorAction SilentlyContinue
    if (-not $lsof) { throw 'lsof is required to verify open handles on Linux and macOS.' }
    $ids = @(& $lsof.Source -t -- $Path 2>$null)
    $rc = $LASTEXITCODE
    if ($rc -gt 1) { throw "lsof failed with exit code $rc while checking $Path." }
    return @($ids | Where-Object { $_ -match '^\d+$' } | Sort-Object -Unique)
}
function Format-LockingProcesses([int[]] $ProcessIds) {
    $details = foreach ($processId in $ProcessIds) {
        if ($isWindowsPlatform) {
            try {
                $p = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop
                if ($null -eq $p) { "PID $processId (already exited)" }
                else { "PID $processId $($p.Name)" + [Environment]::NewLine + "  $($p.CommandLine)" }
            } catch { "PID $processId (details unavailable: $($_.Exception.Message))" }
        } else {
            $p = @(& ps -p $processId -o pid=,comm=,args= 2>$null)
            if ($p.Count) { $p -join ' ' } else { "PID $processId (already exited)" }
        }
    }
    return ($details -join [Environment]::NewLine)
}
function Assert-LocalRepoHasNoOpenFiles([string] $Phase) {
    if (-not (Test-Path -LiteralPath $localRepo -PathType Container)) { Write-Host "PASS: localRepo does not exist after $Phase."; return }
    $files = @(Get-ChildItem -LiteralPath $localRepo -File -Recurse)
    $open = [System.Collections.Generic.List[string]]::new()
    $allPids = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($file in $files) {
        $pids = @(Get-LockingProcessIds $file.FullName)
        if ($pids.Count -gt 0) {
            $open.Add($file.FullName + " (locking PIDs: " + ($pids -join ", ") + ")")
            foreach ($processId in $pids) { [void]$allPids.Add([int]$processId) }
        }
    }
    if ($open.Count -gt 0) {
        $pidList = @($allPids)
        $message = "OPEN FILES DETECTED after $($Phase):" + [Environment]::NewLine +
            ($open -join [Environment]::NewLine) + [Environment]::NewLine +
            "Processes:" + [Environment]::NewLine + (Format-LockingProcesses $pidList)
        $failures.Add($message); Write-Host "FAIL: $message"
    } else { Write-Host "PASS: no open files anywhere under localRepo after $($Phase) ($($files.Count) files checked)." }
}

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
            $parts = $line.Trim() -split '\s+', 2
            if ($parts.Count -eq 2) {
                $processId = [int]$parts[0]
                $commandLine = $parts[1]
                if ($commandLine -like '*mill.daemon.MillDaemonMain*') {
                    [pscustomobject]@{ Id = $processId; Kind = 'daemon'; CommandLine = $commandLine }
                } elseif ($commandLine -like '*mill.javalib.worker.MillJvmWorkerMain*') {
                    [pscustomobject]@{ Id = $processId; Kind = 'worker'; CommandLine = $commandLine }
                }
            }
        }
    }
}
function Assert-MillDaemonClasspathDoesNotReferenceLocalRepo([string] $Phase) {
    $needle = $localRepo.Replace('\', '/').ToLowerInvariant()
    $daemons = @(Get-MillProcesses | Where-Object Kind -eq 'daemon')
    if ($daemons.Count -eq 0) {
        throw "No Mill daemon process was found while checking its runner classpath after $Phase."
    }
    foreach ($daemon in $daemons) {
        $normalized = $daemon.CommandLine.Replace('\', '/').ToLowerInvariant()
        if ($normalized.Contains($needle)) {
            throw "Mill daemon PID $($daemon.Id) was launched with runner classpath entries from the temporary localRepo after $Phase. The daemon outlives the launcher command and keeps those JARs open on Windows."
        }
    }
    Write-Host "PASS: Mill daemon runner classpath is independent of localRepo after $Phase."
}

function Assert-MillDaemonClasspathOutsideLocalRepo([string] $Phase) {
    $needle = $localRepo.Replace('\', '/').ToLowerInvariant()
    $daemons = @(Get-MillProcesses | Where-Object Kind -eq 'daemon')
    if ($daemons.Count -eq 0) {
        throw "No Mill daemon process was found while checking its runtime classpath after $Phase."
    }
    foreach ($daemon in $daemons) {
        $commandLine = $daemon.CommandLine.Replace('\', '/').ToLowerInvariant()
        if ($commandLine.Contains($needle)) {
            throw "Mill daemon PID $($daemon.Id) has a runtime classpath that references the deletable localRepo after $Phase: $($daemon.CommandLine)"
        }
        Write-Host "PASS: daemon PID $($daemon.Id) runtime classpath does not reference localRepo after $Phase."
    }
}

function Assert-MillProcesses([string] $Phase) {
    $processes = @(Get-MillProcesses)
    $daemons = @($processes | Where-Object Kind -eq 'daemon')
    $workers = @($processes | Where-Object Kind -eq 'worker')
    Write-Host "Mill processes after $Phase : daemon=$($daemons.Count), workers=$($workers.Count)"
    $processes | ForEach-Object { Write-Host "  $($_.Kind) PID=$($_.Id) $($_.CommandLine)" }
    if ($daemons.Count -eq 0) { throw "No Mill daemon process was found after $Phase." }
    if ($workers.Count -eq 0) { throw "No Mill JVM worker process was found after $Phase; worker lifecycle was not exercised." }
    return @($processes | ForEach-Object { "$($_.Kind):$($_.Id)" } | Sort-Object -Unique)
}

function Write-MillRuntimeClasspathDiagnostics([string] $Phase) {
    $needle = $localRepo.Replace('\', '/').ToLowerInvariant()
    $processes = @(Get-MillProcesses)
    Write-Host "Runtime classpath diagnostics after $Phase :"
    foreach ($process in $processes) {
        $normalized = $process.CommandLine.Replace('\', '/').ToLowerInvariant()
        $mentionsLocalRepo = $normalized.Contains($needle)
        if ($process.Kind -eq 'worker') {
            if ($mentionsLocalRepo) {
                throw "Zinc worker PID $($process.Id) has explicit subprocess classpath entries from the temporary localRepo after $Phase."
            } else {
                Write-Host "  worker PID=$($process.Id): command line does not reference localRepo."
            }
            Write-Host "    Full command line: $($process.CommandLine)"
        } else {
            Write-Host "  daemon PID=$($process.Id): command line does not expose the in-process URLClassLoader classpath."
            Write-Host "    Full command line: $($process.CommandLine)"
        }
    }
    Write-Host "  IMPORTANT: command-line inspection is conclusive only for an explicit subprocess classpath."
    Write-Host "  It cannot establish the origin of JARs loaded by the daemon's internalWorkerClassLoader."
    Write-Host "  A missing localRepo path above is not evidence that the daemon is independent of localRepo."
}
function Assert-SameMillProcesses([string[]] $Expected, [string] $Phase) {
    $actual = @(Get-MillProcesses | ForEach-Object { "$($_.Kind):$($_.Id)" } | Sort-Object -Unique)
    $missing = @($Expected | Where-Object { $_ -notin $actual })
    if ($missing.Count -gt 0) { throw "Mill processes exited or were replaced during $Phase : $($missing -join ', ')." }
    Write-Host "PASS: original daemon and worker PIDs are still alive after $Phase."
}

function Stop-MillProcesses([string] $Launcher, [string] $Phase) {
    $processes = @(Get-MillProcesses)
    if ($processes.Count -eq 0) {
        Write-Host "INFO: no Mill daemon or workers remain after $Phase."
        return
    }

    $processIds = @($processes | ForEach-Object { $_.Id })
    [void](Invoke-Mill $Launcher @('shutdown') "$Phase / shutdown")
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $remaining = @(Get-MillProcesses | Where-Object { $_.Id -in $processIds })
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    if ($remaining.Count -gt 0) {
        throw "Mill processes did not exit after $Phase / shutdown: $((@($remaining | ForEach-Object { "$($_.Kind):$($_.Id)" })) -join ', ')."
    }
    Write-Host "PASS: daemon and workers exited after $Phase / shutdown; the next launcher scenario starts cleanly."
}

function Run-LauncherMatrix([string] $Launcher, [string] $Label, [bool] $VerifyRebuildAfterClean = $true) {
    # Start the daemon without evaluating localRepo, then inspect the actual
    # daemon JVM command line before localRepo task cleanup can mask the cause.
    [void](Invoke-Mill $Launcher @('show', 'millVersion') "$Label / daemon startup")
    Assert-MillDaemonClasspathOutsideLocalRepo "$Label / daemon startup"
    [void](Invoke-Mill $Launcher @('show', 'dist.raw.localRepo') "$Label / initial show")
    Assert-MillDaemonClasspathDoesNotReferenceLocalRepo "$Label / initial show"
    Assert-LocalRepoHasNoOpenFiles "$Label / initial show"
    [void](Invoke-Mill $Launcher @('show', 'dist.raw.localRepo') "$Label / repeated show (daemon reuse)")
    Assert-LocalRepoHasNoOpenFiles "$Label / repeated show"
    [void](Invoke-Mill $Launcher @('__.compile') "$Label / compile to start Zinc workers")
    $processesBeforeClean = Assert-MillProcesses "$Label / compile"
    # Report explicit subprocess classpaths, but do not infer the daemon's
    # in-process URLClassLoader origin from its command line.
    Write-MillRuntimeClasspathDiagnostics "$Label / compile"
    Assert-LocalRepoHasNoOpenFiles "$Label / daemon and workers active"
    [void](Invoke-Mill $Launcher @('clean', 'dist.raw.localRepo') "$Label / clean with daemon and workers alive")
    Assert-SameMillProcesses $processesBeforeClean "$Label / clean"
    if (Test-Path -LiteralPath $localRepo) { throw "$Label / clean succeeded but localRepo still exists: $localRepo" }
    Write-Host "PASS: localRepo was physically removed while daemon and workers remained alive."
    if ($VerifyRebuildAfterClean) {
        [void](Invoke-Mill $Launcher @('show', 'dist.raw.localRepo') "$Label / rebuild after clean")
        if (-not (Test-Path -LiteralPath $localRepo -PathType Container)) { throw "$Label / rebuild did not recreate localRepo." }
        $rebuiltFiles = @(Get-ChildItem -LiteralPath $localRepo -File -Recurse)
        if ($rebuiltFiles.Count -eq 0) { throw "$Label / rebuilt localRepo is empty." }
        Assert-LocalRepoHasNoOpenFiles "$Label / rebuild after clean"
        [void](Invoke-Mill $Launcher @('show', 'dist.raw.localRepo') "$Label / reuse daemon after rebuild")
        Assert-SameMillProcesses $processesBeforeClean "$Label / reuse after rebuild"
        Assert-LocalRepoHasNoOpenFiles "$Label / reuse after rebuild"
    } else {
        Write-Host "INFO: skipping raw-launcher rebuild after clean; bootstrap-launcher scenario covers rebuild independently, avoiding the unrelated SNAPSHOT daemon-resolution path."
    }
}
Push-Location $repoRoot
try {
    Write-Host "OS: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
    $buildCode = Invoke-Mill $bootstrapMill @('show', 'dist.raw.executable') 'bootstrap / build raw executable'
    if ($buildCode -ne 0) { throw 'Cannot run launcher matrix because dist.raw.executable did not build.' }
    if (-not (Test-Path -LiteralPath $rawMill -PathType Leaf)) { throw "Raw launcher not found: $rawMill" }
    # The build step may itself start workers. Do not let its daemon or workers
    # contaminate the launcher matrix that follows.
    Stop-MillProcesses $bootstrapMill 'bootstrap / build raw executable'
    foreach ($entry in @(
        # Run bootstrap first; Stop-MillProcesses below shuts down its daemon and
        # workers before the raw-launcher scenario uses the shared output tree.
        @{ Launcher = $bootstrapMill; Label = 'bootstrap launcher'; VerifyRebuildAfterClean = $true },
        # The raw launcher's post-clean rebuild may resolve the daemon SNAPSHOT
        # from external repositories after localRepo has intentionally been removed.
        # Keep that unrelated resolution path out of this handle regression test.
        @{ Launcher = $rawMill; Label = 'raw launcher'; VerifyRebuildAfterClean = $false }
    )) {
        try {
            Run-LauncherMatrix $entry.Launcher $entry.Label $entry.VerifyRebuildAfterClean
        } catch {
            $message = "$($entry.Label): $($_.Exception.Message)"
            $failures.Add($message)
            Write-Host "FAIL: $message"
            if ($entry.Label -eq 'raw launcher') {
                try {
                    Assert-MillDaemonClasspathDoesNotReferenceLocalRepo "$($entry.Label) / failed initial show diagnostics"
                } catch {
                    $diagnostic = "$($entry.Label) runner classpath: $($_.Exception.Message)"
                    $failures.Add($diagnostic)
                    Write-Host "FAIL: $diagnostic"
                }
            }
        } finally {
            # Each launcher scenario intentionally keeps its daemon and Zinc
            # workers alive through clean. Shut them down only after that
            # scenario has completed, so the next launcher cannot inherit
            # file handles to the shared dist.raw.localRepo output directory.
            try {
                Stop-MillProcesses $entry.Launcher $entry.Label
            } catch {
                $message = "$($entry.Label) isolation cleanup: $($_.Exception.Message)"
                $failures.Add($message)
                Write-Host "FAIL: $message"
            }
        }
    }
    if ($failures.Count -gt 0) {
        throw ("Local repository open-handle regression failures ($($failures.Count)):" +
            [Environment]::NewLine + ' - ' + ($failures -join ([Environment]::NewLine + ' - ')))
    }
    Write-Host 'PASS: all launcher scenarios completed with no open files under localRepo at any checkpoint.'
} finally { Pop-Location }
