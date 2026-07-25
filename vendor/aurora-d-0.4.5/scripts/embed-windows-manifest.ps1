param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Executable
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$manifest = Join-Path $root "resources/windows/aurora.manifest"
$target = (Resolve-Path $Executable).Path

$mt = Get-Command "mt.exe" -ErrorAction SilentlyContinue
if (-not $mt) {
  throw "mt.exe was not found. Install the Windows SDK only when optional manifest embedding is required. Aurora's default DUB builds do not need it."
}

& $mt.Source -nologo -manifest $manifest "-outputresource:$target;#1"
if ($LASTEXITCODE -ne 0) {
  throw "mt.exe failed with exit code $LASTEXITCODE"
}

Write-Host "Embedded Aurora Per-Monitor-V2 manifest in $target"
