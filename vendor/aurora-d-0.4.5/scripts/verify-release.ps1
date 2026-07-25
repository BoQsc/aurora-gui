$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$compiler = if ($env:DC) { $env:DC } else { "ldc2" }
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("aurora-release-check-" + [Guid]::NewGuid().ToString("N"))
$crossTargets = if ($env:AURORA_CROSS_TARGETS) { @($env:AURORA_CROSS_TARGETS -split "\s+" | Where-Object { $_ }) } else { @("x86_64-pc-windows-msvc", "x86_64-apple-darwin", "arm64-apple-darwin") }

function Invoke-Checked {
  param([string]$File, [string[]]$Arguments)
  & $File @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code $LASTEXITCODE`: $File $($Arguments -join ' ')"
  }
}

Push-Location $root
try {
  if ($env:AURORA_SKIP_BASE_VERIFY -eq "1") {
    Write-Host "Base verification explicitly skipped; running release-only gates."
  }
  else {
    & (Join-Path $scriptDir "verify.ps1")
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }

  New-Item -ItemType Directory -Force -Path (Join-Path $temp "host") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $temp "cross") | Out-Null

  Write-Host "Compiling host graphs with warnings treated as errors"
  $nativeSources = @(
    "source/aurora/package.d",
    "demos/notepad.d",
    "demos/file_explorer.d",
    "demos/desktop_environment.d",
    "demos/taskbar.d",
    "demos/font_gallery.d",
    "tests/vulkan_smoke.d"
  )
  foreach ($source in $nativeSources) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($source)
    Invoke-Checked $compiler @("-w", "-Isource", "-i", "-c", $source, "-of=$(Join-Path $temp "host/$name.o")")
  }

  $headlessSources = @(
    "tests/headless.d",
    "tests/public_api.d",
    "tests/text_system.d",
    "tests/text_boundaries.d",
    "tests/dpi_rendering.d",
    "tests/compositor.d",
    "tests/latency.d",
    "tests/desktop_shell.d",
    "tests/unicode_conformance.d"
  )
  foreach ($source in $headlessSources) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($source)
    Invoke-Checked $compiler @("-w", "--d-version=AuroraHeadless", "-Isource", "-i", "-c", $source, "-of=$(Join-Path $temp "host/$name.o")")
  }

  $versionLine = (& $compiler --version | Select-Object -First 1)
  if ($versionLine -match "^LDC") {
    Write-Host "Cross-compiling complete native application graphs with LDC"
    foreach ($target in $crossTargets) {
      $targetDir = Join-Path $temp "cross/$target"
      New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
      foreach ($source in $nativeSources) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($source)
        Invoke-Checked $compiler @("-w", "--mtriple=$target", "-Isource", "-i", "-c", $source, "-of=$(Join-Path $targetDir "$name.o")")
      }
    }
  }
  else {
    Write-Host "Skipping cross-target code generation: $compiler is not LDC."
  }

  if ($env:AURORA_VERIFY_VULKAN -eq "1") {
    & (Join-Path $scriptDir "test-vulkan.ps1")
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
  else {
    Write-Host "Vulkan runtime smoke not requested (set AURORA_VERIFY_VULKAN=1)."
  }

  if ($env:AURORA_VERIFY_GUI -eq "1") {
    & (Join-Path $scriptDir "test-gui-smoke.ps1")
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
  else {
    Write-Host "GUI runtime smoke not requested (set AURORA_VERIFY_GUI=1)."
  }

  Write-Host "Release verification completed successfully."
}
finally {
  Pop-Location
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $temp
}
