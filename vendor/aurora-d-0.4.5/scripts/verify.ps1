$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$compiler = if ($env:DC) { $env:DC } else { "ldc2" }
$dubCommand = if ($env:DUB) { $env:DUB } else { "dub" }
$pythonCommand = if ($env:PYTHON) { $env:PYTHON } else { "python" }
$ucd = if ($env:AURORA_UCD_ROOT) { $env:AURORA_UCD_ROOT } else { "tools/unicode/17.0.0" }

function Invoke-Checked {
  param([string]$File, [string[]]$Arguments)
  & $File @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code $LASTEXITCODE`: $File $($Arguments -join ' ')"
  }
}

Push-Location $root
try {
  $metadata = Get-Content "dub.json" -Raw | ConvertFrom-Json
  Write-Host "Aurora-D $($metadata.version) verification with $compiler"

  foreach ($name in @("GraphemeBreakTest.txt", "LineBreakTest.txt", "BidiTest.txt", "BidiCharacterTest.txt")) {
    if (-not (Test-Path (Join-Path $ucd $name))) {
      throw "Unicode 17 conformance data is incomplete at $ucd (missing $name)"
    }
  }

  Invoke-Checked $pythonCommand @("tools/verify_assets.py", "--root", $root)
  Invoke-Checked $dubCommand @("test", "--config=library", "--build=unittest", "--compiler=$compiler", "--force")

  foreach ($config in @("headless-test", "public-api-test", "text-system-test", "text-boundaries", "dpi-rendering-test", "compositor-test", "latency-test", "desktop-shell-test", "shell-visual-test")) {
    Write-Host "Running $config"
    Invoke-Checked $dubCommand @("run", "--config=$config", "--build=debug", "--compiler=$compiler", "--force")
  }

  Write-Host "Running Unicode 17 conformance corpora"
  Invoke-Checked $dubCommand @("run", "--config=unicode-conformance", "--build=debug", "--compiler=$compiler", "--force", "--", $ucd)

  foreach ($config in @("library", "notepad", "file-explorer", "desktop", "taskbar", "font-gallery", "vulkan-smoke")) {
    Write-Host "Building $config"
    Invoke-Checked $dubCommand @("build", "--config=$config", "--build=debug", "--compiler=$compiler", "--force")
  }

  Write-Host "Aurora-D $($metadata.version) verification completed successfully."
}
finally {
  Pop-Location
}
