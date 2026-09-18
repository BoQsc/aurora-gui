<#
.SYNOPSIS
    Back up or install the API keys used by Aurora OpenCode / the opencode CLI.

.DESCRIPTION
    Collects the credential stores Aurora OpenCode reads into one portable
    bundle, and installs such a bundle on another machine:

      * ~/.local/share/opencode/auth.json        (opencode-go, deepseek, ...)
      * ~/.config/opencode/commandcode.key       (CommandCode key)
      * %APPDATA%\Aurora OpenCode\settings.json  (configured provider + key)

    Pass -Password to encrypt the bundle with AES-256-CBC (PBKDF2-SHA1,
    100000 iterations) so it is safe to send through chat/email. Without it the
    bundle is plain-text JSON and MUST be treated as a secret.

    Every install backs up the files it touches to <file>.bak-<timestamp>.
    Existing keys that differ are NOT overwritten unless -Force is given.

    Keys are never printed in full; only a masked preview is shown.

.PARAMETER Action
    backup  : write a bundle from this machine (default).
    install : apply a bundle to this machine.
    list    : show what a bundle contains (masked).

.PARAMETER Path
    Bundle path. backup defaults to
    %USERPROFILE%\aurora-api-keys.bundle.json (or .enc.json with -Password).
    install/list require it.

.PARAMETER Password
    Encrypt (backup) or decrypt (install/list) the bundle.

.PARAMETER Force
    Allow overwriting an existing, different key.

.PARAMETER IncludeFullSettings
    On backup, also carry the whole Aurora settings.json (not just the
    provider fields). On install, apply the whole settings object.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\aurora-api-keys.ps1 backup -Password "shared secret"
    # -> %USERPROFILE%\aurora-api-keys.bundle.enc.json  (safe to send)

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\aurora-api-keys.ps1 install -Path .\aurora-api-keys.bundle.enc.json -Password "shared secret"

.EXAMPLE
    scripts\aurora-api-keys.cmd list -Path .\keys.bundle.json
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet("backup", "install", "list")]
    [string]$Action = "backup",

    [string]$Path = "",
    [string]$Password = "",
    [switch]$Force,
    [switch]$IncludeFullSettings
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

$AuthPath        = Join-Path $env:USERPROFILE ".local\share\opencode\auth.json"
$CommandCodePath = Join-Path $env:USERPROFILE ".config\opencode\commandcode.key"
$SettingsPath    = Join-Path $env:APPDATA "Aurora OpenCode\settings.json"

$BundleKind = "aurora-api-keys"
$BundleSchema = 1

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

function Write-Step([string]$Message) {
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Warn([string]$Message) {
    Write-Host $Message -ForegroundColor Yellow
}

function Mask-Secret([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return "(empty)" }
    if ($Value.Length -le 10) { return (("*" * $Value.Length) -join "") }
    return $Value.Substring(0, 4) + "..." + $Value.Substring($Value.Length - 4)
}

function ConvertTo-Hashtable($Object) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in @($Object.Keys)) { $table[[string]$key] = ConvertTo-Hashtable $Object[$key] }
        return $table
    }
    if ($Object -is [pscustomobject]) {
        $table = @{}
        foreach ($prop in $Object.PSObject.Properties) {
            $table[$prop.Name] = ConvertTo-Hashtable $prop.Value
        }
        return $table
    }
    if (($Object -is [System.Collections.IEnumerable]) -and ($Object -isnot [string])) {
        $list = @()
        foreach ($item in $Object) { $list += , (ConvertTo-Hashtable $item) }
        return , $list
    }
    return $Object
}

function Read-JsonObject([string]$FilePath) {
    if (-not (Test-Path -LiteralPath $FilePath)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        return ConvertTo-Hashtable (ConvertFrom-Json $raw)
    }
    catch {
        throw "Cannot parse JSON at $FilePath : $($_.Exception.Message)"
    }
}

