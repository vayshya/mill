# Cross-platform regression test: ensure Mill does not keep the local-repository SNAPSHOT JAR open.
$ErrorActionPreference = 'Stop'
$isWindowsPlatform = $IsWindows -or $env:OS -eq 'Windows_NT'
$launcherName = if ($isWindowsPlatform) { 'mill.bat' } else { 'mill' }
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$mill = Join-Path $repoRoot (Join-Path 'out/dist/raw/executable.dest' $launcherName)
$jarPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'out/dist/raw/localRepo.dest/com/lihaoyi/mill-contrib-buildinfo_3/SNAPSHOT/mill-contrib-buildinfo_3-SNAPSHOT.jar'))
if (-not (Test-Path $mill -PathType Leaf)) { throw "Raw platform launcher not found: $mill. Build it first with ./mill dist.raw.executable." }

function Invoke-MillAndCapture([string[]] $MillArgs) {
    $lines = @(& $mill @MillArgs 2>&1 | ForEach-Object { $_.ToString() })
    $code = $LASTEXITCODE
    $lines | ForEach-Object { Write-Host $_ }
    return @{ ExitCode = $code; Output = ($lines -join [Environment]::NewLine) }
}
function Test-LocalRepoLockError([string] $Output) {
    # Use literal fragments: PowerShell single-quoted strings preserve backslashes,
    # and a regex escape before the F in FileSystemException is invalid in .NET.
    return $Output.Contains('java.nio.file.FileSystemException:') -and
        $Output.Contains('localRepo.dest') -and
        $Output.Contains('mill-contrib-buildinfo_3-SNAPSHOT.jar')
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
    private struct RM_UNIQUE_PROCESS {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
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
    [DllImport("rstrtmgr.dll")]
    private static extern int RmEndSession(uint sessionHandle);
    public static int[] GetLockingProcessIds(string path) {
        uint session;
        StringBuilder key = new StringBuilder(33);
        int rc = RmStartSession(out session, 0, key);
        if (rc != 0) throw new InvalidOperationException("RmStartSession failed: " + rc);
        try {
            rc = RmRegisterResources(session, 1, new string[] { path }, 0, IntPtr.Zero, 0, IntPtr.Zero);
            if (rc != 0) throw new InvalidOperationException("RmRegisterResources failed: " + rc);
            uint needed, count = 0, reasons = 0;
            rc = RmGetList(session, out needed, ref count, null, ref reasons);
            if (rc == 0 || needed == 0) return new int[0];
            if (rc != 234) throw new InvalidOperationException("RmGetList failed: " + rc);
            RM_PROCESS_INFO[] infos = new RM_PROCESS_INFO[needed];
            count = needed;
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
    if (-not $lsof) { throw 'lsof is required to verify open JAR handles on Linux and macOS.' }
    $ids = @(& $lsof.Source -t -- $Path 2>$null)
    $lsofExitCode = $LASTEXITCODE
    if ($lsofExitCode -gt 1) { throw "lsof failed with exit code $lsofExitCode while checking $Path." }
    return @($ids | Where-Object { $_ -match '^\d+$' } | Sort-Object -Unique)
}
function Format-LockingProcesses([int[]] $ProcessIds) {
    $details = foreach ($processId in $ProcessIds) {
        if ($isWindowsPlatform) {
            try {
                $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop
                if ($null -eq $process) {
                    "  PID: $processId (process exited before details could be collected)"
                } else {
                    @(
                        "  PID: $($process.ProcessId)"
                        "    Name: $($process.Name)"
                        "    ExecutablePath: $($process.ExecutablePath)"
                        "    CommandLine: $($process.CommandLine)"
                    )
                }
            } catch {
                "  PID: $processId (could not query process details: $($_.Exception.Message))"
            }
        } else {
            $processInfo = @(& ps -p $processId -o pid=,comm=,args= 2>$null)
            if ($processInfo.Count -gt 0) {
                "  PID / command: $($processInfo -join ' ')"
            } else {
                "  PID: $processId (process exited before details could be collected)"
            }
        }
    }
    return ($details -join [Environment]::NewLine)
}
function Assert-JarNotOpen([string] $Path, [string] $Phase) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ("Expected SNAPSHOT JAR does not exist after " + $Phase + ": " + $Path) }
    $processIds = @(Get-LockingProcessIds $Path)
    if ($processIds.Count -gt 0) {
        throw ("FILE LOCK DETECTED after " + $Phase + ": " + $Path + " is open by process(es): " + ($processIds -join ', ') + [Environment]::NewLine + (Format-LockingProcesses $processIds))
    }
    Write-Host ("PASS: no process has the SNAPSHOT JAR open after " + $Phase + ".")
}
Push-Location $repoRoot
try {
    Write-Host "Evaluating dist.raw.localRepo on $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)..."
    $result = Invoke-MillAndCapture @('show', 'dist.raw.localRepo')
    if ($result.ExitCode -ne 0) {
        if (Test-LocalRepoLockError $result.Output) {
            try {
                $processIds = @(Get-LockingProcessIds $jarPath)
                if ($processIds.Count -gt 0) {
                    throw ("FILE LOCK DETECTED while evaluating dist.raw.localRepo; process ID(s) using the JAR: " + ($processIds -join ', ') + "." + [Environment]::NewLine + (Format-LockingProcesses $processIds))
                }
                throw 'FILE LOCK DETECTED while evaluating dist.raw.localRepo; Windows Restart Manager returned no process IDs for the locked JAR.'
            } catch {
                if ($_.Exception.Message -like 'FILE LOCK DETECTED*') { throw }
                throw ("FILE LOCK DETECTED while evaluating dist.raw.localRepo, but process lookup failed: " + $_.Exception.Message)
            }
        }
        throw "Mill failed while evaluating dist.raw.localRepo (exit code $($result.ExitCode))."
    }
    # Linux allows unlinking open files; inspect OS-level handles before cleanup.
    Assert-JarNotOpen $jarPath 'show dist.raw.localRepo'
    Write-Host 'Cleaning dist.raw.localRepo in a subsequent Mill invocation...'
    $result = Invoke-MillAndCapture @('clean', 'dist.raw.localRepo')
    if ($result.ExitCode -ne 0) {
        if (Test-LocalRepoLockError $result.Output) {
            try {
                $processIds = @(Get-LockingProcessIds $jarPath)
                if ($processIds.Count -gt 0) {
                    throw ("FILE LOCK DETECTED while cleaning dist.raw.localRepo; process ID(s) using the JAR: " + ($processIds -join ', ') + "." + [Environment]::NewLine + (Format-LockingProcesses $processIds))
                }
                throw 'FILE LOCK DETECTED while cleaning dist.raw.localRepo; process lookup returned no process IDs.'
            } catch {
                if ($_.Exception.Message -like 'FILE LOCK DETECTED*') { throw }
                throw ("FILE LOCK DETECTED while cleaning dist.raw.localRepo, but process lookup failed: " + $_.Exception.Message)
            }
        }
        throw "Mill clean failed (exit code $($result.ExitCode))."
    }
    Write-Host 'PASS: localRepo evaluated and cleaned; no process held the SNAPSHOT JAR open.'
} finally { Pop-Location }
