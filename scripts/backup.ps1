[CmdletBinding()]
param()

Set-StrictMode -Version Latest

$ErrorActionPreference = "Continue"

$Workspace = "D:\DAO-Workspace"
$Logs      = "D:\DAO-Logs"

$BackupRoot = Join-Path $env:RUNNER_TEMP "DAO-Backup"
$Payload    = Join-Path $BackupRoot "DAO-Backup"
$ZipFile    = Join-Path $Logs "dao-windows-backup.zip"

$BackupLog = Join-Path $Logs "backup.log"

New-Item `
    -ItemType Directory `
    -Force `
    -Path $Logs |
    Out-Null

function Backup-Log {
    param([string]$Message)

    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"

    Write-Host $line

    try {
        Add-Content `
            -LiteralPath $BackupLog `
            -Value $line
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

        Backup-Log "Source does not exist: $Source"

        return @{
            Copied  = 0
            Failed  = 0
            Skipped = 0
        }
    }

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $Destination |
        Out-Null

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

    $copied = 0
    $failed = 0
    $skipped = 0

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

                    $skipped++
                    return
                }

                if ($dangerousExtensions -contains $file.Extension.ToLowerInvariant()) {

                    $skipped++
                    return
                }

                $target = Join-Path `
                    $Destination `
                    $relative

                $targetDir = Split-Path `
                    -Path $target `
                    -Parent

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

                $copied++
            }
            catch {

                $failed++

                Backup-Log `
                    "WARNING: failed to backup $($file.FullName): $($_.Exception.Message)"
            }
        }

    return @{
        Copied  = $copied
        Failed  = $failed
        Skipped = $skipped
    }
}

Backup-Log "=============================================="
Backup-Log "DAO BACKUP START"
Backup-Log "=============================================="

# ============================================================
# CLEAN OLD STAGING
# ============================================================

Remove-Item `
    -LiteralPath $BackupRoot `
    -Recurse `
    -Force `
    -ErrorAction SilentlyContinue

New-Item `
    -ItemType Directory `
    -Force `
    -Path $Payload |
    Out-Null

# ============================================================
# WORKSPACE
# ============================================================

$totalCopied = 0
$totalFailed = 0
$totalSkipped = 0

if (Test-Path $Workspace) {

    Backup-Log "Backing up DAO workspace..."

    $result = Copy-SafeTree `
        -Source $Workspace `
        -Destination (Join-Path $Payload "workspace")

    $totalCopied += $result.Copied
    $totalFailed += $result.Failed
    $totalSkipped += $result.Skipped

    Backup-Log "Workspace: copied=$($result.Copied), failed=$($result.Failed), skipped=$($result.Skipped)"
}
else {

    Backup-Log "Workspace does not exist."
}

# ============================================================
# FILEZILLA
# ============================================================

$filezilla = Join-Path $env:APPDATA "FileZilla"

if (Test-Path $filezilla) {

    Backup-Log "Backing up FileZilla configuration..."

    $result = Copy-SafeTree `
        -Source $filezilla `
        -Destination (Join-Path $Payload "FileZilla")

    $totalCopied += $result.Copied
    $totalFailed += $result.Failed
    $totalSkipped += $result.Skipped
}

# ============================================================
# GEANY
# ============================================================

$geany = Join-Path $env:APPDATA "geany"

if (Test-Path $geany) {

    Backup-Log "Backing up Geany configuration..."

    $result = Copy-SafeTree `
        -Source $geany `
        -Destination (Join-Path $Payload "Geany")

    $totalCopied += $result.Copied
    $totalFailed += $result.Failed
    $totalSkipped += $result.Skipped
}

# ============================================================
# DAO LOGS
# ============================================================

$daoData = Join-Path $Payload "dao-data"

New-Item `
    -ItemType Directory `
    -Force `
    -Path $daoData |
    Out-Null

# Copy selected logs only.
$logFiles = @(
    "vnc.log",
    "websockify.log",
    "websockify-error.log",
    "cloudflared.log",
    "cloudflared-error.log",
    "anydesk.log",
    "connection-info.txt",
    "tunnel-url.txt",
    "novnc-url.txt",
    "anydesk-id.txt",
    "restore.log",
    "backup.log"
)

foreach ($logName in $logFiles) {

    $source = Join-Path $Logs $logName

    if (Test-Path $source) {

        try {

            Copy-Item `
                -LiteralPath $source `
                -Destination (Join-Path $daoData $logName) `
                -Force `
                -ErrorAction Stop

            $totalCopied++

        }
        catch {

            $totalFailed++

            Backup-Log `
                "WARNING: failed to copy log $logName : $($_.Exception.Message)"
        }
    }
}

# ============================================================
# BACKUP METADATA
# ============================================================

$metadata = @"
DAO Windows Desktop Backup

Created:
$(Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz")

Runner:
$env:RUNNER_NAME

Repository:
$env:GITHUB_REPOSITORY

Workflow:
$env:GITHUB_WORKFLOW

Run:
$env:GITHUB_RUN_ID

Workspace:
$Workspace

Files copied:
$totalCopied

Files failed:
$totalFailed

Files skipped:
$totalSkipped

Passwords:
NOT INCLUDED

GitHub credentials:
NOT INCLUDED

System profile:
NOT INCLUDED

Executable files:
NOT INCLUDED
"@

Set-Content `
    -LiteralPath (Join-Path $Payload "backup-metadata.txt") `
    -Value $metadata

# ============================================================
# CREATE ZIP
# ============================================================

Remove-Item `
    -LiteralPath $ZipFile `
    -Force `
    -ErrorAction SilentlyContinue

Backup-Log "Creating ZIP backup..."

try {

    Compress-Archive `
        -Path (Join-Path $Payload "*") `
        -DestinationPath $ZipFile `
        -CompressionLevel Optimal `
        -Force `
        -ErrorAction Stop

}
catch {

    Backup-Log "ERROR: ZIP creation failed: $($_.Exception.Message)"

    throw
}

# ============================================================
# VALIDATE ZIP
# ============================================================

try {

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipFile)

    try {

        if ($zip.Entries.Count -eq 0) {
            throw "Backup ZIP contains no files."
        }

        Backup-Log "ZIP validation successful."
        Backup-Log "ZIP entries: $($zip.Entries.Count)"
    }
    finally {

        $zip.Dispose()
    }

}
catch {

    Backup-Log "ERROR: Backup ZIP validation failed: $($_.Exception.Message)"

    throw
}

# ============================================================
# STATUS
# ============================================================

if ($totalFailed -eq 0) {

    $status = "Backup completed successfully"

}
else {

    $status = "Backup completed with warnings"
}

Set-Content `
    -LiteralPath (Join-Path $Logs "backup-status.txt") `
    -Value $status

Backup-Log ""
Backup-Log "=============================================="
Backup-Log $status
Backup-Log "=============================================="
Backup-Log "Files copied : $totalCopied"
Backup-Log "Files skipped: $totalSkipped"
Backup-Log "Files failed : $totalFailed"
Backup-Log "Backup file  : $ZipFile"
Backup-Log "=============================================="

Write-Host ""
Write-Host $status
Write-Host ""
Write-Host "Backup file:"
Write-Host $ZipFile
