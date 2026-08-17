[CmdletBinding()]
param(
    [string]$WorkspaceRoot = "D:\DAO-Workspace",
    [string]$LogsRoot      = "D:\DAO-Logs",
    [string]$BackupRoot    = "D:\DAO-Backup"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# PATHS
# ============================================================

$Workspace = $WorkspaceRoot
$Logs      = $LogsRoot
$Backup    = $BackupRoot

$BackupWorkspace = Join-Path $Backup "DAO-Workspace"
$BackupLogs      = Join-Path $Backup "DAO-Logs"
$ManifestFile    = Join-Path $Backup "backup-manifest.txt"

# ============================================================
# INITIALIZE
# ============================================================

New-Item `
    -ItemType Directory `
    -Path $Backup `
    -Force |
    Out-Null

# Clear previous backup so stale files are never mixed with a
# new backup.

Get-ChildItem `
    -LiteralPath $Backup `
    -Force `
    -ErrorAction SilentlyContinue |
    Remove-Item `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

New-Item `
    -ItemType Directory `
    -Path $BackupWorkspace `
    -Force |
    Out-Null

New-Item `
    -ItemType Directory `
    -Path $BackupLogs `
    -Force |
    Out-Null

# ============================================================
# LOGGING
# ============================================================

$BackupLog = Join-Path $Logs "backup.log"

function Write-BackupLog {
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

Write-BackupLog "=============================================="
Write-BackupLog "DAO BACKUP START"
Write-BackupLog "=============================================="

# ============================================================
# COPY WORKSPACE
# ============================================================

if (Test-Path -LiteralPath $Workspace) {

    Write-BackupLog "Copying workspace..."

    $source = (Resolve-Path -LiteralPath $Workspace).Path
    $destination = $BackupWorkspace

    $robocopyArgs = @(
        $source,
        $destination,
        "/E",
        "/R:2",
        "/W:2",
        "/XJ",
        "/COPY:DAT",
        "/DCOPY:DAT"
    )

    # Exclude regeneratable application caches.
    $robocopyArgs += @(
        "/XD",
        (Join-Path $source "Applications\noVNC\.git"),
        (Join-Path $source "Applications\noVNC\node_modules")
    )

    & robocopy @robocopyArgs | Out-Null

    $robocopyCode = $LASTEXITCODE

    # Robocopy 0-7 are success/non-fatal statuses.
    if ($robocopyCode -gt 7) {
        throw "Workspace backup failed. Robocopy exit code: $robocopyCode"
    }

    Write-BackupLog "[OK] Workspace copied."
}
else {
    Write-BackupLog "[WARN] Workspace directory does not exist."
}

# ============================================================
# COPY LOGS
# ============================================================

if (Test-Path -LiteralPath $Logs) {

    Write-BackupLog "Copying logs..."

    $source = (Resolve-Path -LiteralPath $Logs).Path
    $destination = $BackupLogs

    $robocopyArgs = @(
        $source,
        $destination,
        "/E",
        "/R:2",
        "/W:2",
        "/XJ",
        "/COPY:DAT",
        "/DCOPY:DAT"
    )

    & robocopy @robocopyArgs | Out-Null

    $robocopyCode = $LASTEXITCODE

    if ($robocopyCode -gt 7) {
        throw "Logs backup failed. Robocopy exit code: $robocopyCode"
    }

    Write-BackupLog "[OK] Logs copied."
}
else {
    Write-BackupLog "[WARN] Logs directory does not exist."
}

# ============================================================
# REMOVE SENSITIVE / TRANSIENT ITEMS
# ============================================================

# The actual passwords are never intentionally stored by the
# workflow, but remove known transient credential/config files
# if an application happened to create them.

$removePatterns = @(
    "*.tmp",
    "*.temp",
    "*.lock"
)

foreach ($root in @(
    $BackupWorkspace,
    $BackupLogs
)) {

    if (-not (Test-Path -LiteralPath $root)) {
        continue
    }

    foreach ($pattern in $removePatterns) {

        Get-ChildItem `
            -LiteralPath $root `
            -Filter $pattern `
            -Recurse `
            -Force `
            -File `
            -ErrorAction SilentlyContinue |
            Remove-Item `
                -Force `
                -ErrorAction SilentlyContinue
    }
}

# ============================================================
# MANIFEST
# ============================================================

$workspaceFiles = @()

if (Test-Path -LiteralPath $BackupWorkspace) {

    $workspaceFiles = @(
        Get-ChildItem `
            -LiteralPath $BackupWorkspace `
            -Recurse `
            -File `
            -ErrorAction SilentlyContinue
    )
}

$logFiles = @()

if (Test-Path -LiteralPath $BackupLogs) {

    $logFiles = @(
        Get-ChildItem `
            -LiteralPath $BackupLogs `
            -Recurse `
            -File `
            -ErrorAction SilentlyContinue
    )
}

$totalBytes = (
    @($workspaceFiles) + @($logFiles) |
        Measure-Object -Property Length -Sum
).Sum

if ($null -eq $totalBytes) {
    $totalBytes = 0
}

$manifest = @"
DAO WINDOWS DESKTOP BACKUP
==========================

Created:
$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')

Workspace source:
$Workspace

Logs source:
$Logs

Workspace files:
$($workspaceFiles.Count)

Log files:
$($logFiles.Count)

Total bytes:
$totalBytes

Backup format:
DAO-Workspace/
DAO-Logs/
backup-manifest.txt

Passwords:
Not intentionally stored.

GitHub tokens:
Not stored.

Restore:
restore.ps1 restores DAO-Workspace and DAO-Logs.
"@

Set-Content `
    -LiteralPath $ManifestFile `
    -Value $manifest `
    -Encoding UTF8

Write-BackupLog "Workspace files: $($workspaceFiles.Count)"
Write-BackupLog "Log files:       $($logFiles.Count)"
Write-BackupLog "Total bytes:     $totalBytes"

Write-BackupLog "Backup manifest created."
Write-BackupLog "DAO BACKUP COMPLETE."

exit 0
