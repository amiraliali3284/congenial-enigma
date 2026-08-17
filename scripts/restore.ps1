[CmdletBinding()]
param()

Set-StrictMode -Version Latest

$ErrorActionPreference = "Continue"

$Workspace = "D:\DAO-Workspace"
$Logs      = "D:\DAO-Logs"

$RestoreLog = Join-Path $Logs "restore.log"
$TempRoot   = Join-Path $env:RUNNER_TEMP "dao-restore"

New-Item -ItemType Directory -Force -Path $Workspace | Out-Null
New-Item -ItemType Directory -Force -Path $Logs | Out-Null

function Restore-Log {
    param([string]$Message)

    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"

    Write-Host $line

    try {
        Add-Content -LiteralPath $RestoreLog -Value $line
    }
    catch {
    }
}

function Copy-SafeTree {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path $Source)) {
        return
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    $dangerousExtensions = @(
        ".exe",
        ".msi",
        ".msp",
        ".com",
        ".scr",
        ".sys",
        ".dll",
        ".ocx",
        ".cpl",
        ".bat",
        ".cmd",
        ".ps1",
        ".psm1",
        ".psd1",
        ".vbs",
        ".vbe",
        ".js",
        ".jse",
        ".wsf",
        ".wsh",
        ".hta"
    )

    $excludedDirectoryNames = @(
        "Windows",
        "Temp",
        "tmp",
        "Cache",
        "Caches",
        "Code Cache",
        "GPUCache",
        "OneDrive",
        "My Music",
        "My Pictures",
        "My Videos"
    )

    Get-ChildItem `
        -LiteralPath $Source `
        -Force `
        -Recurse `
        -File `
        -ErrorAction SilentlyContinue |
        ForEach-Object {

            $file = $_

            try {

                $relative = $file.FullName.Substring(
                    $Source.TrimEnd('\').Length
                ).TrimStart('\')

                $parts = $relative -split '[\\/]'

                $skipDirectory = $false

                foreach ($part in $parts) {

                    if ($excludedDirectoryNames -contains $part) {
                        $skipDirectory = $true
                        break
                    }
                }

                if ($skipDirectory) {
                    return
                }

                if ($dangerousExtensions -contains $file.Extension.ToLowerInvariant()) {
                    return
                }

                $target = Join-Path $Destination $relative

                $targetDir = Split-Path $target -Parent

                New-Item `
                    -ItemType Directory `
                    -Force `
                    -Path $targetDir |
                    Out-Null

                Copy-Item `
                    -LiteralPath $file.FullName `
                    -Destination $target `
                    -Force `
                    -ErrorAction Stop
            }
            catch {

                Restore-Log "WARNING: could not restore $($file.FullName): $($_.Exception.Message)"
            }
        }
}

Restore-Log "=============================================="
Restore-Log "DAO RESTORE START"
Restore-Log "=============================================="

$token = [Environment]::GetEnvironmentVariable("GH_TOKEN")

if ([string]::IsNullOrWhiteSpace($token)) {

    Restore-Log "GH_TOKEN is not available."
    Restore-Log "No artifact restore can be performed."

    Set-Content `
        -LiteralPath (Join-Path $Logs "restore-status.txt") `
        -Value "NO TOKEN - NO RESTORE"

    exit 0
}

$repo = $env:GITHUB_REPOSITORY

if ([string]::IsNullOrWhiteSpace($repo)) {

    Restore-Log "GITHUB_REPOSITORY is not available."

    Set-Content `
        -LiteralPath (Join-Path $Logs "restore-status.txt") `
        -Value "NO REPOSITORY - NO RESTORE"

    exit 0
}

# ============================================================
# CLEAN TEMP
# ============================================================

Remove-Item `
    -LiteralPath $TempRoot `
    -Recurse `
    -Force `
    -ErrorAction SilentlyContinue

New-Item `
    -ItemType Directory `
    -Force `
    -Path $TempRoot |
    Out-Null

$artifactZip = Join-Path $TempRoot "backup.zip"
$extractDir  = Join-Path $TempRoot "extracted"

# ============================================================
# FIND ARTIFACTS
# ============================================================

Restore-Log "Searching for previous dao-windows-backup artifacts..."

$artifactList = $null

try {

    $json = & gh api `
        "repos/$repo/actions/artifacts?per_page=100" `
        --header "Accept: application/vnd.github+json" `
        --header "X-GitHub-Api-Version: 2022-11-28" `
        2>&1

    if ($LASTEXITCODE -ne 0) {

        Restore-Log "gh api failed."
        Restore-Log "$json"

        exit 0
    }

    if ($json) {
        $artifactList = ($json -join "`n") | ConvertFrom-Json
    }

}
catch {

    Restore-Log "Artifact API query failed: $($_.Exception.Message)"
    exit 0
}

if ($null -eq $artifactList) {

    Restore-Log "No artifact response."
    exit 0
}

$artifacts = @(
    $artifactList.artifacts |
        Where-Object {
            $_.name -eq "dao-windows-backup" -and
            $_.expired -ne $true
        } |
        Sort-Object `
            -Property created_at `
            -Descending
)

if ($artifacts.Count -eq 0) {

    Restore-Log "No previous DAO backup artifact was found."

    Set-Content `
        -LiteralPath (Join-Path $Logs "restore-status.txt") `
        -Value "NO PREVIOUS BACKUP"

    exit 0
}

