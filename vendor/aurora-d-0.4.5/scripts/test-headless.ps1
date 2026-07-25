$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$compiler = if ($env:DC) { $env:DC } else { "ldc2" }
$dubCommand = if ($env:DUB) { $env:DUB } else { "dub" }
Push-Location $root
try {
  & $dubCommand run --config=headless-test --build=debug --compiler=$compiler --force
  exit $LASTEXITCODE
}
finally {
  Pop-Location
}
