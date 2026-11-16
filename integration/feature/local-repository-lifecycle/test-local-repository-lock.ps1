# Target-requirement coverage:
# - LRL-TAR-01: verify repository files are not left open after resolution.
# - LRL-TAR-02: verify clean physically removes localRepo while daemon/workers remain alive.
# - LRL-TAR-06: report locked files and the processes holding them.
# LRL-TAR-03/04/05/07/08 are covered by focused companion scripts.
$ErrorActionPreference = 'Stop'
$isWindowsPlatform = $IsWindows -or $env:OS -eq 'Windows_NT'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$launcher = Join-Path $repoRoot $(if ($isWindowsPlatform) { 'mill.bat' } else { 'mill' })
$localRepo = Join-Path $repoRoot 'out/dist/raw/localRepo.dest'

function Invoke-Mill([string[]] $Args, [string] $Scenario) {
    Write-Host ([Environment]::NewLine + '=== ' + $Scenario + ' ===')
    Write-Host "Command: $($Args -join ' ')"
    $lines = @(& $launcher @Args 2>&1 | ForEach-Object { $_.ToString() })
    $code = $LASTEXITCODE
    $lines | ForEach-Object { Write-Host $_ }
    if ($code -ne 0) { throw "$Scenario failed with exit code $code" }
    Write-Host "PASS: $Scenario"
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
                $id = [int]$parts[0]
                if ($parts[1] -like '*mill.daemon.MillDaemonMain*') {
                    [pscustomobject]@{ Id = $id; Kind = 'daemon'; CommandLine = $parts[1] }
                } elseif ($parts[1] -like '*mill.javalib.worker.MillJvmWorkerMain*') {
                    [pscustomobject]@{ Id = $id; Kind = 'worker'; CommandLine = $parts[1] }
                }
            }
        }
    }
}

function Assert-NoOpenLocalRepoFiles([string] $Phase) {
    if (-not (Test-Path -LiteralPath $localRepo -PathType Container)) {
        Write-Host "PASS: localRepo does not exist after $Phase."
        return
    }
    $open = [System.Collections.Generic.List[string]]::new()
    $allPids = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $localRepo -File -Recurse)) {
        $pids = @(Get-LockingProcessIds $file.FullName)
        if ($pids.Count -gt 0) {
            $open.Add("$($file.FullName) (locking PIDs: $($pids -join ', '))")
            foreach ($id in $pids) { [void]$allPids.Add([int]$id) }
        }
    }
    if ($open.Count -gt 0) {
        $pidList = @($allPids)
        $message = "OPEN FILES DETECTED after $Phase:" + [Environment]::NewLine +
            ($open -join [Environment]::NewLine) + [Environment]::NewLine +
            "Processes:" + [Environment]::NewLine + (Format-LockingProcesses $pidList)
        Write-Host "FAIL: $message"
        throw $message
    }
    Write-Host "PASS: no open files under localRepo after $Phase."
}

function Assert-DaemonClasspathOutsideLocalRepo([string] $Phase) {
    $needle = $localRepo.Replace('\','/').ToLowerInvariant()
    $daemons = @(Get-MillProcesses | Where-Object Kind -eq 'daemon')
    if ($daemons.Count -eq 0) { throw "No Mill daemon found after $Phase." }
    foreach ($daemon in $daemons) {
        if ($daemon.CommandLine.Replace('\','/').ToLowerInvariant().Contains($needle)) {
            throw "Mill daemon PID $($daemon.Id) has a runner classpath entry under localRepo after $Phase."
        }
    }
    Write-Host "PASS: daemon runner classpath does not reference localRepo after $Phase."
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
    throw "Mill processes did not exit: $((@($remaining | ForEach-Object { "$($_.Kind):$($_.Id)" })) -join ', ')"
}

Push-Location $repoRoot
try {
    Invoke-Mill @('show','dist.raw.localRepo') 'initial repository resolution'
    if (-not (Test-Path -LiteralPath $localRepo -PathType Container)) { throw "localRepo was not created: $localRepo" }
    if (@(Get-ChildItem -LiteralPath $localRepo -File -Recurse).Count -eq 0) { throw 'localRepo was created but is empty.' }
    Assert-DaemonClasspathOutsideLocalRepo 'initial repository resolution'
    Assert-NoOpenLocalRepoFiles 'initial repository resolution'

    Invoke-Mill @('__.compile') 'compile to start Zinc workers'
    $processes = @(Get-MillProcesses)
    $daemons = @($processes | Where-Object Kind -eq 'daemon')
    $workers = @($processes | Where-Object Kind -eq 'worker')
    if ($daemons.Count -eq 0 -or $workers.Count -eq 0) {
        throw "Expected a live daemon and Zinc worker after compile; daemon=$($daemons.Count), worker=$($workers.Count)."
    }
    $expectedIds = @($processes | ForEach-Object Id)
    Assert-DaemonClasspathOutsideLocalRepo 'compile'
    Assert-NoOpenLocalRepoFiles 'compile with daemon and workers alive'

    Invoke-Mill @('clean','dist.raw.localRepo') 'clean while daemon and workers remain alive'
    if (Test-Path -LiteralPath $localRepo) { throw "clean succeeded but localRepo still exists: $localRepo" }
    $remaining = @(Get-MillProcesses | Where-Object { $_.Id -in $expectedIds })
    if ($remaining.Count -ne $expectedIds.Count) {
        throw "Original daemon/worker processes were not preserved through clean."
    }
    Write-Host 'PASS: clean physically removed localRepo while original daemon and Zinc workers remained alive.'
} finally {
    try { Stop-Mill } catch { Write-Host "Cleanup warning: $($_.Exception.Message)" }
    Pop-Location
}
