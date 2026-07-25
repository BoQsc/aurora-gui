$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$pythonCommand = if ($env:PYTHON) { $env:PYTHON } else { "python" }
& $pythonCommand (Join-Path $root "tools/release.py") --root $root @args
exit $LASTEXITCODE
