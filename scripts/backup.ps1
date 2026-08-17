[CmdletBinding()]
param()

Set-StrictMode -Version Latest

$ErrorActionPreference = "Continue"

# ============================================================
# PATHS
# ============================================================

$Workspace = "D:\DAO-Workspace"
$Logs      = "D:\DAO-Logs"

$BackupRoot = Join-Path $env:RUNNER_TEMP "DAO-Backup"
$Payload    = Join-Path $BackupRoot "DAO-Backup"

$ZipFile    = Join-Path $Logs "dao-windows-backup.zip"
$BackupLog  = Join-Path $Logs "backup.log"
$StatusFile = Join-Path $Logs "backup-status.txt"

# ============================================================
# DIRECTORIES
# ============================================================

New-Item `
    -ItemType Directory `
    -Force `
    -Path $Logs |
    Out-Null

New-Item `
    -ItemType Directory `
    -Force `
    -Path $BackupRoot |
    Out-Null

# ============================================================
# LOGGING
# ============================================================

function Backup-Log {
    param(
        [string]$Message
    )

    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"

    Write-Host $line

    try {
        Add-Content `
            -LiteralPath $BackupLog `
            -Value $line `
            -ErrorAction SilentlyContinue
    }
    catch {
    }
}

# ============================================================
# SAFE TREE COPY
# ============================================================

function Copy-SafeTree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $result = @{
        Copied  = 0
        Failed  = 0
        Skipped = 0
    }

    if (-not (Test-Path -LiteralPath $Source)) {

        Backup-Log "Source does not exist: $Source"

        return $result
    }

    try {
        New-Item `
            -ItemType Directory `
            -Force `
            -Path $Destination |
            Out-Null
    }
    catch {

        Backup-Log "Could not create destination: $Destination"

        $result.Failed++

        return $result
    }

    # --------------------------------------------------------
    # Executable / script extensions are deliberately excluded.
    # This keeps the backup focused on user data/configuration.
    # --------------------------------------------------------

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

    # --------------------------------------------------------
    # Directories that should not be backed up.
    # --------------------------------------------------------

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
        "My Videos",
        "node_modules",
        ".git"
    )

    # --------------------------------------------------------
    # Avoid following problematic reparse points.
    # --------------------------------------------------------

    try {

        $files = Get-ChildItem `
            -LiteralPath $Source `
            -Force `
            -Recurse `
            -File `
            -ErrorAction SilentlyContinue
    }
    catch {

        Backup-Log "Could not enumerate source: $Source"

        $result.Failed++

        return $result
    }

    foreach ($file in $files) {

        try {

            # ------------------------------------------------
            # Relative path
            # ------------------------------------------------

            $sourceRoot = $Source.TrimEnd('\')

            if (-not $file.FullName.StartsWith(
                $sourceRoot,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {

                $result.Skipped++

                continue
            }

            $relative = $file.FullName.Substring(
                $sourceRoot.Length
            ).TrimStart('\')

            if ([string]::IsNullOrWhiteSpace($relative)) {

                $result.Skipped++

                continue
            }

            # ------------------------------------------------
            # Check directory components
            # ------------------------------------------------

            $parts = $relative -split '[\\/]'

            $skipDirectory = $false

            foreach ($part in $parts) {

                if ($excludedDirectoryNames -contains $part) {

                    $skipDirectory = $true

                    break
                }
            }

            if ($skipDirectory) {

                $result.Skipped++

                continue
            }

            # ------------------------------------------------
            # Check extension
            # ------------------------------------------------

            $extension = $file.Extension.ToLowerInvariant()

            if ($dangerousExtensions -contains $extension) {

                $result.Skipped++

                continue
            }

            # ------------------------------------------------
            # Ignore reparse-point files
            # ------------------------------------------------

            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {

                $result.Skipped++

                continue
            }

            # ------------------------------------------------
            # Destination
            # ------------------------------------------------

            $target = Join-Path `
                -Path $Destination `
                -ChildPath $relative

            $targetDir = Split-Path `
                -Path $target `
                -Parent

            New-Item `
                -ItemType Directory `
                -Force `
                -Path $targetDir |
                Out-Null

            # ------------------------------------------------
            # Copy
            # ------------------------------------------------

            Copy-Item `
                -LiteralPath $file.FullName `
                -Destination $target `
                -Force `
                -ErrorAction Stop

            $result.Copied++

        }
        catch {

            $result.Failed++

            Backup-Log `
                "WARNING: could not backup $($file.FullName): $($_.Exception.Message)"
        }
    }

    return $result
}

# ============================================================
# START
# ============================================================

Backup-Log "=============================================="
Backup-Log "DAO BACKUP START"
Backup-Log "=============================================="

Backup-Log "Workspace: $Workspace"
Backup-Log "Backup root: $BackupRoot"
Backup-Log "Payload: $Payload"
Backup-Log "ZIP: $ZipFile"

# ============================================================
# CLEAN PREVIOUS TEMP DATA
# ============================================================

Backup-Log "Cleaning previous temporary backup..."

try {

    Remove-Item `
        -LiteralPath $BackupRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

}
catch {
}