function Write-Utf8NoBom([string]$FilePath, [string]$Text) {
    $dir = Split-Path -Parent $FilePath
    if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllText($FilePath, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Backup-Existing([string]$FilePath) {
    if (-not (Test-Path -LiteralPath $FilePath)) { return }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = "$FilePath.bak-$stamp"
    Copy-Item -LiteralPath $FilePath -Destination $backup -Force
    Write-Host "  backed up: $backup" -ForegroundColor DarkGray
}

function Protect-Bundle([string]$Json, [string]$Password) {
    $salt = New-Object byte[] 16
    $iv = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($salt)
    $rng.GetBytes($iv)
    $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 100000)
    $key = $derive.GetBytes(32)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $key
    $aes.IV = $iv
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $plain = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $encryptor = $aes.CreateEncryptor()
    $cipher = $encryptor.TransformFinalBlock($plain, 0, $plain.Length)
    return [ordered]@{
        schema     = $BundleSchema
        kind       = $BundleKind
        encrypted  = $true
        kdf        = "pbkdf2-sha1"
        iterations = 100000
        salt       = [Convert]::ToBase64String($salt)
        iv         = [Convert]::ToBase64String($iv)
        data       = [Convert]::ToBase64String($cipher)
    }
}

function Unprotect-Bundle($Envelope, [string]$Password) {
    if ([string]::IsNullOrEmpty($Password)) {
        throw "This bundle is encrypted; pass -Password."
    }
    $salt = [Convert]::FromBase64String([string]$Envelope.salt)
    $iv = [Convert]::FromBase64String([string]$Envelope.iv)
    $iterations = 100000
    if ($Envelope.PSObject.Properties.Name -contains "iterations") { $iterations = [int]$Envelope.iterations }
    $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, $iterations)
    $key = $derive.GetBytes(32)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $key
    $aes.IV = $iv
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $cipher = [Convert]::FromBase64String([string]$Envelope.data)
    try {
        $decryptor = $aes.CreateDecryptor()
        $plain = $decryptor.TransformFinalBlock($cipher, 0, $cipher.Length)
    }
    catch {
        throw "Wrong password or corrupt bundle."
    }
    return [System.Text.Encoding]::UTF8.GetString($plain)
}

function Read-Bundle([string]$BundlePath) {
    if ([string]::IsNullOrWhiteSpace($BundlePath)) { throw "Pass -Path <bundle>." }
    if (-not (Test-Path -LiteralPath $BundlePath)) { throw "Bundle not found: $BundlePath" }
    $raw = Get-Content -LiteralPath $BundlePath -Raw -Encoding UTF8
    $envelope = ConvertFrom-Json $raw
    if (($envelope.PSObject.Properties.Name -contains "encrypted") -and $envelope.encrypted) {
        $json = Unprotect-Bundle $envelope $Password
        $bundle = ConvertTo-Hashtable (ConvertFrom-Json $json)
    }
    else {
        $bundle = ConvertTo-Hashtable $envelope
    }
    if (-not ($bundle.ContainsKey("kind")) -or $bundle["kind"] -ne $BundleKind) {
        throw "Not an $BundleKind bundle (kind='$($bundle['kind'])'): $BundlePath"
    }
    return $bundle
}

function Get-SecretKey($Entry) {
    if ($null -eq $Entry) { return $null }
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains("key")) {
        return [string]$Entry["key"]
    }
    return $null
}

# ---------------------------------------------------------------------------
# backup
# ---------------------------------------------------------------------------

