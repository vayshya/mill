[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ScriptPath
)
$ErrorActionPreference = 'Stop'
$resolvedPath = (Resolve-Path -LiteralPath $ScriptPath -ErrorAction Stop).Path
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($resolvedPath, [ref] $tokens, [ref] $parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
    foreach ($parseError in $parseErrors) {
        Write-Host ('ERROR: {0}:{1}:{2}: {3}' -f $resolvedPath, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
    }
    throw "PowerShell syntax validation failed: $resolvedPath"
}
Write-Host "PASS: PowerShell syntax: $resolvedPath"
