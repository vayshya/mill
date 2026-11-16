# Target-requirement coverage:
# - LRL-TAR-07: keep an active consumer pinned to the initial local-repository
#   generation while a concurrent Mill operation republishes the repository;
#   verify the consumer retains a consistent initial state and the new
#   repository remains complete.
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
$newReleaseFile = Join-Path $workDir 'new-release'
$consumerOutput = Join-Path $workDir 'consumer.out'
$consumerError = Join-Path $workDir 'consumer.err'
$newConsumerOutput = Join-Path $workDir 'new-consumer.out'
$newConsumerError = Join-Path $workDir 'new-consumer.err'

function Invoke-Mill([string] $Launcher, [string[]] $MillArgs, [string] $Scenario) {
    Write-Host ([Environment]::NewLine + '=== ' + $Scenario + ' ===')
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
      if (entries == 0) throw new IllegalStateException("Initial repository JAR is empty");
      if (jf.getManifest() == null) throw new IllegalStateException("Initial repository JAR has no manifest");
      out.println("OPEN");
      out.flush();
      while (!release.exists()) Thread.sleep(100);
      if (jf.size() != entries) throw new IllegalStateException("Initial repository JAR changed while active");
      if (jf.getManifest() == null) throw new IllegalStateException("Initial repository JAR became inconsistent");
      out.println("CONSISTENT");
      out.flush();
    }
  }
}
'@ | Set-Content -LiteralPath $helperSource -Encoding UTF8
    $javac = Get-Command javac -ErrorAction SilentlyContinue
    if (-not $javac) { throw 'JDK with javac is required for LRL-TAR-07 active-consumer verification.' }
    & $javac.Source -d $helperClasses $helperSource
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the LRL-TAR-07 repository consumer helper.' }
}

function Start-RepositoryConsumer([string] $JarPath, [string] $ReleasePath, [string] $OutputPath, [string] $ErrorPath) {
    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
    if (Test-Path -LiteralPath $ErrorPath) { Remove-Item -LiteralPath $ErrorPath -Force }
    $java = (Get-Command java -ErrorAction Stop).Source
    Start-Process -FilePath $java -ArgumentList @('-cp', $helperClasses, 'RepositoryConsumer', $JarPath, $ReleasePath, $OutputPath) -RedirectStandardError $ErrorPath -PassThru -NoNewWindow
}