New-Item `
    -ItemType Directory `
    -Force `
    -Path $Payload |
    Out-Null

# Remove old ZIP.

try {

    Remove-Item `
        -LiteralPath $ZipFile `
        -Force `
        -ErrorAction SilentlyContinue

}
catch {
}

# ============================================================
# BACKUP WORKSPACE
# ============================================================

$workspaceDestination = Join-Path $Payload "workspace"

Backup-Log "Backing up DAO workspace..."

$workspaceResult = Copy-SafeTree `
    -Source $Workspace `
    -Destination $workspaceDestination

Backup-Log (
    "Workspace: copied=$($workspaceResult.Copied), " +
    "skipped=$($workspaceResult.Skipped), " +
    "failed=$($workspaceResult.Failed)"
)

# ============================================================
# FILEZILLA
# ============================================================

$filezillaSource = Join-Path $env:APPDATA "FileZilla"
$filezillaDestination = Join-Path $Payload "FileZilla"

Backup-Log "Checking FileZilla configuration..."

if (Test-Path -LiteralPath $filezillaSource) {

    $filezillaResult = Copy-SafeTree `
        -Source $filezillaSource `
        -Destination $filezillaDestination

    Backup-Log (
        "FileZilla: copied=$($filezillaResult.Copied), " +
        "skipped=$($filezillaResult.Skipped), " +
        "failed=$($filezillaResult.Failed)"
    )

}
else {

    Backup-Log "FileZilla configuration not found."
}

# ============================================================
# GEANY
# ============================================================

$geanySource = Join-Path $env:APPDATA "geany"
$geanyDestination = Join-Path $Payload "Geany"

Backup-Log "Checking Geany configuration..."

if (Test-Path -LiteralPath $geanySource) {

    $geanyResult = Copy-SafeTree `
        -Source $geanySource `
        -Destination $geanyDestination

    Backup-Log (
        "Geany: copied=$($geanyResult.Copied), " +
        "skipped=$($geanyResult.Skipped), " +
        "failed=$($geanyResult.Failed)"
    )

}
else {

    Backup-Log "Geany configuration not found."
}

# ============================================================
# DAO DATA
# ============================================================
#
# Keep a separate dao-data directory so restore.ps1 can
# distinguish DAO-specific data from the normal workspace.
#
# Only selected data directories are copied.
# ============================================================

$daoDataDestination = Join-Path $Payload "dao-data"

New-Item `
    -ItemType Directory `
    -Force `
    -Path $daoDataDestination |
    Out-Null

# ------------------------------------------------------------
# Optional DAO data locations.
# Add/remove directories here according to your workspace.
# ------------------------------------------------------------

$daoDataCandidates = @(
    (Join-Path $Workspace "Data"),
    (Join-Path $Workspace "Database"),
    (Join-Path $Workspace "Databases"),
    (Join-Path $Workspace "Documents"),
    (Join-Path $Workspace "Projects"),
    (Join-Path $Workspace "Config")
)

$daoDataFound = $false

foreach ($candidate in $daoDataCandidates) {

    if (Test-Path -LiteralPath $candidate) {

        $daoDataFound = $true

        $name = Split-Path `
            -Path $candidate `
            -Leaf

        $destination = Join-Path `
            $daoDataDestination `
            $name

        Backup-Log "Backing up DAO data directory: $candidate"

        $daoResult = Copy-SafeTree `
            -Source $candidate `
            -Destination $destination

        Backup-Log (
            "DAO data [$name]: copied=$($daoResult.Copied), " +
            "skipped=$($daoResult.Skipped), " +
            "failed=$($daoResult.Failed)"
        )
    }
}

if (-not $daoDataFound) {

    Backup-Log "No separate DAO data directories were found."
}

# ============================================================
# CREATE MANIFEST
# ============================================================

$manifest = Join-Path $Payload "backup-manifest.txt"

try {

    $fileCount = @(
        Get-ChildItem `
            -LiteralPath $Payload `
            -Recurse `
            -File `
            -ErrorAction SilentlyContinue
    ).Count

    $manifestContent = @"
DAO WINDOWS BACKUP
==================

Created:
$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Computer:
$env:COMPUTERNAME

User:
$env:USERNAME

Workspace:
$Workspace

Payload:
DAO-Backup

File count:
$fileCount

Excluded executable/script extensions:
.exe
.msi
.msp
.com
.scr
.sys
.dll
.ocx
.cpl
.bat
.cmd
.ps1
.psm1
.psd1
.vbs
.vbe
.js
.jse
.wsf
.wsh
.hta

Backup structure:
DAO-Backup/
    workspace/
    FileZilla/
    Geany/
    dao-data/
    backup-manifest.txt
"@

    Set-Content `
        -LiteralPath $manifest `
        -Value $manifestContent `
        -Encoding UTF8

}
catch {

    Backup-Log "WARNING: Could not create backup manifest: $($_.Exception.Message)"
}

