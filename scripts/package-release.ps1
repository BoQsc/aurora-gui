param(
    [string]$OutputDir = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$RepoName = Split-Path -Leaf $RepoRoot

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $RepoRoot "dist"
}
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $RepoRoot $OutputDir
}

function Invoke-GitValue([string[]]$Arguments) {
    try {
        $value = & git -C $RepoRoot @Arguments 2>$null
        if ($LASTEXITCODE -ne 0) {
            return ""
        }
        return ($value -join "`n").Trim()
    } catch {
        return ""
    }
}

function Normalize-RelativePath([string]$FullName) {
    $root = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd("\", "/")
    $relative = $FullName.Substring($root.Length).TrimStart("\", "/")
    return $relative.Replace("\", "/")
}

function Test-ExcludedDirectory([string]$RelativePath) {
    $path = $RelativePath.Replace("\", "/").Trim("/")
    if ($path.Length -eq 0) {
        return $false
    }

    $parts = $path.Split("/")
    foreach ($part in $parts) {
        switch -Regex ($part) {
            "^\.git$" { return $true }
            "^\.dub$" { return $true }
            "^build$" { return $true }
            "^build-validation$" { return $true }
            "^dist$" { return $true }
            "^release$" { return $true }
            "^releases$" { return $true }
            "^quality-diagnostic-artifacts$" { return $true }
            "^stream-pacing-diagnostic$" { return $true }
            "^__pycache__$" { return $true }
            "^\.pytest_cache$" { return $true }
            "^\.mypy_cache$" { return $true }
            "^\.vscode$" { return $true }
            "^\.idea$" { return $true }
        }
    }

    return $false
}

function Test-ExcludedFile([string]$RelativePath) {
    $path = $RelativePath.Replace("\", "/")
    $name = [System.IO.Path]::GetFileName($path)
    $extension = [System.IO.Path]::GetExtension($name).ToLowerInvariant()

    switch ($extension) {
        ".o" { return $true }
        ".obj" { return $true }
        ".pdb" { return $true }
        ".ilk" { return $true }
        ".exe" { return $true }
        ".dll" { return $true }
        ".log" { return $true }
        ".tmp" { return $true }
        ".bak" { return $true }
        ".zip" { return $true }
        ".7z" { return $true }
        ".rar" { return $true }
        ".mp4" { return $true }
        ".mov" { return $true }
        ".mkv" { return $true }
        ".webm" { return $true }
        ".flv" { return $true }
        ".wav" { return $true }
        ".mp3" { return $true }
        ".aac" { return $true }
        ".auroracut" { return $true }
    }

    switch -Wildcard ($name) {
        "aurora-cut-startup.log" { return $true }
        "aurora-stream-startup.log" { return $true }
        "aurora-stream-settings.json" { return $true }
        "aurora-stream-settings.json.*" { return $true }
        "audio-device-diagnostic.txt" { return $true }
        "aurora-stream-*diagnostic*.txt" { return $true }
        "*-test-application.exe" { return $true }
        "*-test-application.pdb" { return $true }
    }

    return $false
}

$versionPath = Join-Path $RepoRoot "VERSION.txt"
$version = "dev"
if (Test-Path -LiteralPath $versionPath) {
    $version = (Get-Content -LiteralPath $versionPath -TotalCount 1).Trim()
    if ([string]::IsNullOrWhiteSpace($version)) {
        $version = "dev"
    }
}

$shortSha = Invoke-GitValue @("rev-parse", "--short", "HEAD")
if ([string]::IsNullOrWhiteSpace($shortSha)) {
    $shortSha = "nogit"
}

$dirtyMarker = ""
$gitStatus = Invoke-GitValue @("status", "--porcelain")
if (-not [string]::IsNullOrWhiteSpace($gitStatus)) {
    $dirtyMarker = "-dirty"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$archiveBaseName = "aurora-gui-$version-$shortSha$dirtyMarker-$stamp"
$zipPath = Join-Path $OutputDir "$archiveBaseName.zip"

$files = New-Object System.Collections.Generic.List[System.IO.FileInfo]

Get-ChildItem -LiteralPath $RepoRoot -Force -Recurse -File | ForEach-Object {
    $relative = Normalize-RelativePath $_.FullName
    $parent = [System.IO.Path]::GetDirectoryName($relative)
    if ($null -eq $parent) {
        $parent = ""
    }
    $parent = $parent.Replace("\", "/")

    if (Test-ExcludedDirectory $parent) {
        return
    }
    if (Test-ExcludedFile $relative) {
        return
    }

    $files.Add($_)
}

if ($files.Count -eq 0) {
    throw "No files matched the release package rules."
}

$totalBytes = 0L
foreach ($file in $files) {
    $totalBytes += $file.Length
}

if ($DryRun) {
    Write-Host "Release dry run"
    Write-Host "Files: $($files.Count)"
    Write-Host ("Input bytes: {0:N0}" -f $totalBytes)
    Write-Host "Output: $zipPath"
    Write-Host ""
    $files |
        ForEach-Object { Normalize-RelativePath $_.FullName } |
        Sort-Object |
        ForEach-Object { Write-Host $_ }
    exit 0
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
if (Test-Path -LiteralPath $zipPath) {
    throw "Release archive already exists: $zipPath"
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in ($files | Sort-Object FullName)) {
        $relative = Normalize-RelativePath $file.FullName
        $entryName = "$RepoName/$relative"
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip,
            $file.FullName,
            $entryName,
            [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }

    $manifestEntry = $zip.CreateEntry("$RepoName/RELEASE-MANIFEST.txt", [System.IO.Compression.CompressionLevel]::Optimal)
    $writer = New-Object System.IO.StreamWriter($manifestEntry.Open(), [System.Text.UTF8Encoding]::new($false))
    try {
        $writer.WriteLine("Aurora GUI release package")
        $writer.WriteLine("Generated: $(Get-Date -Format o)")
        $writer.WriteLine("Version: $version")
        $writer.WriteLine("Git commit: $shortSha")
        $writer.WriteLine("Working tree dirty: $(-not [string]::IsNullOrWhiteSpace($dirtyMarker))")
        $writer.WriteLine("Packaged files: $($files.Count)")
        $writer.WriteLine("")
        $writer.WriteLine("Excluded by design:")
        $writer.WriteLine("- .git, DUB caches, build directories, and release output directories")
        $writer.WriteLine("- compiled binaries, object files, debug symbols, and temporary files")
        $writer.WriteLine("- logs, diagnostics, local settings, stream keys, and generated media")
        $writer.WriteLine("")
        $writer.WriteLine("File list:")
        foreach ($file in ($files | Sort-Object FullName)) {
            $writer.WriteLine((Normalize-RelativePath $file.FullName))
        }
    } finally {
        $writer.Dispose()
    }
} finally {
    $zip.Dispose()
}

$zipInfo = Get-Item -LiteralPath $zipPath
Write-Host "Release archive created:"
Write-Host $zipInfo.FullName
Write-Host ("Files: {0}" -f $files.Count)
Write-Host ("Archive size: {0:N0} bytes" -f $zipInfo.Length)
