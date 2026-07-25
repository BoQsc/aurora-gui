$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$compiler = if ($env:DC) { $env:DC } else { "ldc2" }
$dubCommand = if ($env:DUB) { $env:DUB } else { "dub" }
$configs = @("notepad", "file-explorer", "desktop", "taskbar", "font-gallery")

Push-Location $root
try {
  foreach ($config in $configs) {
    Write-Host "Building $config with $compiler"
    & $dubCommand build --config=$config --build=release --compiler=$compiler --force
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }

  Write-Host "Built all Aurora-D demos. Run one with:"
  Write-Host "  $dubCommand run --config=notepad --compiler=$compiler"
}
finally {
  Pop-Location
}
