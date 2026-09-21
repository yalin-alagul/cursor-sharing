[CmdletBinding()]
param(
    [switch]$SelfContained
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root 'apps\windows\SideCursor.Windows\SideCursor.Windows.csproj'
$output = Join-Path $root 'dist\windows'
$arguments = @('publish', $project, '-c', 'Release', '-r', 'win-x64', '-o', $output)

if ($SelfContained) {
    $arguments += @('--self-contained', 'true', '-p:PublishSingleFile=true')
} else {
    $arguments += @('--self-contained', 'false')
}

& dotnet @arguments
Write-Host "Built $output"
