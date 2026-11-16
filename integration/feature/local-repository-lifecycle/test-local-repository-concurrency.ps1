# Target-requirement coverage:
# - LRL-TAR-07: an active consumer keeps reading the initial repository artifact
#   while a concurrent clean-and-republish operation creates the next repository.
$ErrorActionPreference = 'Stop'
$isWindowsPlatform = $IsWindows -or $env:OS -eq 'Windows_NT'
$launcherName = if ($isWindowsPlatform) { 'mill.bat' } else { 'mill' }
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$bootstrapMill = Join-Path $repoRoot $launcherName
$localRepo = Join-Path $repoRoot 'out/dist/raw/localRepo.dest'
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("mill-lrl-tar07-" + [guid]::NewGuid().ToString("N"))
$helperSource = Join-Path $workDir 'RepositoryConsumer.java'
$helperClasses = Join-Path $workDir 'classes'
$releaseFile = Join-Path $workDir 'release'
$consumerOutput = Join-Path $workDir 'consumer.out'
$consumerError = Join-Path $workDir 'consumer.err'

function Invoke-Mill([string] $Launcher, [string[]] $MillArgs, [string] $Scenario) {
    Write-Host ([Environment]::NewLine + '=== ' + $Scenario + ' ===')
    Write-Host "Command: $Launcher $($MillArgs -join ' ')"
    $lines = @(& $Launcher @MillArgs 2>&1 | ForEach-Object { $_.ToString() })
    $code = $LASTEXITCODE
    $lines | ForEach-Object { Write-Host $_ }
    if ($code -ne 0) { throw "$Scenario failed with exit code $code" }
}