function Invoke-Backup {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $name = if ($Password) { "aurora-api-keys.bundle.enc.json" } else { "aurora-api-keys.bundle.json" }
        $Path = Join-Path $env:USERPROFILE $name
    }
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Warn "WARNING: writing the bundle inside the git repository is risky - delete it before committing."
    }

    $bundle = [ordered]@{
        schema    = $BundleSchema
        kind      = $BundleKind
        createdAt = (Get-Date).ToString("o")
        machine   = $env:COMPUTERNAME
        user      = $env:USERNAME
        auth      = @{}
        commandcodeKey = ""
        aurora    = [ordered]@{}
    }

    $providerCount = 0
    if (Test-Path -LiteralPath $AuthPath) {
        $auth = Read-JsonObject $AuthPath
        foreach ($provider in @($auth.Keys)) {
            $key = Get-SecretKey $auth[$provider]
            $bundle["auth"][$provider] = $auth[$provider]
            $providerCount++
            Write-Host ("  auth: {0,-14} {1}" -f $provider, (Mask-Secret $key))
        }
    }
    else {
        Write-Warn "  auth store not found: $AuthPath"
    }

    if (Test-Path -LiteralPath $CommandCodePath) {
        $ccKey = (Get-Content -LiteralPath $CommandCodePath -Raw -Encoding UTF8).Trim()
        $bundle["commandcodeKey"] = $ccKey
        Write-Host ("  commandcode.key  {0}" -f (Mask-Secret $ccKey))
    }

    if (Test-Path -LiteralPath $SettingsPath) {
        $settings = Read-JsonObject $SettingsPath
        foreach ($field in @("apiKey", "baseUrl", "model", "thinking", "toolsEnabled", "legacyTools")) {
            if ($settings.ContainsKey($field)) { $bundle["aurora"][$field] = $settings[$field] }
        }
        if ($IncludeFullSettings) { $bundle["fullSettings"] = $settings }
        Write-Host ("  settings.json    baseUrl={0} model={1} key={2}" -f `
            $bundle["aurora"]["baseUrl"], $bundle["aurora"]["model"], `
            (Mask-Secret ([string]$bundle["aurora"]["apiKey"])))
    }

    $json = $bundle | ConvertTo-Json -Depth 12
    if ($Password) {
        $envelope = Protect-Bundle $json $Password
        Write-Utf8NoBom $full (($envelope | ConvertTo-Json -Depth 5) + "`n")
    }
    else {
        Write-Utf8NoBom $full ($json + "`n")
        Write-Warn "Plain-text bundle: treat it as a secret (or re-run with -Password)."
    }

    Write-Step "Backup written: $full"
    Write-Host ("  {0} auth provider(s) + commandcode" -f $providerCount)
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------