$selected = $artifacts[0]

Restore-Log "Selected artifact:"
Restore-Log "ID: $($selected.id)"
Restore-Log "Created: $($selected.created_at)"
Restore-Log "Size: $($selected.size_in_bytes) bytes"

# ============================================================
# DOWNLOAD
# ============================================================

Restore-Log "Downloading artifact..."

try {

    & gh api `
        "repos/$repo/actions/artifacts/$($selected.id)/zip" `
        --header "Accept: application/vnd.github+json" `
        --header "X-GitHub-Api-Version: 2022-11-28" `
        > $artifactZip

    if ($LASTEXITCODE -ne 0) {
        throw "gh api returned exit code $LASTEXITCODE"
    }

}
catch {

    Restore-Log "Artifact download failed: $($_.Exception.Message)"

    Set-Content `
        -LiteralPath (Join-Path $Logs "restore-status.txt") `
        -Value "DOWNLOAD FAILED"

    exit 0
}

if (-not (Test-Path $artifactZip)) {

    Restore-Log "Downloaded ZIP does not exist."
    exit 0
}

$fileInfo = Get-Item $artifactZip

if ($fileInfo.Length -lt 100) {

    Restore-Log "Downloaded artifact appears invalid or empty."
    exit 0
}

# ============================================================
# VALIDATE ZIP
# ============================================================

Restore-Log "Validating backup ZIP..."

try {

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $zip = [System.IO.Compression.ZipFile]::OpenRead($artifactZip)

    try {

        if ($zip.Entries.Count -eq 0) {
            throw "ZIP contains no entries."
        }

        foreach ($entry in $zip.Entries) {

            $fullName = $entry.FullName.Replace("\", "/")

            if ($fullName.StartsWith("/") -or
                $fullName.Contains("../") -or
                $fullName.StartsWith("../")) {

                throw "Unsafe ZIP path detected: $fullName"
            }
        }

        Restore-Log "ZIP validation successful."
    }
    finally {

        $zip.Dispose()
    }

}
catch {

    Restore-Log "ZIP validation failed: $($_.Exception.Message)"

    Set-Content `
        -LiteralPath (Join-Path $Logs "restore-status.txt") `
        -Value "INVALID ZIP"

    exit 0
}

# ============================================================
# EXTRACT
# ============================================================

Restore-Log "Extracting backup..."

try {

    Expand-Archive `
        -LiteralPath $artifactZip `
        -DestinationPath $extractDir `
        -Force `
        -ErrorAction Stop

}
catch {

    Restore-Log "ZIP extraction failed: $($_.Exception.Message)"
    exit 0
}

# ============================================================
# FIND PAYLOAD
# ============================================================

$payload = Join-Path $extractDir "DAO-Backup"

if (-not (Test-Path $payload)) {

    # Handle a possible extra root directory.
    $candidate = Get-ChildItem `
        -LiteralPath $extractDir `
        -Directory `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($candidate) {
        $payload = $candidate.FullName
    }
}

if (-not (Test-Path $payload)) {

    Restore-Log "Backup payload was not found."
    exit 0
}

# ============================================================
# RESTORE WORKSPACE
# ============================================================

$workspaceBackup = Join-Path $payload "workspace"

if (Test-Path $workspaceBackup) {

    Restore-Log "Restoring DAO workspace..."

    Copy-SafeTree `
        -Source $workspaceBackup `
        -Destination $Workspace

    Restore-Log "Workspace restore completed."

}
else {

    Restore-Log "No workspace directory exists in backup."
}

# ============================================================
# RESTORE FILEZILLA
# ============================================================

$filezillaBackup = Join-Path $payload "FileZilla"

if (Test-Path $filezillaBackup) {

    $filezillaDestination = Join-Path $env:APPDATA "FileZilla"

    Restore-Log "Restoring FileZilla configuration..."

    Copy-SafeTree `
        -Source $filezillaBackup `
        -Destination $filezillaDestination

    Restore-Log "FileZilla restore completed."
}

# ============================================================
# RESTORE GEANY
# ============================================================

$geanyBackup = Join-Path $payload "Geany"

if (Test-Path $geanyBackup) {

    $geanyDestination = Join-Path $env:APPDATA "geany"

    Restore-Log "Restoring Geany configuration..."

    Copy-SafeTree `
        -Source $geanyBackup `
        -Destination $geanyDestination

    Restore-Log "Geany restore completed."
}

# ============================================================
# RESTORE DAO DATA
# ============================================================

$daoDataBackup = Join-Path $payload "dao-data"

if (Test-Path $daoDataBackup) {

    Restore-Log "Restoring DAO-specific data..."

    Copy-SafeTree `
        -Source $daoDataBackup `
        -Destination $Workspace

    Restore-Log "DAO-specific data restore completed."
}

# ============================================================
# RESTORE STATUS
# ============================================================

$statusFile = Join-Path $Logs "restore-status.txt"

Set-Content `
    -LiteralPath $statusFile `
    -Value "RESTORE COMPLETED"

Restore-Log "=============================================="
Restore-Log "DAO RESTORE COMPLETED"
Restore-Log "=============================================="

Remove-Item `
    -LiteralPath $TempRoot `
    -Recurse `
    -Force `
    -ErrorAction SilentlyContinue
