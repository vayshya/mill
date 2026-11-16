# Cross-platform regression test for open handles in dist.raw.localRepo.
# Successful unlink on Unix is not sufficient: inspect OS-level handles on every OS.
$ErrorActionPreference = 'Stop'
$isWindowsPlatform = $IsWindows -or $env:OS -eq 'Windows_NT'
$launcherName = if ($isWindowsPlatform) { 'mill.bat' } else { 'mill' }
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$bootstrapMill = Join-Path $repoRoot $launcherName
$rawMill = Join-Path $repoRoot 'out/dist/raw/executable.dest' $launcherName
$localRepo = Join-Path $repoRoot 'out/dist/raw/localRepo.dest'
$failures = [System.Collections.Generic.List[string]]::new()
if (-not (Test-Path -LiteralPath $bootstrapMill -PathType Leaf)) { throw "Bootstrap launcher not found: $bootstrapMill" }

function Invoke-Mill([string] $Launcher, [string[]] $MillArgs, [string] $Scenario) {
    Write-Host ([Environment]::NewLine + '=== ' + $Scenario + ' ===')
    Write-Host "Launcher: $Launcher"
    Write-Host "Command: $($MillArgs -join ' ')"
    $lines = @(& $Launcher @MillArgs 2>&1 | ForEach-Object { $_.ToString() })
    $code = $LASTEXITCODE
    $lines | ForEach-Object { Write-Host $_ }
    if ($code -ne 0) { throw "$Scenario failed with exit code $code" }
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

function Assert-MillClasspathsOutsideLocalRepo([string] $Phase, [bool] $Required) {
    $needle = $localRepo.Replace('\', '/').ToLowerInvariant()
    $usingLocalRepo = @(
        Get-MillProcesses | Where-Object {
            $_.CommandLine.Replace('\', '/').ToLowerInvariant().Contains($needle)
        }
    )
    if ($usingLocalRepo.Count -gt 0) {
        $details = $usingLocalRepo | ForEach-Object { "$($_.Kind) PID=$($_.Id): $($_.CommandLine)" }
        $message = "Daemon/worker runtime classpaths still reference localRepo after " + $Phase + ":" +
            [Environment]::NewLine + ($details -join [Environment]::NewLine)
        if ($Required) {
            $failures.Add($message)
            Write-Host "FAIL: $message"
        } else {
            Write-Host "INFO: $message"
        }
    } else {
        Write-Host "PASS: daemon and worker runtime classpaths are outside localRepo after $Phase."
    }
}

function Assert-SameMillProcesses([string[]] $Expected, [string] $Phase) {
    $actual = @(Get-MillProcesses | ForEach-Object { "$($_.Kind):$($_.Id)" } | Sort-Object -Unique)
    $missing = @($Expected | Where-Object { $_ -notin $actual })
    if ($missing.Count -gt 0) { throw "Mill processes exited or were replaced during $Phase : $($missing -join ', ')." }
    Write-Host "PASS: original daemon and worker PIDs are still alive after $Phase."
}

function Run-LauncherMatrix([string] $Launcher, [string] $Label) {
    [void](Invoke-Mill $Launcher @('show', 'dist.raw.localRepo') "$Label / initial show")
    Assert-LocalRepoHasNoOpenFiles "$Label / initial show"
    [void](Invoke-Mill $Launcher @('show', 'dist.raw.localRepo') "$Label / repeated show (daemon reuse)")
    Assert-LocalRepoHasNoOpenFiles "$Label / repeated show"
    [void](Invoke-Mill $Launcher @('__.compile') "$Label / compile to start Zinc workers")
    $processesBeforeClean = Assert-MillProcesses "$Label / compile"
    # The raw launcher is expected to resolve its runtime from localRepo; that is
    # precisely the configuration under test for the open-handle regression.
    # The bootstrap launcher must remain isolated from localRepo.
    Assert-MillClasspathsOutsideLocalRepo "$Label / compile" ($Label -eq 'bootstrap launcher')
    Assert-LocalRepoHasNoOpenFiles "$Label / daemon and workers active"
    [void](Invoke-Mill $Launcher @('clean', 'dist.raw.localRepo') "$Label / clean with daemon and workers alive")
    Assert-SameMillProcesses $processesBeforeClean "$Label / clean"
    if (Test-Path -LiteralPath $localRepo) { throw "$Label / clean succeeded but localRepo still exists: $localRepo" }
    Write-Host "PASS: localRepo was physically removed while daemon and workers remained alive."
    [void](Invoke-Mill $Launcher @('show', 'dist.raw.localRepo') "$Label / rebuild after clean")
    if (-not (Test-Path -LiteralPath $localRepo -PathType Container)) { throw "$Label / rebuild did not recreate localRepo." }
    $rebuiltFiles = @(Get-ChildItem -LiteralPath $localRepo -File -Recurse)
    if ($rebuiltFiles.Count -eq 0) { throw "$Label / rebuilt localRepo is empty." }
    Assert-LocalRepoHasNoOpenFiles "$Label / rebuild after clean"
    [void](Invoke-Mill $Launcher @('show', 'dist.raw.localRepo') "$Label / reuse daemon after rebuild")
    Assert-SameMillProcesses $processesBeforeClean "$Label / reuse after rebuild"
    Assert-LocalRepoHasNoOpenFiles "$Label / reuse after rebuild"
}
Push-Location $repoRoot
try {
    Write-Host "OS: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
    $buildCode = Invoke-Mill $bootstrapMill @('show', 'dist.raw.executable') 'bootstrap / build raw executable'
    if ($buildCode -ne 0) { throw 'Cannot run launcher matrix because dist.raw.executable did not build.' }
    if (-not (Test-Path -LiteralPath $rawMill -PathType Leaf)) { throw "Raw launcher not found: $rawMill" }
    foreach ($entry in @(
        @{ Launcher = $rawMill; Label = 'raw launcher' },
        @{ Launcher = $bootstrapMill; Label = 'bootstrap launcher' }
    )) {
        try {
            Run-LauncherMatrix $entry.Launcher $entry.Label
        } catch {
            $message = "$($entry.Label): $($_.Exception.Message)"
            $failures.Add($message)
            Write-Host "FAIL: $message"
        }
    }
    if ($failures.Count -gt 0) {
        throw ("Local repository open-handle regression failures ($($failures.Count)):" +
            [Environment]::NewLine + ' - ' + ($failures -join ([Environment]::NewLine + ' - ')))
    }
    Write-Host 'PASS: all launcher scenarios completed with no open files under localRepo at any checkpoint.'
} finally { Pop-Location }
