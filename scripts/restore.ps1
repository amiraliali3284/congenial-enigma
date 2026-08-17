[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$Workspace = "D:\DAO-Workspace"
$Logs      = "D:\DAO-Logs"
$Tools     = "D:\DAO-Tools"
$Temp      = "D:\DAO-Restore"

$RestoreLog = Join-Path $Logs "restore.log"

New-Item -ItemType Directory -Path $Workspace -Force | Out-Null
New-Item -ItemType Directory -Path $Logs -Force | Out-Null
New-Item -ItemType Directory -Path $Tools -Force | Out-Null
New-Item -ItemType Directory -Path $Temp -Force | Out-Null


# ==============================================================
# LOG
# ==============================================================

function Write-RestoreLog {
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
        -LiteralPath $RestoreLog `
        -Value $line `
        -Encoding UTF8

    Write-Host $line
}


# ==============================================================
# SAFE COPY
# ==============================================================

function Restore-SafeTree {

    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination,

        [Parameter(Mandatory)]
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Source)) {

        Write-RestoreLog `
            "$Label does not exist in backup." `
            "WARN"

        return
    }

    New-Item `
        -ItemType Directory `
        -Path $Destination `
        -Force | Out-Null

    $blockedExtensions = @(
        ".exe",
        ".dll",
        ".msi",
        ".com",
        ".scr",
        ".bat",
        ".cmd",
        ".ps1",
        ".psm1",
        ".vbs",
        ".vbe",
        ".js",
        ".jse",
        ".wsf",
        ".wsh"
    )

    $files = Get-ChildItem `
        -LiteralPath $Source `
        -File `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    foreach ($file in $files) {

        try {

            $extension = $file.Extension.ToLowerInvariant()

            if ($blockedExtensions -contains $extension) {

                Write-RestoreLog `
                    "Skipped executable/script: $($file.Name)" `
                    "WARN"

                continue
            }

            $relative = `
                $file.FullName.Substring(
                    $Source.Length
                ).TrimStart("\")

            $target = Join-Path `
                $Destination `
                $relative

            $parent = Split-Path `
                -Parent `
                $target

            New-Item `
                -ItemType Directory `
                -Path $parent `
                -Force | Out-Null

            Copy-Item `
                -LiteralPath $file.FullName `
                -Destination $target `
                -Force `
                -ErrorAction Stop
        }
        catch {

            Write-RestoreLog `
                "Could not restore $($file.FullName): $($_.Exception.Message)" `
                "WARN"
        }
    }
}


# ==============================================================
# MAIN
# ==============================================================