New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Push-Location $repoRoot
$consumer = $null
$newConsumer = $null
try {
    New-ConsumerHelper
    if (-not (Test-Path -LiteralPath $bootstrapMill -PathType Leaf)) { throw "Bootstrap launcher not found: $bootstrapMill" }

    Invoke-Mill $bootstrapMill @('show', 'dist.raw.localRepo') 'initial repository publication'
    $initialInventory = Get-RepositoryInventory
    $initialJar = $initialInventory | Where-Object { $_.RelativePath -like '*.jar' } | Select-Object -First 1
    if ($null -eq $initialJar) { throw 'No JAR artifact was found in the initial local repository.' }
    $initialJarPath = Join-Path $localRepo $initialJar.RelativePath
    $initialJarHash = (Get-FileHash -LiteralPath $initialJarPath -Algorithm SHA256).Hash

    $consumer = Start-RepositoryConsumer $initialJarPath $releaseFile $consumerOutput $consumerError
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 100
        if (Test-Path -LiteralPath $consumerOutput) {
            if ((Get-Content -LiteralPath $consumerOutput -Raw) -match '(?m)^OPEN$') { break }
        }
        if ($consumer.HasExited) { throw "Active repository consumer exited early. stderr: $(Get-Content -LiteralPath $consumerError -Raw)" }
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not (Test-Path -LiteralPath $consumerOutput) -or (Get-Content -LiteralPath $consumerOutput -Raw) -notmatch '(?m)^OPEN$') {
        throw 'Timed out waiting for the active repository consumer to open the initial artifact.'
    }

    $publisherOutput = Join-Path $workDir 'publisher.out'
    $publisherError = Join-Path $workDir 'publisher.err'
    $publisher = Start-Process -FilePath $bootstrapMill -ArgumentList @('clean', 'dist.raw.localRepo', '+', 'show', 'dist.raw.localRepo') -RedirectStandardOutput $publisherOutput -RedirectStandardError $publisherError -PassThru -NoNewWindow
    $publisher.WaitForExit()
    if ($publisher.ExitCode -ne 0) {
        throw "Concurrent repository publication failed with exit code $($publisher.ExitCode). stderr: $(Get-Content -LiteralPath $publisherError -Raw)"
    }

    if (-not (Test-Path -LiteralPath $initialJarPath -PathType Leaf)) {
        throw 'Concurrent publication removed the initial artifact while its consumer was still active.'
    }
    $activeJarHash = (Get-FileHash -LiteralPath $initialJarPath -Algorithm SHA256).Hash
    if ($activeJarHash -ne $initialJarHash) {
        throw 'Concurrent publication modified the artifact observed by the active consumer.'
    }

    $newJar = Get-RepositoryInventory | Where-Object { $_.RelativePath -eq $initialJar.RelativePath } | Select-Object -First 1
    if ($null -eq $newJar) { throw 'Republished repository does not contain the artifact used by the new consumer.' }
    $newJarPath = Join-Path $localRepo $newJar.RelativePath
    $newConsumer = Start-RepositoryConsumer $newJarPath $newReleaseFile $newConsumerOutput $newConsumerError
    $newDeadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 100
        if (Test-Path -LiteralPath $newConsumerOutput) {
            if ((Get-Content -LiteralPath $newConsumerOutput -Raw) -match '(?m)^OPEN
    $initialPaths = @($initialInventory | ForEach-Object RelativePath)
    $rebuiltPaths = @($rebuiltInventory | ForEach-Object RelativePath)
    $missing = @($initialPaths | Where-Object { $_ -notin $rebuiltPaths })
    if ($missing.Count -gt 0) { throw "Concurrent publication left the repository incomplete. Missing: $($missing -join ', ')" }

    Write-Host 'PASS: LRL-TAR-07 active consumer retained a consistent initial repository state during concurrent publication.'
    Write-Host "PASS: republished repository contains $($rebuiltInventory.Count) files."
} finally {
    if ($null -ne $consumer -and -not $consumer.HasExited) {
        try { New-Item -ItemType File -Force -Path $releaseFile | Out-Null; $consumer.WaitForExit(5000) | Out-Null } catch {}
        if (-not $consumer.HasExited) { Stop-Process -Id $consumer.Id -Force }
    }
    if ($null -ne $newConsumer -and -not $newConsumer.HasExited) {
        try { New-Item -ItemType File -Force -Path $newReleaseFile | Out-Null; $newConsumer.WaitForExit(5000) | Out-Null } catch {}
        if (-not $newConsumer.HasExited) { Stop-Process -Id $newConsumer.Id -Force }
    }
    Pop-Location
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
}
) { break }
        }
        if ($newConsumer.HasExited) { throw "New repository consumer exited early. stderr: $(Get-Content -LiteralPath $newConsumerError -Raw)" }
    } while ([DateTime]::UtcNow -lt $newDeadline)
    if (-not (Test-Path -LiteralPath $newConsumerOutput) -or (Get-Content -LiteralPath $newConsumerOutput -Raw) -notmatch '(?m)^OPEN
    $initialPaths = @($initialInventory | ForEach-Object RelativePath)
    $rebuiltPaths = @($rebuiltInventory | ForEach-Object RelativePath)
    $missing = @($initialPaths | Where-Object { $_ -notin $rebuiltPaths })
    if ($missing.Count -gt 0) { throw "Concurrent publication left the repository incomplete. Missing: $($missing -join ', ')" }

    Write-Host 'PASS: LRL-TAR-07 active consumer retained a consistent initial repository state during concurrent publication.'
    Write-Host "PASS: republished repository contains $($rebuiltInventory.Count) files."
} finally {
    if ($null -ne $consumer -and -not $consumer.HasExited) {
        try { New-Item -ItemType File -Force -Path $releaseFile | Out-Null; $consumer.WaitForExit(5000) | Out-Null } catch {}
        if (-not $consumer.HasExited) { Stop-Process -Id $consumer.Id -Force }
    }
    Pop-Location
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
}
) {
        throw 'Timed out waiting for the new repository consumer to open the republished artifact.'
    }

    New-Item -ItemType File -Force -Path $releaseFile | Out-Null
    $consumer.WaitForExit()
    if ($consumer.ExitCode -ne 0) { throw "Active repository consumer observed an inconsistent initial state. stderr: $(Get-Content -LiteralPath $consumerError -Raw)" }
    if ((Get-Content -LiteralPath $consumerOutput -Raw) -notmatch '(?m)^CONSISTENT
    $initialPaths = @($initialInventory | ForEach-Object RelativePath)
    $rebuiltPaths = @($rebuiltInventory | ForEach-Object RelativePath)
    $missing = @($initialPaths | Where-Object { $_ -notin $rebuiltPaths })
    if ($missing.Count -gt 0) { throw "Concurrent publication left the repository incomplete. Missing: $($missing -join ', ')" }

    Write-Host 'PASS: LRL-TAR-07 active consumer retained a consistent initial repository state during concurrent publication.'
    Write-Host "PASS: republished repository contains $($rebuiltInventory.Count) files."
} finally {
    if ($null -ne $consumer -and -not $consumer.HasExited) {
        try { New-Item -ItemType File -Force -Path $releaseFile | Out-Null; $consumer.WaitForExit(5000) | Out-Null } catch {}
        if (-not $consumer.HasExited) { Stop-Process -Id $consumer.Id -Force }
    }
    Pop-Location
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
}
) { throw 'Active repository consumer did not report a consistent initial state.' }

    New-Item -ItemType File -Force -Path $newReleaseFile | Out-Null
    $newConsumer.WaitForExit()
    if ($newConsumer.ExitCode -ne 0) { throw "New repository consumer observed an inconsistent republished state. stderr: $(Get-Content -LiteralPath $newConsumerError -Raw)" }
    if ((Get-Content -LiteralPath $newConsumerOutput -Raw) -notmatch '(?m)^CONSISTENT
    $initialPaths = @($initialInventory | ForEach-Object RelativePath)
    $rebuiltPaths = @($rebuiltInventory | ForEach-Object RelativePath)
    $missing = @($initialPaths | Where-Object { $_ -notin $rebuiltPaths })
    if ($missing.Count -gt 0) { throw "Concurrent publication left the repository incomplete. Missing: $($missing -join ', ')" }

    Write-Host 'PASS: LRL-TAR-07 active consumer retained a consistent initial repository state during concurrent publication.'
    Write-Host "PASS: republished repository contains $($rebuiltInventory.Count) files."
} finally {
    if ($null -ne $consumer -and -not $consumer.HasExited) {
        try { New-Item -ItemType File -Force -Path $releaseFile | Out-Null; $consumer.WaitForExit(5000) | Out-Null } catch {}
        if (-not $consumer.HasExited) { Stop-Process -Id $consumer.Id -Force }
    }
    Pop-Location
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
}
) { throw 'New repository consumer did not report a consistent republished state.' }

    $rebuiltInventory = Get-RepositoryInventory
    $initialPaths = @($initialInventory | ForEach-Object RelativePath)
    $rebuiltPaths = @($rebuiltInventory | ForEach-Object RelativePath)
    $missing = @($initialPaths | Where-Object { $_ -notin $rebuiltPaths })
    if ($missing.Count -gt 0) { throw "Concurrent publication left the repository incomplete. Missing: $($missing -join ', ')" }

    Write-Host 'PASS: LRL-TAR-07 active consumer retained a consistent initial repository state during concurrent publication.'
    Write-Host "PASS: republished repository contains $($rebuiltInventory.Count) files."
} finally {
    if ($null -ne $consumer -and -not $consumer.HasExited) {
        try { New-Item -ItemType File -Force -Path $releaseFile | Out-Null; $consumer.WaitForExit(5000) | Out-Null } catch {}
        if (-not $consumer.HasExited) { Stop-Process -Id $consumer.Id -Force }
    }
    Pop-Location
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
}
