[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$Workspace = "D:\DAO-Workspace"
$Logs      = "D:\DAO-Logs"
$Staging   = "D:\DAO-Backup-Staging"

$FileZilla = Join-Path $env:APPDATA "FileZilla"
$Geany     = Join-Path $env:APPDATA "geany"

$BackupLog = Join-Path $Logs "backup.log"

New-Item -ItemType Directory -Path $Workspace -Force | Out-Null
New-Item -ItemType Directory -Path $Logs -Force | Out-Null


# ==============================================================
# LOG
# ==============================================================

function Write-BackupLog {

    param(
        [string]$Message,

        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )

    $line = "[{0}] [{1}] {2}" -f `
        (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),
        $Level,
        $Message

    Add-Content `
        -LiteralPath $BackupLog `
        -Value $line `
        -Encoding UTF8

    Write-Host $line
}


# ==============================================================
# ROBOCOPY TREE
# ==============================================================

function Backup-Tree {

    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination,

        [Parameter(Mandatory)]
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Source)) {

        Write-BackupLog `
            "$Label does not exist: $Source" `
            "WARN"

        return $false
    }

    try {

        New-Item `
            -ItemType Directory `
            -Path $Destination `
            -Force | Out-Null

        $args = @(
            $Source,
            $Destination,

            "/E",
            "/COPY:DAT",
            "/DCOPY:DAT",

            "/R:1",
            "/W:1",

            "/XJ",
            "/FFT",
            "/NP"
        )

        Write-BackupLog `
            "Backing up $Label."

        & robocopy @args 2>&1 |
            ForEach-Object {

                $line = [string]$_

                Add-Content `
                    -LiteralPath $BackupLog `
                    -Value $line `
                    -Encoding UTF8
            }

        $code = $LASTEXITCODE

        # Robocopy:
        # 0-7 = success / success with differences
        # >=8 = failure
        if ($code -lt 8) {

            Write-BackupLog `
                "$Label backup completed. Robocopy code: $code"

            return $true
        }

        Write-BackupLog `
            "$Label backup returned Robocopy code $code." `
            "WARN"

        return $false
    }
    catch {

        Write-BackupLog `
            "$Label backup failed: $($_.Exception.Message)" `
            "WARN"

        return $false
    }
}


# ==============================================================
# SANITIZE STAGING
# ==============================================================

function Remove-TemporaryFiles {

    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return
    }

    $patterns = @(
        "*.tmp",
        "*.temp",
        "~*"
    )

    foreach ($pattern in $patterns) {

        try {

            Get-ChildItem `
                -LiteralPath $Root `
                -File `
                -Recurse `
                -Force `
                -Filter $pattern `
                -ErrorAction SilentlyContinue |
                Remove-Item `
                    -Force `
                    -ErrorAction SilentlyContinue
        }
        catch {
        }
    }
}


# ==============================================================
# SECRET FILE SCAN
# ==============================================================