try {

    Write-RestoreLog "============================================================"
    Write-RestoreLog "DAO restore starting."
    Write-RestoreLog "============================================================"

    if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {

        Write-RestoreLog `
            "GITHUB_TOKEN is unavailable. Continuing without restore." `
            "WARN"

        Set-Content `
            -LiteralPath (Join-Path $Logs "restore-status.txt") `
            -Value "No restore: GitHub token unavailable." `
            -Encoding UTF8

        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {

        Write-RestoreLog `
            "GITHUB_REPOSITORY is unavailable." `
            "WARN"

        exit 0
    }

    $headers = @{
        Authorization = "Bearer $env:GITHUB_TOKEN"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2026-03-10"
        "User-Agent" = "DAO-Windows-Desktop"
    }

    $repo = $env:GITHUB_REPOSITORY

    $apiUrl =
        "https://api.github.com/repos/$repo/actions/artifacts" +
        "?name=dao-windows-backup&per_page=100"

    Write-RestoreLog `
        "Searching for previous DAO backup artifact."

    $response = Invoke-RestMethod `
        -Uri $apiUrl `
        -Headers $headers `
        -Method Get `
        -ErrorAction Stop

    if ($null -eq $response.artifacts) {

        Write-RestoreLog `
            "No artifacts were returned."

        exit 0
    }

    $currentRunId = ""

    if ($null -ne $env:CURRENT_RUN_ID) {
        $currentRunId = [string]$env:CURRENT_RUN_ID
    }

    $candidate = @(
        $response.artifacts |
        Where-Object {

            $_.name -eq "dao-windows-backup" -and
            $_.expired -ne $true -and
            $null -ne $_.id -and
            [string]$_.workflow_run.id -ne $currentRunId
        } |
        Sort-Object `
            -Property created_at `
            -Descending
    ) | Select-Object -First 1

    if ($null -eq $candidate) {

        Write-RestoreLog `
            "No previous DAO backup found."

        Set-Content `
            -LiteralPath (Join-Path $Logs "restore-status.txt") `
            -Value "No previous backup found. Fresh environment." `
            -Encoding UTF8

        exit 0
    }

    Write-RestoreLog `
        "Selected artifact ID: $($candidate.id)"

    Write-RestoreLog `
        "Artifact created: $($candidate.created_at)"

    $zipPath = Join-Path `
        $Temp `
        "dao-windows-backup.zip"

    Remove-Item `
        -LiteralPath $zipPath `
        -Force `
        -ErrorAction SilentlyContinue

    $downloadUrl =
        "https://api.github.com/repos/$repo/actions/artifacts/" +
        "$($candidate.id)/zip"

    Write-RestoreLog `
        "Downloading backup."

    Invoke-WebRequest `
        -Uri $downloadUrl `
        -Headers $headers `
        -OutFile $zipPath `
        -UseBasicParsing `
        -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw "Backup ZIP was not downloaded."
    }

    $zipInfo = Get-Item `
        -LiteralPath $zipPath

    if ($zipInfo.Length -lt 100) {
        throw "Backup ZIP is unexpectedly small."
    }

    # ----------------------------------------------------------
    # ZIP VALIDATION
    # ----------------------------------------------------------

    Add-Type `
        -AssemblyName System.IO.Compression.FileSystem

    $archive = $null

    try {

        $archive = [System.IO.Compression.ZipFile]::OpenRead(
            $zipPath
        )

        if ($archive.Entries.Count -eq 0) {
            throw "Backup ZIP contains zero entries."
        }

        Write-RestoreLog `
            "ZIP validation successful. Entries: $($archive.Entries.Count)"
    }
    finally {

        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }

    # ----------------------------------------------------------
    # EXTRACT
    # ----------------------------------------------------------

    $extractPath = Join-Path `
        $Temp `
        "extracted"

    if (Test-Path -LiteralPath $extractPath) {

        Remove-Item `
            -LiteralPath $extractPath `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    New-Item `
        -ItemType Directory `
        -Path $extractPath `
        -Force | Out-Null

    Expand-Archive `
        -LiteralPath $zipPath `
        -DestinationPath $extractPath `
        -Force `
        -ErrorAction Stop

    # ----------------------------------------------------------
    # EXPECTED BACKUP STRUCTURE
    # ----------------------------------------------------------

    $workspaceSource = Join-Path $extractPath "workspace"
    $fileZillaSource = Join-Path $extractPath "filezilla"
    $geanySource     = Join-Path $extractPath "geany"
    $daoDataSource   = Join-Path $extractPath "dao-data"
    $logsSource      = Join-Path $extractPath "logs"

    # ----------------------------------------------------------
    # WORKSPACE
    # ----------------------------------------------------------

    Restore-SafeTree `
        -Source $workspaceSource `
        -Destination $Workspace `
        -Label "DAO workspace"

    # ----------------------------------------------------------
    # FILEZILLA
    # ----------------------------------------------------------

    $fileZillaDestination = Join-Path `
        $env:APPDATA `
        "FileZilla"

    Restore-SafeTree `
        -Source $fileZillaSource `
        -Destination $fileZillaDestination `
        -Label "FileZilla configuration"

    # ----------------------------------------------------------
    # GEANY
    # ----------------------------------------------------------

    $geanyDestination = Join-Path `
        $env:APPDATA `
        "geany"

    Restore-SafeTree `
        -Source $geanySource `
        -Destination $geanyDestination `
        -Label "Geany configuration"

    # ----------------------------------------------------------
    # DAO DATA
    # ----------------------------------------------------------

    Restore-SafeTree `
        -Source $daoDataSource `
        -Destination $Workspace `
        -Label "DAO-specific data"

    # ----------------------------------------------------------
    # LOGS
    # ----------------------------------------------------------

    Restore-SafeTree `
        -Source $logsSource `
        -Destination $Logs `
        -Label "DAO logs"

    $status = `
        "Restore completed from artifact ID " +
        "$($candidate.id), created $($candidate.created_at)."

    Set-Content `
        -LiteralPath (Join-Path $Logs "restore-status.txt") `
        -Value $status `
        -Encoding UTF8

    Write-RestoreLog $status
}
catch {

    Write-RestoreLog `
        "Restore encountered an error but will not stop the desktop: $($_.Exception.Message)" `
        "ERROR"

    Set-Content `
        -LiteralPath (Join-Path $Logs "restore-status.txt") `
        -Value "Restore completed with warnings. See restore.log." `
        -Encoding UTF8

    # Restore is deliberately non-fatal.
    exit 0
}
finally {

    if (Test-Path -LiteralPath $Temp) {

        Remove-Item `
            -LiteralPath $Temp `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}
