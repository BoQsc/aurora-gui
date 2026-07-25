$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$compiler = if ($env:DC) { $env:DC } else { "ldc2" }
$dubCommand = if ($env:DUB) { $env:DUB } else { "dub" }
$renderers = if ($env:AURORA_GUI_RENDERERS) { $env:AURORA_GUI_RENDERERS -split "\s+" } else { @("software") }
$duration = if ($env:AURORA_GUI_SMOKE_SECONDS) { [int]$env:AURORA_GUI_SMOKE_SECONDS } else { 2 }
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("aurora-gui-smoke-" + [Guid]::NewGuid().ToString("N"))

Push-Location $root
try {
  foreach ($config in @("notepad", "file-explorer", "desktop", "taskbar", "font-gallery")) {
    & $dubCommand build --config=$config --build=debug --compiler=$compiler --force
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }

  New-Item -ItemType Directory -Force -Path $temp | Out-Null
  foreach ($renderer in $renderers) {
    if ($renderer -notin @("software", "vulkan")) {
      throw "Unknown GUI smoke renderer: $renderer"
    }
    foreach ($executable in @("aurora-notepad", "aurora-file-explorer", "aurora-desktop", "aurora-taskbar", "aurora-font-gallery")) {
      Write-Host "GUI smoke: $renderer / $executable"
      $stdout = Join-Path $temp "$renderer-$executable.stdout"
      $stderr = Join-Path $temp "$renderer-$executable.stderr"
      $oldRenderer = $env:AURORA_RENDERER
      $env:AURORA_RENDERER = $renderer
      try {
        $process = Start-Process -FilePath (Join-Path $root "$executable.exe") -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if ($process.WaitForExit($duration * 1000)) {
          throw "$renderer / $executable exited early with code $($process.ExitCode)"
        }
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
      }
      finally {
        $env:AURORA_RENDERER = $oldRenderer
      }
      if ((Get-Item $stderr).Length -ne 0) {
        throw "Unexpected stderr for $renderer / $executable`: $(Get-Content $stderr -Raw)"
      }
    }
  }
  Write-Host "GUI startup and event-loop smoke completed successfully."
}
finally {
  Pop-Location
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $temp
}
