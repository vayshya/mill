# Observational follow-up scenarios for LRL-CHAR-07..10.
$ErrorActionPreference = 'Stop'
$win = $IsWindows -or $env:OS -eq 'Windows_NT'
$name = if ($win) { 'mill.bat' } else { 'mill' }
$root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$bootstrap = Join-Path $root $name
$raw = Join-Path $root 'out/dist/raw/executable.dest' $name
$repo = Join-Path $root 'out/dist/raw/localRepo.dest'
function Processes {
    if ($win) {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name = 'java.exe' OR Name = 'javaw.exe'")) {
            if ($p.CommandLine -like '*mill.daemon.MillDaemonMain*') { [pscustomobject]@{ Id=[int]$p.ProcessId; Kind='daemon'; CommandLine=$p.CommandLine } }
            elseif ($p.CommandLine -like '*mill.javalib.worker.MillJvmWorkerMain*') { [pscustomobject]@{ Id=[int]$p.ProcessId; Kind='worker'; CommandLine=$p.CommandLine } }
        }
    } else {
        foreach ($line in @(& ps -eo pid=,args=)) {
            if ($line -match '^\s*(\d+)\s+(.*)$') {
                if ($Matches[2].Contains('mill.daemon.MillDaemonMain')) { [pscustomobject]@{ Id=[int]$Matches[1]; Kind='daemon'; CommandLine=$Matches[2] } }
                elseif ($Matches[2].Contains('mill.javalib.worker.MillJvmWorkerMain')) { [pscustomobject]@{ Id=[int]$Matches[1]; Kind='worker'; CommandLine=$Matches[2] } }
            }
        }
    }
}
function Observe([string]$launcher,[string[]]$millArgs,[string]$label) {
    Write-Host ''
    Write-Host "=== $label ==="
    $out = @(& $launcher @millArgs 2>&1 | ForEach-Object { $_.ToString() }); $code = $LASTEXITCODE
    $out | ForEach-Object { Write-Host $_ }
    Write-Host "OBSERVATION: label=$label; exitCode=$code"
    [pscustomobject]@{ ExitCode=$code; Output=$out }
}
function Inventory([string]$phase) {
    if (-not (Test-Path -LiteralPath $repo -PathType Container)) { Write-Host "CHAR-09: phase=$phase; exists=false; files=0"; return @() }
    $items = @(Get-ChildItem -LiteralPath $repo -File -Recurse | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{ Path=$_.FullName.Substring($repo.Length).TrimStart([char[]]@('\','/')); Size=$_.Length; Hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
    Write-Host "CHAR-09: phase=$phase; exists=true; files=$($items.Count); bytes=$(($items | Measure-Object Size -Sum).Sum)"
    foreach ($x in $items) { Write-Host "  $($x.Path) | $($x.Size) | $($x.Hash)" }
    return $items
}
function Shutdown([string]$launcher,[string]$label) {
    $ids = @((Processes | ForEach-Object Id))
    if ($ids.Count) { [void](Observe $launcher @('shutdown') "$label shutdown") }
    $until = [DateTime]::UtcNow.AddSeconds(30)
    do { $left = @(Processes | Where-Object { $_.Id -in $ids }); if (-not $left.Count) { break }; Start-Sleep -Milliseconds 250 } while ([DateTime]::UtcNow -lt $until)
    Write-Host "PROCESS: $label; original=$($ids -join ','); remaining=$(@($left | ForEach-Object Id) -join ',')"
}
Push-Location $root
try {
    Write-Host "OS: $([Runtime.InteropServices.RuntimeInformation]::OSDescription)"
    if (-not (Test-Path $bootstrap -PathType Leaf)) { throw "Missing bootstrap launcher: $bootstrap" }
    [void](Observe $bootstrap @('show','dist.raw.executable') 'build raw launcher prerequisite')
    if (-not (Test-Path $raw -PathType Leaf)) { throw "Missing raw launcher: $raw" }
    Shutdown $bootstrap 'isolate prior processes'
    [void](Observe $raw @('show','millVersion') 'start initial raw daemon')
    [void](Observe $raw @('show','dist.raw.localRepo') 'initial repository resolve')
    $initial = @(Inventory 'initial publication')
    $originalIds = @((Processes | ForEach-Object Id))
    $clean = Observe $raw @('clean','dist.raw.localRepo') 'same-daemon clean'
    $empty = @(Inventory 'immediately after clean')
    $resolve = Observe $raw @('show','dist.raw.localRepo') 'same-daemon resolve after clean'
    $after = @(Inventory 'after same-daemon resolve')
    $alive = @(Processes | Where-Object { $_.Id -in $originalIds })
    Write-Host "CHAR-07: clean=$($clean.ExitCode); resolve=$($resolve.ExitCode); originalProcessesAlive=$($alive.Count -eq $originalIds.Count); filesAfterResolve=$($after.Count)"
    [void](Observe $raw @('clean','dist.raw.localRepo') 'clean before fresh daemon')
    Shutdown $raw 'stop original daemon for fresh-daemon observation'
    Write-Host "CHAR-08 pre-start: localRepoExists=$(Test-Path -LiteralPath $repo -PathType Container)"
    $freshStart = Observe $raw @('show','millVersion') 'fresh raw daemon startup after clean'
    $freshDaemons = @(Processes | Where-Object Kind -eq 'daemon')
    $freshPids = @($freshDaemons | ForEach-Object Id)
    foreach ($daemon in $freshDaemons) {
        $normalizedCommandLine = $daemon.CommandLine.Replace('\', '/').ToLowerInvariant()
        $hasLocalRepoMarker = $normalizedCommandLine.Contains('localrepo.dest')
        $usesCoursierFileCache = $hasLocalRepoMarker -and $normalizedCommandLine.Contains('/coursier/cache/v1/file/')
        Write-Host "CHAR-08 daemon classpath: pid=$($daemon.Id); localRepoMarker=$hasLocalRepoMarker; coursierFileCachePath=$usesCoursierFileCache"
        Write-Host $daemon.CommandLine
    }
    $freshResolve = Observe $raw @('show','dist.raw.localRepo') 'fresh daemon repository resolve'
    $freshItems = @(Inventory 'fresh daemon resolve')
    Write-Host "CHAR-08: startup=$($freshStart.ExitCode); daemonPids=$($freshPids -join ','); resolve=$($freshResolve.ExitCode); files=$($freshItems.Count)"
    [void](Observe $raw @('clean','dist.raw.localRepo') 'CHAR-10 clean before publication one')
    $pub1 = Observe $raw @('show','dist.raw.localRepo') 'CHAR-10 publish and resolve one'
    $one = @(Inventory 'CHAR-10 publication one')
    [void](Observe $raw @('clean','dist.raw.localRepo') 'CHAR-10 clean between publications')
    $middle = @(Inventory 'CHAR-10 after intermediate clean')
    $pub2 = Observe $raw @('show','dist.raw.localRepo') 'CHAR-10 publish and resolve two'
    $two = @(Inventory 'CHAR-10 publication two')
    $a=@{}; foreach($x in $one){$a[$x.Path]="$($x.Size):$($x.Hash)"}
    $b=@{}; foreach($x in $two){$b[$x.Path]="$($x.Size):$($x.Hash)"}
    $added=@($b.Keys|Where-Object{-not $a.ContainsKey($_)})
    $removed=@($a.Keys|Where-Object{-not $b.ContainsKey($_)})
    $changed=@($a.Keys|Where-Object{$b.ContainsKey($_)-and $a[$_] -ne $b[$_]})
    Write-Host "CHAR-10: publish1=$($pub1.ExitCode); publish2=$($pub2.ExitCode); counts=$($one.Count)/$($two.Count); added=$($added.Count); removed=$($removed.Count); changed=$($changed.Count)"
    Write-Host "CHAR-10 differences: added=$($added -join ';'); removed=$($removed -join ';'); changed=$($changed -join ';')"
    Write-Host 'Characterization finished; outcomes are observations, not predetermined assertions.'
} finally {
    try { Shutdown $raw 'final raw cleanup' } catch { Write-Host "Cleanup warning: $($_.Exception.Message)" }
    if (Test-Path -LiteralPath $repo) { try { [void](Observe $bootstrap @('clean','dist.raw.localRepo') 'final repository cleanup') } catch { Write-Host "Repository cleanup warning: $($_.Exception.Message)" } }
    try { Shutdown $bootstrap 'final bootstrap cleanup' } catch { Write-Host "Final bootstrap cleanup warning: $($_.Exception.Message)" }
    Pop-Location
}