function Remove-PotentialSecretFiles {

    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return
    }

    $files = Get-ChildItem `
        -LiteralPath $Root `
        -File `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    foreach ($file in $files) {

        $name = $file.Name.ToLowerInvariant()

        if (
            $name -match "github.*token" -or
            $name -match "access.*token" -or
            $name -match "vnc.*password" -or
            $name -match "anydesk.*password" -or
            $name -match "private.*key" -or
            $name -match "secret"
        ) {

            Write-BackupLog `
                "Removing potentially sensitive file from artifact: $($file.FullName)" `
                "WARN"

            Remove-Item `
                -LiteralPath $file.FullName `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}


# ==============================================================
# MAIN
# ==============================================================

try {

    Write-BackupLog "============================================================"
    Write-BackupLog "DAO backup starting."
    Write-BackupLog "============================================================"

    # ----------------------------------------------------------
    # Clean previous staging
    # ----------------------------------------------------------

    if (Test-Path -LiteralPath $Staging) {

        Remove-Item `
            -LiteralPath $Staging `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    New-Item `
        -ItemType Directory `
        -Path $Staging `
        -Force | Out-Null

    # ----------------------------------------------------------
    # Destinations
    # ----------------------------------------------------------

    $workspaceDestination =
        Join-Path $Staging "workspace"

    $fileZillaDestination =
        Join-Path $Staging "filezilla"

    $geanyDestination =
        Join-Path $Staging "geany"

    $daoDataDestination =
        Join-Path $Staging "dao-data"

    $logsDestination =
        Join-Path $Staging "logs"

    $results = @()

    # ----------------------------------------------------------
    # Workspace
    # ----------------------------------------------------------

    $results += Backup-Tree `
        -Source $Workspace `
        -Destination $workspaceDestination `
        -Label "DAO workspace"

    # ----------------------------------------------------------
    # FileZilla
    # ----------------------------------------------------------

    $results += Backup-Tree `
        -Source $FileZilla `
        -Destination $fileZillaDestination `
        -Label "FileZilla configuration"

    # ----------------------------------------------------------
    # Geany
    # ----------------------------------------------------------

    $results += Backup-Tree `
        -Source $Geany `
        -Destination $geanyDestination `
        -Label "Geany configuration"

    # ----------------------------------------------------------
    # DAO metadata
    # ----------------------------------------------------------

    New-Item `
        -ItemType Directory `
        -Path $daoDataDestination `
        -Force | Out-Null

    $metadata = @(
        "Backup time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')",
        "Repository: $env:GITHUB_REPOSITORY",
        "Workflow: $env:GITHUB_WORKFLOW",
        "Run ID: $env:GITHUB_RUN_ID",
        "Runner OS: $env:RUNNER_OS",
        "Workspace: $Workspace"
    )

    Set-Content `
        -LiteralPath (
            Join-Path `
                $daoDataDestination `
                "backup-metadata.txt"
        ) `
        -Value $metadata `
        -Encoding UTF8

    $results += $true

    # ----------------------------------------------------------
    # Logs
    # ----------------------------------------------------------

    $results += Backup-Tree `
        -Source $Logs `
        -Destination $logsDestination `
        -Label "DAO logs"

    # ----------------------------------------------------------
    # Remove temporary files
    # ----------------------------------------------------------

    Remove-TemporaryFiles `
        -Root $Staging

    # ----------------------------------------------------------
    # Remove obvious secret files
    # ----------------------------------------------------------

    Remove-PotentialSecretFiles `
        -Root $Staging

    # ----------------------------------------------------------
    # Verify backup
    # ----------------------------------------------------------

    $entries = Get-ChildItem `
        -LiteralPath $Staging `
        -Force `
        -ErrorAction SilentlyContinue

    if ($null -eq $entries -or @($entries).Count -eq 0) {

        Write-BackupLog `
            "Backup staging directory is empty." `
            "ERROR"

        Set-Content `
            -LiteralPath (
                Join-Path $Logs "backup-status.txt"
            ) `
            -Value "Backup failed" `
            -Encoding UTF8

        exit 1
    }

    $failed = @(
        $results |
        Where-Object { $_ -eq $false }
    ).Count

    if ($failed -eq 0) {

        $status = "Backup completed successfully"

        Write-BackupLog $status
    }
    else {

        $status = "Backup completed with warnings"

        Write-BackupLog `
            $status `
            "WARN"
    }

    Set-Content `
        -LiteralPath (
            Join-Path $Logs "backup-status.txt"
        ) `
        -Value $status `
        -Encoding UTF8

    Write-BackupLog `
        "Backup staging: $Staging"

    Write-BackupLog `
        "Backup completed."
}
catch {

    Write-BackupLog `
        "Unexpected backup exception: $($_.Exception.Message)" `
        "ERROR"

    Set-Content `
        -LiteralPath (
            Join-Path $Logs "backup-status.txt"
        ) `
        -Value "Backup completed with warnings" `
        -Encoding UTF8

    exit 1
}