function Invoke-Install {
    $bundle = Read-Bundle $Path
    Write-Step "Installing bundle from $Path"

    $settings = Read-JsonObject $SettingsPath
    $applyKey = {
        param($target, $field, $incoming, $label)
        $existing = $null
        if ($target.ContainsKey($field)) { $existing = [string]$target[$field] }
        if (-not $Force -and -not [string]::IsNullOrEmpty($existing) -and
            -not [string]::IsNullOrEmpty($incoming) -and $existing -ne $incoming) {
            Write-Warn ("  skip {0}: a different key already exists (use -Force)" -f $label)
            return $false
        }
        if ([string]::IsNullOrEmpty($incoming)) { return $false }
        $target[$field] = $incoming
        Write-Host ("  set  {0} {1}" -f $label, (Mask-Secret $incoming))
        return $true
    }

    # auth.json
    $touchedAuth = $false
    if ($bundle.ContainsKey("auth") -and $bundle["auth"].Count -gt 0) {
        $auth = Read-JsonObject $AuthPath
        foreach ($provider in @($bundle["auth"].Keys)) {
            $incomingEntry = $bundle["auth"][$provider]
            $incomingKey = Get-SecretKey $incomingEntry
            $existingKey = Get-SecretKey $auth[$provider]
            if (-not $Force -and -not [string]::IsNullOrEmpty($existingKey) -and
                -not [string]::IsNullOrEmpty($incomingKey) -and $existingKey -ne $incomingKey) {
                Write-Warn ("  skip auth.{0}: a different key already exists (use -Force)" -f $provider)
                continue
            }
            $auth[$provider] = $incomingEntry
            $touchedAuth = $true
            Write-Host ("  set  auth.{0,-12} {1}" -f $provider, (Mask-Secret $incomingKey))
        }
        if ($touchedAuth) {
            Backup-Existing $AuthPath
            Write-Utf8NoBom $AuthPath (($auth | ConvertTo-Json -Depth 12) + "`n")
            Write-Host "  wrote: $AuthPath"
        }
    }

    # commandcode.key
    $ccIncoming = [string]$bundle["commandcodeKey"]
    if (-not [string]::IsNullOrEmpty($ccIncoming)) {
        $existing = ""
        if (Test-Path -LiteralPath $CommandCodePath) {
            $existing = (Get-Content -LiteralPath $CommandCodePath -Raw -Encoding UTF8).Trim()
        }
        if (-not $Force -and -not [string]::IsNullOrEmpty($existing) -and $existing -ne $ccIncoming) {
            Write-Warn "  skip commandcode.key: a different key already exists (use -Force)"
        }
        else {
            Backup-Existing $CommandCodePath
            Write-Utf8NoBom $CommandCodePath ($ccIncoming + "`n")
            Write-Host ("  set  commandcode.key {0}" -f (Mask-Secret $ccIncoming))
            Write-Host "  wrote: $CommandCodePath"
        }
    }

    # Aurora settings.json (provider fields, or the whole object)
    $settingsTouched = $false
    $source = $null
    if ($bundle.ContainsKey("fullSettings")) { $source = $bundle["fullSettings"] }
    elseif ($bundle.ContainsKey("aurora")) { $source = $bundle["aurora"] }
    if ($null -ne $source -and $source.Count -gt 0) {
        foreach ($field in @($source.Keys)) {
            if ($field -eq "apiKey") {
                if (& $applyKey $settings "apiKey" ([string]$source[$field]) "settings.apiKey") {
                    $settingsTouched = $true
                }
                continue
            }
            $settings[$field] = $source[$field]
            $settingsTouched = $true
        }
        if ($settingsTouched) {
            Backup-Existing $SettingsPath
            Write-Utf8NoBom $SettingsPath (($settings | ConvertTo-Json -Depth 12) + "`n")
            Write-Host "  wrote: $SettingsPath"
        }
    }

    if (-not $touchedAuth -and -not $settingsTouched -and [string]::IsNullOrEmpty($ccIncoming)) {
        Write-Warn "Nothing was installed (bundle empty or all keys skipped)."
    }
    Write-Step "Install complete. Restart Aurora OpenCode so it reloads the settings."
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

function Invoke-List {
    $bundle = Read-Bundle $Path
    Write-Step "Bundle: $Path"
    Write-Host ("  kind={0} schema={1} created={2} machine={3}" -f `
        $bundle["kind"], $bundle["schema"],
        $bundle["createdAt"], $bundle["machine"])
    if ($bundle.ContainsKey("auth")) {
        foreach ($provider in @($bundle["auth"].Keys)) {
            Write-Host ("  auth.{0,-14} {1}" -f $provider, (Mask-Secret (Get-SecretKey $bundle["auth"][$provider])))
        }
    }
    if (-not [string]::IsNullOrEmpty([string]$bundle["commandcodeKey"])) {
        Write-Host ("  commandcode.key   {0}" -f (Mask-Secret ([string]$bundle["commandcodeKey"])))
    }
    if ($bundle.ContainsKey("aurora")) {
        Write-Host ("  settings          baseUrl={0} model={1} key={2}" -f `
            $bundle["aurora"]["baseUrl"], $bundle["aurora"]["model"], `
            (Mask-Secret ([string]$bundle["aurora"]["apiKey"])))
    }
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

switch ($Action) {
    "backup"  { Invoke-Backup }
    "install" { Invoke-Install }
    "list"    { Invoke-List }
    default   { throw "Unknown action: $Action" }
}
