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

function Invoke-Launcher([string] $Launcher, [string[]] $MillArgs, [string] $Scenario, [bool] $AllowNonZero = $false) {
    Write-Host ([Environment]::NewLine + '=== ' + $Scenario + ' ===')
    Write-Host "Launcher: $Launcher"
    Write-Host "Command: $($MillArgs -join ' ')"
    $lines = @(& $Launcher @MillArgs 2>&1 | ForEach-Object { $_.ToString() })
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

function Get-LockingProcessIds([string] $Path) {
    if ($isWindowsPlatform) {
        if (-not ('MillRawFileLockProbe' -as [type])) {
            $source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class MillRawFileLockProbe {
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
            List<int> ids = new List<int>();
            for (int i = 0; i < count; i++) ids.Add(infos[i].Process.dwProcessId);
            return ids.ToArray();
        } finally { RmEndSession(session); }
    }
}
'@
            Add-Type -TypeDefinition $source -Language CSharp
        }
        return @([MillRawFileLockProbe]::GetLockingProcessIds($Path))
    }
    $lsof = Get-Command lsof -ErrorAction SilentlyContinue
    if (-not $lsof) { throw 'lsof is required to verify open handles on Linux and macOS.' }
    $ids = @(& $lsof.Source -t -- $Path 2>$null)
    $code = $LASTEXITCODE
    if ($code -gt 1) { throw "lsof failed with exit code $code while checking $Path." }
    return @($ids | Where-Object { $_ -match '^\d+$' } | Sort-Object -Unique)
}

function Assert-NoOpenLocalRepoFiles([string] $Phase) {
    if (-not (Test-Path -LiteralPath $localRepo -PathType Container)) {
        Write-Host "PASS: localRepo does not exist after $Phase."
        return
    }
    $openFiles = [System.Collections.Generic.List[string]]::new()
    $processIds = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $localRepo -File -Recurse)) {
        $ids = @(Get-LockingProcessIds $file.FullName)
        if ($ids.Count -gt 0) {
            $openFiles.Add("$($file.FullName) (locking PIDs: $($ids -join ', '))")
            foreach ($id in $ids) { [void]$processIds.Add([int]$id) }
        }
    }
    if ($openFiles.Count -gt 0) {
        $details = foreach ($id in @($processIds)) {
            if ($isWindowsPlatform) {
                try {
                    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $id" -ErrorAction Stop
                    if ($null -eq $process) { "PID $id (already exited)" }
                    else { "PID $id $($process.Name)" + [Environment]::NewLine + "  $($process.CommandLine)" }
                } catch { "PID $id (details unavailable: $($_.Exception.Message))" }
            } else {
                $process = @(& ps -p $id -o pid=,comm=,args= 2>$null)
                if ($process.Count -gt 0) { $process -join ' ' } else { "PID $id (already exited)" }
            }
        }
        throw "Open localRepo files detected after ${Phase}:" + [Environment]::NewLine +
            ($openFiles -join [Environment]::NewLine) + [Environment]::NewLine +
            "Locking processes:" + [Environment]::NewLine + ($details -join [Environment]::NewLine)
    }
    Write-Host "PASS: no open files under localRepo after $Phase."
}

function Stop-Mill([string] $Launcher) {
    $processes = @(Get-MillProcesses)
    if ($processes.Count -eq 0) { return }
    $ids = @($processes | ForEach-Object Id)
    try { Invoke-Launcher $Launcher @('shutdown') 'shutdown' $true | Out-Null } catch {}
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $remaining = @(Get-MillProcesses | Where-Object { $_.Id -in $ids })
        if ($remaining.Count -eq 0) { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($Launcher -ne $bootstrap) {
        try { Invoke-Launcher $bootstrap @('shutdown') 'bootstrap shutdown fallback' $true | Out-Null } catch {}
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            $remaining = @(Get-MillProcesses | Where-Object { $_.Id -in $ids })
            if ($remaining.Count -eq 0) { return }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $deadline)
    }
    throw "Mill processes did not exit during cleanup: $((@($remaining | ForEach-Object { "$($_.Kind):$($_.Id)" })) -join ', ')"
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
    Assert-NoOpenLocalRepoFiles 'raw daemon startup'

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
