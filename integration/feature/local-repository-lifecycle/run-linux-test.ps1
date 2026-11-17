[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('characterization', 'lock', 'rebuild', 'raw-launcher', 'concurrency', 'resolution-characterization')]
    [string] $Scenario,

    [string] $RepositoryPath = '/workspace',
    [string] $TrackedPath,
    [string] $DeletedFilesPath,
    [string] $UntrackedPath
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath $RepositoryPath).Path
$feature = 'integration/feature/local-repository-lifecycle'

$scenarioScripts = @{
    characterization = 'characterize-lifecycle.ps1'
    lock = 'acceptance-lock.ps1'
    rebuild = 'acceptance-rebuild.ps1'
    'raw-launcher' = 'acceptance-raw-launcher.ps1'
    concurrency = 'acceptance-concurrency.ps1'
    'resolution-characterization' = 'characterize-resolution.ps1'
}

git -C $repo rev-parse --show-toplevel *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Expected a Git checkout at $repo"
}

git config --global --add safe.directory '*'
if ($LASTEXITCODE -ne 0) { throw 'Failed to configure Git safe.directory.' }

$worktree = Join-Path ([System.IO.Path]::GetTempPath()) ("mill-lrl-" + [guid]::NewGuid().ToString('N'))
$localPatch = Join-Path ([System.IO.Path]::GetTempPath()) ("mill-lrl-" + [guid]::NewGuid().ToString('N') + '.patch')
$worktreeAdded = $false
$scenarioExitCode = 0

try {
    Write-Host "=== Linux scenario: $Scenario ==="
    git -C $repo worktree add --quiet --detach $worktree HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create an isolated Git worktree.' }
    $worktreeAdded = $true

    if ($TrackedPath) {
        # Local WSL runs receive only files Git reports as changed on the Windows checkout.
        foreach ($file in (Get-ChildItem -LiteralPath $TrackedPath -File -Recurse -Force)) {
            $relativePath = $file.FullName.Substring((Resolve-Path -LiteralPath $TrackedPath).Path.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            $destination = Join-Path $worktree $relativePath
            $destinationDirectory = Split-Path -Parent $destination
            New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        }
        if ($DeletedFilesPath -and (Test-Path -LiteralPath $DeletedFilesPath)) {
            foreach ($relativePath in (Get-Content -LiteralPath $DeletedFilesPath)) {
                if ($relativePath) {
                    Remove-Item -LiteralPath (Join-Path $worktree $relativePath) -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    else {
        # Docker CI runs from a mounted checkout; include its tracked working-tree edits.
        git -C $repo diff --binary --output=$localPatch HEAD
        if ($LASTEXITCODE -ne 0) { throw 'Failed to export tracked working-tree changes.' }
        if ((Get-Item -LiteralPath $localPatch).Length -gt 0) {
            git -C $worktree apply --binary $localPatch
            if ($LASTEXITCODE -ne 0) { throw 'Failed to apply tracked working-tree changes to the isolated worktree.' }
        }
    }

    if ($UntrackedPath) {
        if (Test-Path -LiteralPath $UntrackedPath) {
            $untrackedRoot = (Resolve-Path -LiteralPath $UntrackedPath).Path
            foreach ($file in (Get-ChildItem -LiteralPath $untrackedRoot -File -Recurse -Force)) {
                $relativePath = $file.FullName.Substring($untrackedRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
                $destination = Join-Path $worktree $relativePath
                $destinationDirectory = Split-Path -Parent $destination
                New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
            }
        }
    }
    elseif (-not $TrackedPath) {
        # Docker CI also copies untracked, non-ignored files from its mounted checkout.
        $untrackedOutput = git -C $repo ls-files --others --exclude-standard -z
        if ($LASTEXITCODE -ne 0) { throw 'Failed to enumerate untracked files.' }
        foreach ($relativePath in ($untrackedOutput -split [char]0 | Where-Object { $_ })) {
            $source = Join-Path $repo $relativePath
            if (Test-Path -LiteralPath $source) {
                $destination = Join-Path $worktree $relativePath
                $destinationDirectory = Split-Path -Parent $destination
                New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
                Copy-Item -LiteralPath $source -Destination $destination -Force
            }
        }
    }

    $testScript = Join-Path $worktree (Join-Path $feature $scenarioScripts[$Scenario])
    Push-Location -LiteralPath $worktree
    try {
        & pwsh -NoLogo -NoProfile -File $testScript
        $scenarioExitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}
finally {
    if ($worktreeAdded) {
        git -C $repo worktree remove --force $worktree
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Git could not remove temporary worktree $worktree; removing its directory."
            Remove-Item -LiteralPath $worktree -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $localPatch -Force -ErrorAction SilentlyContinue
}

if ($scenarioExitCode -ne 0) {
    exit $scenarioExitCode
}
