[CmdletBinding()]
param(
    [string]$RestoreRoot    = "D:\DAO-Restore",
    [string]$WorkspaceRoot  = "D:\DAO-Workspace",
    [string]$LogsRoot      = "D:\DAO-Logs"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ============================================================
# PATHS
# ============================================================

$Restore = $RestoreRoot
$Workspace = $WorkspaceRoot
$Logs = $LogsRoot

$RestoreLog = Join-Path $Logs "restore.log"

# ============================================================
# DIRECTORIES
# ============================================================

New-Item `
    -ItemType Directory `
    -Path $Workspace `
    -Force |
    Out-Null

New-Item `
    -ItemType Directory `
    -Path $Logs `
    -Force |
    Out-Null

# ============================================================
# LOG
# ============================================================

function Write-RestoreLog {
    param(
        [string]$Message
    )

    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"

    Write-Host $line

    try {
        Add-Content `
            -LiteralPath $RestoreLog `
            -Value $line `
            -ErrorAction SilentlyContinue
    }
    catch {
    }
}

Write-RestoreLog "=============================================="
Write-RestoreLog "DAO RESTORE START"
Write-RestoreLog "=============================================="

# ============================================================
# NO BACKUP
# ============================================================

if (-not (Test-Path -LiteralPath $Restore)) {

    Write-RestoreLog "[INFO] No restore directory exists."
    Write-RestoreLog "Nothing to restore."
    exit 0
}

$restoreFiles = @(
    Get-ChildItem `
        -LiteralPath $Restore `
        -Recurse `
        -File `
        -ErrorAction SilentlyContinue
)

if ($restoreFiles.Count -eq 0) {

    Write-RestoreLog "[INFO] Restore directory is empty."
    Write-RestoreLog "Nothing to restore."
    exit 0
}

Write-RestoreLog "Restore files found: $($restoreFiles.Count)"

# ============================================================
# LOCATE BACKUP ROOT
# ============================================================

$sourceWorkspace = Join-Path `
    $Restore `
    "DAO-Workspace"

$sourceLogs = Join-Path `
    $Restore `
    "DAO-Logs"

# Handle possible artifact nesting:
#
# D:\DAO-Restore\DAO-Workspace
#
# OR
#
# D:\DAO-Restore\dao-windows-backup\DAO-Workspace
#

if (-not (Test-Path -LiteralPath $sourceWorkspace)) {

    $candidate = Get-ChildItem `
        -LiteralPath $Restore `
        -Directory `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq "DAO-Workspace"
        } |
        Select-Object -First 1

    if ($candidate) {
        $sourceWorkspace = $candidate.FullName
    }
}

if (-not (Test-Path -LiteralPath $sourceLogs)) {

    $candidate = Get-ChildItem `
        -LiteralPath $Restore `
        -Directory `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq "DAO-Logs"
        } |
        Select-Object -First 1

    if ($candidate) {
        $sourceLogs = $candidate.FullName
    }
}

# ============================================================
# RESTORE WORKSPACE
# ============================================================

if (Test-Path -LiteralPath $sourceWorkspace) {

    Write-RestoreLog "Restoring workspace..."
    Write-RestoreLog "Source: $sourceWorkspace"
    Write-RestoreLog "Target: $Workspace"

    $robocopyArgs = @(
        $sourceWorkspace,
        $Workspace,
        "/E",
        "/R:2",
        "/W:2",
        "/XJ",
        "/COPY:DAT",
        "/DCOPY:DAT"
    )

    & robocopy @robocopyArgs | Out-Null

    $code = $LASTEXITCODE

    if ($code -le 7) {
        Write-RestoreLog "[OK] Workspace restored."
    }
    else {
        Write-RestoreLog `
            "[WARN] Workspace restore returned robocopy code $code."
    }
}
else {
    Write-RestoreLog "[INFO] No DAO-Workspace found in backup."
}

# ============================================================
# RESTORE LOGS
# ============================================================

if (Test-Path -LiteralPath $sourceLogs) {

    Write-RestoreLog "Restoring logs..."
    Write-RestoreLog "Source: $sourceLogs"
    Write-RestoreLog "Target: $Logs"

    $robocopyArgs = @(
        $sourceLogs,
        $Logs,
        "/E",
        "/R:2",
        "/W:2",
        "/XJ",
        "/COPY:DAT",
        "/DCOPY:DAT"
    )

    & robocopy @robocopyArgs | Out-Null

    $code = $LASTEXITCODE

    if ($code -le 7) {
        Write-RestoreLog "[OK] Logs restored."
    }
    else {
        Write-RestoreLog `
            "[WARN] Logs restore returned robocopy code $code."
    }
}
else {
    Write-RestoreLog "[INFO] No DAO-Logs found in backup."
}

# ============================================================
# RESTORE SUMMARY
# ============================================================

$workspaceCount = @(
    Get-ChildItem `
        -LiteralPath $Workspace `
        -Recurse `
        -File `
        -ErrorAction SilentlyContinue
).Count

$logsCount = @(
    Get-ChildItem `
        -LiteralPath $Logs `
        -Recurse `
        -File `
        -ErrorAction SilentlyContinue
).Count

Write-RestoreLog "Workspace files after restore: $workspaceCount"
Write-RestoreLog "Log files after restore:       $logsCount"

Write-RestoreLog "DAO RESTORE COMPLETE."

exit 0
