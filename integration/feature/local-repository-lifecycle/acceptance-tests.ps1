[CmdletBinding()]
param(
    [string] $ImageTag = 'mill-local-repository-lifecycle:local',
    [string] $CacheVolume = 'mill-local-repository-lifecycle-coursier'
)

$ErrorActionPreference = 'Stop'

$featureDirectory = $PSScriptRoot
$repositoryRoot = (& git -C $featureDirectory rev-parse --show-toplevel)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to locate the Git repository root.'
}
$repositoryRoot = ($repositoryRoot | Select-Object -First 1).Trim()

$scenarios = @(
    'characterization',
    'lock',
    'rebuild',
    'raw-launcher',
    'concurrency',
    'resolution-characterization'
)

Push-Location -LiteralPath $repositoryRoot
try {
    Write-Host "Repository: $repositoryRoot"

    if ($IsLinux) {
        # On Linux, run the same isolated scenarios directly. The runner creates
        # a temporary worktree and overlays tracked and untracked checkout changes.
        $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
        if (-not $pwsh) {
            throw 'PowerShell 7 (pwsh) is required to run the Linux scenarios directly.'
        }
        if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
            throw 'Java is required. Install the configured JDK before running the scenarios.'
        }
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            throw 'Git is required to create isolated Linux scenario worktrees.'
        }
        if (-not (Get-Command lsof -ErrorAction SilentlyContinue)) {
            throw 'lsof is required by the Linux acceptance scenarios.'
        }

        $runner = Join-Path $featureDirectory 'run-linux-test.ps1'
        if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
            throw "Linux scenario runner not found: $runner"
        }

        $failed = [System.Collections.Generic.List[string]]::new()
        foreach ($scenario in $scenarios) {
            Write-Host ''
            Write-Host "########## Linux scenario: $scenario ##########"

            & $pwsh.Source -NoLogo -NoProfile -File $runner -Scenario $scenario -RepositoryPath $repositoryRoot
            $scenarioExitCode = $LASTEXITCODE
            if ($scenarioExitCode -eq 0) {
                Write-Host "PASS: Linux scenario '$scenario'."
            }
            else {
                Write-Warning "FAIL: Linux scenario '$scenario' (exit code $scenarioExitCode)."
                $failed.Add($scenario)
            }
        }

        if ($failed.Count -gt 0) {
            throw "Linux scenarios failed: $($failed -join ', ')"
        }

        Write-Host 'PASS: all six Linux local-repository-lifecycle scenarios (direct execution).'
    }
    else {
        $wslc = Get-Command wslc -ErrorAction SilentlyContinue
        if (-not $wslc) {
            throw 'WSL Containers CLI (wslc.exe) was not found. Install or enable WSL Containers first.'
        }

        $containerfile = Join-Path $featureDirectory 'Containerfile'
        if (-not (Test-Path -LiteralPath $containerfile -PathType Leaf)) {
            throw "Containerfile not found: $containerfile"
        }

        Write-Host "WSL Containers CLI: $($wslc.Source)"
        Write-Host "Image: $ImageTag"

        # Build from the repository root so the Containerfile and checkout are available.
        & wslc build --pull --file $containerfile --tag $ImageTag $repositoryRoot
        if ($LASTEXITCODE -ne 0) {
            throw "WSLC image build failed with exit code $LASTEXITCODE."
        }

        # Reuse the Coursier cache across the six isolated containers.
        $volumes = @(& wslc volume list --quiet)
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to list WSLC volumes.'
        }
        if ($volumes -notcontains $CacheVolume) {
            & wslc volume create $CacheVolume
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to create WSLC cache volume '$CacheVolume'."
            }
        }

        # WSLC accepts a Windows host path in Docker-style bind-mount syntax.
        $mountSource = $repositoryRoot.Replace('\\', '/')
        $repositoryMount = "type=bind,source=$mountSource,target=/workspace"
        $cacheMount = "type=volume,source=$CacheVolume,target=/root/.cache/coursier"

        $failed = [System.Collections.Generic.List[string]]::new()
        foreach ($scenario in $scenarios) {
            Write-Host ''
            Write-Host "########## Linux scenario: $scenario ##########"

            & wslc run --rm --mount $repositoryMount --mount $cacheMount $ImageTag $scenario
            $scenarioExitCode = $LASTEXITCODE
            if ($scenarioExitCode -eq 0) {
                Write-Host "PASS: Linux scenario '$scenario'."
            }
            else {
                Write-Warning "FAIL: Linux scenario '$scenario' (exit code $scenarioExitCode)."
                $failed.Add($scenario)
            }
        }

        if ($failed.Count -gt 0) {
            throw "Linux WSLC scenarios failed: $($failed -join ', ')"
        }

        Write-Host 'PASS: all six Linux local-repository-lifecycle scenarios (WSLC).'
    }
}
finally {
    Pop-Location
}