# ============================================================
# VERIFY PAYLOAD
# ============================================================

Backup-Log "Verifying backup payload..."

if (-not (Test-Path -LiteralPath $Payload)) {

    Backup-Log "ERROR: Backup payload does not exist."

    Set-Content `
        -LiteralPath $StatusFile `
        -Value "BACKUP FAILED"

    exit 1
}

$payloadFiles = @(
    Get-ChildItem `
        -LiteralPath $Payload `
        -Recurse `
        -File `
        -ErrorAction SilentlyContinue
)

if ($payloadFiles.Count -eq 0) {

    Backup-Log "ERROR: Backup payload is empty."

    Set-Content `
        -LiteralPath $StatusFile `
        -Value "BACKUP EMPTY"

    exit 1
}

Backup-Log "Payload contains $($payloadFiles.Count) files."

# ============================================================
# CREATE ZIP
# ============================================================

Backup-Log "Creating backup ZIP..."

try {

    Add-Type `
        -AssemblyName System.IO.Compression.FileSystem

    if (Test-Path -LiteralPath $ZipFile) {

        Remove-Item `
            -LiteralPath $ZipFile `
            -Force `
            -ErrorAction Stop
    }

    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $BackupRoot,
        $ZipFile,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

}
catch {

    Backup-Log "ERROR: ZIP creation failed: $($_.Exception.Message)"

    Set-Content `
        -LiteralPath $StatusFile `
        -Value "ZIP CREATION FAILED"

    exit 1
}

# ============================================================
# VERIFY ZIP
# ============================================================

Backup-Log "Validating generated ZIP..."

try {

    $zipInfo = Get-Item `
        -LiteralPath $ZipFile `
        -ErrorAction Stop

    if ($zipInfo.Length -lt 100) {
        throw "Generated ZIP is unexpectedly small."
    }

    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipFile)

    try {

        if ($zip.Entries.Count -eq 0) {
            throw "Generated ZIP contains no entries."
        }

        foreach ($entry in $zip.Entries) {

            $name = $entry.FullName.Replace("\", "/")

            if (
                $name.StartsWith("/") -or
                $name.Contains("../") -or
                $name.StartsWith("../")
            ) {

                throw "Unsafe ZIP entry detected: $name"
            }
        }

        Backup-Log "ZIP validation successful."
        Backup-Log "ZIP entries: $($zip.Entries.Count)"
        Backup-Log "ZIP size: $($zipInfo.Length) bytes"

    }
    finally {

        $zip.Dispose()
    }

}
catch {

    Backup-Log "ERROR: ZIP validation failed: $($_.Exception.Message)"

    Set-Content `
        -LiteralPath $StatusFile `
        -Value "INVALID ZIP"

    exit 1
}

# ============================================================
# BACKUP STATUS
# ============================================================

$status = @"
BACKUP COMPLETED

Created:
$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

ZIP:
$ZipFile

Size:
$((Get-Item $ZipFile).Length) bytes

Payload files:
$($payloadFiles.Count)
"@

Set-Content `
    -LiteralPath $StatusFile `
    -Value $status `
    -Encoding UTF8

# ============================================================
# CLEAN TEMP
# ============================================================

Backup-Log "Cleaning temporary backup directory..."

try {

    Remove-Item `
        -LiteralPath $BackupRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

}
catch {

    Backup-Log "WARNING: temporary backup directory could not be completely removed."
}

# ============================================================
# COMPLETE
# ============================================================

Backup-Log "=============================================="
Backup-Log "DAO BACKUP COMPLETED"
Backup-Log "=============================================="

Write-Host ""
Write-Host "=============================================="
Write-Host "DAO BACKUP READY"
Write-Host "=============================================="
Write-Host ""
Write-Host "Backup ZIP:"
Write-Host $ZipFile
Write-Host ""
Write-Host "Status:"
Write-Host $StatusFile
Write-Host ""
