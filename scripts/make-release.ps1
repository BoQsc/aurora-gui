param(
    [string]$Version = "",
    [switch]$Yes
)
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Git = "git"

function Invoke-Git([string[]]$Arguments) {
    & $Git -C $RepoRoot @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed (exit $LASTEXITCODE)"
    }
}

# 1. Determine the version to release.
if ([string]::IsNullOrWhiteSpace($Version)) {
    $current = (Get-Content -LiteralPath (Join-Path $RepoRoot "VERSION.txt") -TotalCount 1).Trim()
    $parts = $current.Split(".")
    if ($parts.Length -lt 3) { throw "Cannot parse current version: $current" }
    $parts[2] = [int]$parts[2] + 1
    $Version = ($parts -join ".")
    Write-Host "Current: $current  ->  suggesting next patch: $Version"
}
$Version = $Version.TrimStart("v")
if ($Version -notmatch "^\d+\.\d+\.\d+$") {
    throw "Invalid version '$Version'. Use MAJOR.MINOR.PATCH, e.g. 0.62.1"
}
$Tag = "v$Version"

# 2. The release must be built from committed, known code.
$dirty = (& $Git -C $RepoRoot status --porcelain)
if ($LASTEXITCODE -ne 0) { throw "git status failed" }
if (-not [string]::IsNullOrWhiteSpace($dirty)) {
    Write-Host "Working tree is not clean - commit or stash before releasing:" -ForegroundColor Yellow
    Write-Host $dirty
    exit 1
}

# 3. Confirm before pushing anything.
if (-not $Yes) {
    Write-Host ""
    Write-Host "About to release ${Tag}:"
    Write-Host "  - python scripts\version.py bump $Version"
    Write-Host "  - commit 'bump version to $Version'"
    Write-Host "  - push main, tag $Tag, push tag (CI then builds + publishes the release)"
    $answer = Read-Host "Continue? (y/N)"
    if ($answer -notmatch "^[yY]") {
        Write-Host "Cancelled."
        exit 1
    }
}

# 4. Bump, verify, commit, push.
& python (Join-Path $RepoRoot "scripts\version.py") bump $Version
if ($LASTEXITCODE -ne 0) { throw "version.py bump failed" }
& python (Join-Path $RepoRoot "scripts\version.py") check
if ($LASTEXITCODE -ne 0) { throw "version.py check failed after bump" }

Invoke-Git @("add", "-u")
Invoke-Git @("commit", "-m", "bump version to $Version")
Invoke-Git @("push", "origin", "main")

# 5. Tag and push - this is what triggers the release workflow.
Invoke-Git @("tag", $Tag)
Invoke-Git @("push", "origin", $Tag)

Write-Host ""
Write-Host "Release $Tag triggered. CI will build and publish the release." -ForegroundColor Green
Write-Host "Watch: https://github.com/BoQsc/aurora-gui/actions"
Write-Host "Release page when done: https://github.com/BoQsc/aurora-gui/releases/tag/$Tag"