function Get-RepositoryInventory {
    if (-not (Test-Path -LiteralPath $localRepo -PathType Container)) { throw "localRepo does not exist: $localRepo" }
    $files = @(Get-ChildItem -LiteralPath $localRepo -File -Recurse | Sort-Object FullName)
    if ($files.Count -eq 0) { throw "localRepo is empty: $localRepo" }
    @($files | ForEach-Object {
        [pscustomobject]@{
            RelativePath = $_.FullName.Substring($localRepo.Length).TrimStart([char[]]@('\','/'))
            Length = $_.Length
            Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    })
}

function New-ConsumerHelper {
    New-Item -ItemType Directory -Force -Path $helperClasses | Out-Null
    @'
import java.io.File;
import java.io.FileOutputStream;
import java.io.PrintWriter;
import java.util.jar.JarFile;
public class RepositoryConsumer {
  public static void main(String[] args) throws Exception {
    File jar = new File(args[0]);
    File release = new File(args[1]);
    File output = new File(args[2]);
    try (JarFile jf = new JarFile(jar); PrintWriter out = new PrintWriter(new FileOutputStream(output))) {
      int entries = jf.size();
      if (entries == 0 || jf.getManifest() == null) throw new IllegalStateException("Invalid initial JAR");
      out.println("OPEN");
      out.flush();
      while (!release.exists()) Thread.sleep(100);
      if (jf.size() != entries || jf.getManifest() == null) throw new IllegalStateException("JAR changed while consumer was active");
      out.println("CONSISTENT");
      out.flush();
    }
  }
}
'@ | Set-Content -LiteralPath $helperSource -Encoding UTF8
    $javac = Get-Command javac -ErrorAction SilentlyContinue
    if (-not $javac) { throw 'JDK with javac is required for LRL-TAR-07.' }
    & $javac.Source -d $helperClasses $helperSource
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the repository consumer helper.' }
}

function Start-RepositoryConsumer([string] $JarPath) {
    $java = (Get-Command java -ErrorAction Stop).Source
    Start-Process -FilePath $java -ArgumentList @('-cp', $helperClasses, 'RepositoryConsumer', $JarPath, $releaseFile, $consumerOutput) -RedirectStandardError $consumerError -PassThru -NoNewWindow
}

New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Push-Location $repoRoot
$consumer = $null
try {
    New-ConsumerHelper
    if (-not (Test-Path -LiteralPath $bootstrapMill -PathType Leaf)) { throw "Bootstrap launcher not found: $bootstrapMill" }

    Invoke-Mill $bootstrapMill @('show', 'dist.raw.localRepo') 'initial repository publication'
    $initialInventory = Get-RepositoryInventory
    $initialJar = $initialInventory | Where-Object { $_.RelativePath -like '*.jar' } | Select-Object -First 1
    if ($null -eq $initialJar) { throw 'No JAR artifact was found in localRepo.' }
    $initialJarPath = Join-Path $localRepo $initialJar.RelativePath
    $initialJarHash = (Get-FileHash -LiteralPath $initialJarPath -Algorithm SHA256).Hash

    $consumer = Start-RepositoryConsumer $initialJarPath
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 100
        if (Test-Path -LiteralPath $consumerOutput) {
            if ((Get-Content -LiteralPath $consumerOutput -Raw) -match '(?m)^OPEN$') { break }
        }
        if ($consumer.HasExited) { throw "Consumer exited early. stderr: $(Get-Content -LiteralPath $consumerError -Raw)" }
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not (Test-Path -LiteralPath $consumerOutput) -or (Get-Content -LiteralPath $consumerOutput -Raw) -notmatch '(?m)^OPEN$') {
        throw 'Timed out waiting for consumer to open the initial repository artifact.'
    }

    $publisherOutput = Join-Path $workDir 'publisher.out'
    $publisherError = Join-Path $workDir 'publisher.err'
    $publisher = Start-Process -FilePath $bootstrapMill -ArgumentList @('clean', 'dist.raw.localRepo', '+', 'show', 'dist.raw.localRepo') -RedirectStandardOutput $publisherOutput -RedirectStandardError $publisherError -PassThru -NoNewWindow
    $publisher.WaitForExit()
    if ($publisher.ExitCode -ne 0) {
        throw "Concurrent clean and publication failed with exit code $($publisher.ExitCode). stdout: $(Get-Content -LiteralPath $publisherOutput -Raw) stderr: $(Get-Content -LiteralPath $publisherError -Raw)"
    }

    if (-not (Test-Path -LiteralPath $initialJarPath -PathType Leaf)) {
        throw 'Concurrent publication removed the artifact while its consumer was active.'
    }
    if ((Get-FileHash -LiteralPath $initialJarPath -Algorithm SHA256).Hash -ne $initialJarHash) {
        throw 'Concurrent publication modified the artifact observed by the active consumer.'
    }

    $rebuiltInventory = Get-RepositoryInventory
    $initialPaths = @($initialInventory | ForEach-Object RelativePath)
    $rebuiltPaths = @($rebuiltInventory | ForEach-Object RelativePath)
    $missing = @($initialPaths | Where-Object { $_ -notin $rebuiltPaths })
    if ($missing.Count -gt 0) { throw "Republished repository is incomplete. Missing: $($missing -join ', ')" }

    New-Item -ItemType File -Force -Path $releaseFile | Out-Null
    $consumer.WaitForExit()
    if ($consumer.ExitCode -ne 0) { throw "Active consumer observed an inconsistent artifact. stderr: $(Get-Content -LiteralPath $consumerError -Raw)" }
    if ((Get-Content -LiteralPath $consumerOutput -Raw) -notmatch '(?m)^CONSISTENT$') {
        throw 'Active consumer did not confirm a consistent artifact.'
    }
    Write-Host 'PASS: LRL-TAR-07 active consumer retained a consistent artifact during concurrent repository publication.'
    Write-Host "PASS: republished repository contains $($rebuiltInventory.Count) files."
} finally {
    if ($null -ne $consumer -and -not $consumer.HasExited) {
        try { New-Item -ItemType File -Force -Path $releaseFile | Out-Null; $consumer.WaitForExit(5000) | Out-Null } catch {}
        if (-not $consumer.HasExited) { Stop-Process -Id $consumer.Id -Force }
    }
    Pop-Location
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
}
