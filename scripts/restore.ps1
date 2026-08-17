[CmdletBinding()]
param(
    [string]$RestoreRoot   = "D:\DAO-Restore",
    [string]$WorkspaceRoot = "D:\DAO-Workspace",
    [string]$LogsRoot      = "D:\DAO-Logs"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ============================================================
# PATHS
# ============================================================

$Workspace = $WorkspaceRoot
$Logs      = $LogsRoot
$Restore   = $RestoreRoot

$RestoreLog   = Join-Path $Logs "restore.log"
$StatusFile   = Join-Path $Logs "restore-status.txt"
$TempRoot     = Join-Path $env:RUNNER_TEMP "dao-restore"
$ArtifactZip  = Join-Path $TempRoot "backup.zip"
$ExtractDir   = Join-Path $TempRoot "extracted"

# ============================================================
# INITIALIZE DIRECTORIES
# ============================================================

New-Item -ItemType Directory -Force -Path $Workspace | Out-Null
New-Item -ItemType Directory -Force -Path $Logs      | Out-Null
New-Item -ItemType Directory -Force -Path $Restore   | Out-Null

# ============================================================
# LOGGING
# ============================================================

function Restore-Log {
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

function Set-Restore-Status {
    param(
        [string]$Status
    )

    try {
        Set-Content `
            -LiteralPath $StatusFile `
            -Value $Status `
            -Encoding UTF8 `
            -ErrorAction SilentlyContinue
    }
    catch {
    }
}

# ============================================================
# SAFE TREE COPY
#
# Only user/data files are restored.
# Executables, scripts and potentially executable content are
# intentionally excluded.
# ============================================================

function Copy-SafeTree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Restore-Log "Source does not exist: $Source"
        return
    }

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $Destination |
        Out-Null

    # --------------------------------------------------------
    # Files that should not be restored from an artifact.
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

    $files = Get-ChildItem `
        -LiteralPath $Source `
        -Force `
        -Recurse `
        -File `
        -ErrorAction SilentlyContinue

    foreach ($file in $files) {

        try {

            # ------------------------------------------------
            # Calculate relative path.
            # ------------------------------------------------

            $sourceRoot = $Source.TrimEnd('\')

            $relative = $file.FullName.Substring(
                $sourceRoot.Length
            ).TrimStart('\')

            if ([string]::IsNullOrWhiteSpace($relative)) {
                continue
            }

            # ------------------------------------------------
            # Check directory names.
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
                continue
            }

            # ------------------------------------------------
            # Check dangerous extension.
            # ------------------------------------------------

            $extension = $file.Extension.ToLowerInvariant()

            if ($dangerousExtensions -contains $extension) {
                continue
            }

            # ------------------------------------------------
            # Destination.
            # ------------------------------------------------

            $target = Join-Path `
                $Destination `
                $relative

            $targetDirectory = Split-Path `
                -Path $target `
                -Parent

            New-Item `
                -ItemType Directory `
                -Force `
                -Path $targetDirectory |
                Out-Null

            # ------------------------------------------------
            # Copy.
            # ------------------------------------------------

            Copy-Item `
                -LiteralPath $file.FullName `
                -Destination $target `
                -Force `
                -ErrorAction Stop
        }
        catch {

            Restore-Log `
                "WARNING: Could not restore '$($file.FullName)': $($_.Exception.Message)"
        }
    }
}

# ============================================================
# START
# ============================================================

Restore-Log "=============================================="
Restore-Log "DAO RESTORE START"
Restore-Log "=============================================="

Restore-Log "Restore root: $Restore"
Restore-Log "Workspace:    $Workspace"
Restore-Log "Logs:         $Logs"

# ============================================================
# GITHUB TOKEN
# ============================================================

$token = [Environment]::GetEnvironmentVariable("GH_TOKEN")

if ([string]::IsNullOrWhiteSpace($token)) {

    Restore-Log "GH_TOKEN is not available."
    Restore-Log "No artifact restore can be performed."

    Set-Restore-Status "NO TOKEN - NO RESTORE"

    exit 0
}

# ============================================================
# REPOSITORY
# ============================================================

$repo = [Environment]::GetEnvironmentVariable("GITHUB_REPOSITORY")

if ([string]::IsNullOrWhiteSpace($repo)) {

    Restore-Log "GITHUB_REPOSITORY is not available."

    Set-Restore-Status "NO REPOSITORY - NO RESTORE"

    exit 0
}

Restore-Log "Repository: $repo"

# ============================================================
# GH CLI
# ============================================================

$gh = Get-Command gh.exe -ErrorAction SilentlyContinue

if (-not $gh) {

    Restore-Log "GitHub CLI (gh.exe) was not found."
    Set-Restore-Status "GH CLI NOT FOUND"

    exit 0
}

Restore-Log "GitHub CLI: $($gh.Source)"

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

New-Item `
    -ItemType Directory `
    -Force `
    -Path $ExtractDir |
    Out-Null

# ============================================================
# FIND PREVIOUS ARTIFACT
# ============================================================

Restore-Log "Searching for previous dao-windows-backup artifact..."

$artifactList = $null

try {

    $json = & $gh.Source api `
        "repos/$repo/actions/artifacts?per_page=100" `
        --header "Accept: application/vnd.github+json" `
        --header "X-GitHub-Api-Version: 2022-11-28" `
        2>&1

    if ($LASTEXITCODE -ne 0) {

        Restore-Log "GitHub artifact API request failed."

        if ($json) {
            Restore-Log (($json | Out-String).Trim())
        }

        Set-Restore-Status "ARTIFACT API FAILED"

        exit 0
    }

    if ($null -eq $json) {
        Restore-Log "GitHub returned an empty response."
        Set-Restore-Status "EMPTY ARTIFACT RESPONSE"
        exit 0
    }

    $jsonText = ($json -join "`n")

    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        Restore-Log "GitHub returned an empty JSON response."
        Set-Restore-Status "EMPTY ARTIFACT RESPONSE"
        exit 0
    }

    $artifactList = $jsonText | ConvertFrom-Json
}
catch {

    Restore-Log `
        "Artifact API query failed: $($_.Exception.Message)"

    Set-Restore-Status "ARTIFACT API FAILED"

    exit 0
}

if ($null -eq $artifactList) {

    Restore-Log "No artifact response was received."

    Set-Restore-Status "NO ARTIFACT RESPONSE"

    exit 0
}

# ============================================================
# SELECT ARTIFACT
# ============================================================

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

    Set-Restore-Status "NO PREVIOUS BACKUP"

    exit 0
}

# ------------------------------------------------------------
# Prefer an artifact that is not from the current run.
# ------------------------------------------------------------

$currentRunId = [Environment]::GetEnvironmentVariable("GITHUB_RUN_ID")

$selected = $null

foreach ($artifact in $artifacts) {

    $candidateRunId = ""

    try {
        $candidateRunId = [string]$artifact.workflow_run.id
    }
    catch {
        $candidateRunId = ""
    }

    if (
        -not [string]::IsNullOrWhiteSpace($currentRunId) -and
        $candidateRunId -eq $currentRunId
    ) {
        continue
    }

    $selected = $artifact
    break
}

if ($null -eq $selected) {
    $selected = $artifacts[0]
}

Restore-Log "Previous backup selected."

Restore-Log "Artifact ID: $($selected.id)"
Restore-Log "Name:        $($selected.name)"
Restore-Log "Created:     $($selected.created_at)"
Restore-Log "Size:        $($selected.size_in_bytes) bytes"

try {
    Restore-Log "Workflow run: $($selected.workflow_run.id)"
}
catch {
}

# ============================================================
# DOWNLOAD ARTIFACT
#
# IMPORTANT:
# Use gh api --output rather than PowerShell stdout redirection.
# This avoids corrupting binary ZIP data.
# ============================================================

Restore-Log "Downloading DAO backup artifact..."

try {

    & $gh.Source api `
        "repos/$repo/actions/artifacts/$($selected.id)/zip" `
        --header "Accept: application/vnd.github+json" `
        --header "X-GitHub-Api-Version: 2022-11-28" `
        --output $ArtifactZip

    if ($LASTEXITCODE -ne 0) {
        throw "gh api returned exit code $LASTEXITCODE"
    }
}
catch {

    Restore-Log `
        "Artifact download failed: $($_.Exception.Message)"

    Set-Restore-Status "DOWNLOAD FAILED"

    exit 0
}

# ============================================================
# CHECK DOWNLOADED ZIP
# ============================================================

if (-not (Test-Path -LiteralPath $ArtifactZip -PathType Leaf)) {

    Restore-Log "Downloaded ZIP does not exist."

    Set-Restore-Status "ZIP NOT FOUND"

    exit 0
}

try {

    $fileInfo = Get-Item `
        -LiteralPath $ArtifactZip `
        -ErrorAction Stop

    Restore-Log "Downloaded ZIP size: $($fileInfo.Length) bytes"

    if ($fileInfo.Length -lt 100) {

        Restore-Log "Downloaded ZIP appears empty or invalid."

        Set-Restore-Status "INVALID ZIP"

        exit 0
    }
}
catch {

    Restore-Log "Could not inspect downloaded ZIP."

    Set-Restore-Status "ZIP INSPECTION FAILED"

    exit 0
}

# ============================================================
# VALIDATE ZIP
# ============================================================

Restore-Log "Validating ZIP contents..."

try {

    Add-Type `
        -AssemblyName System.IO.Compression.FileSystem `
        -ErrorAction SilentlyContinue

    $zip = [System.IO.Compression.ZipFile]::OpenRead(
        $ArtifactZip
    )

    try {

        if ($zip.Entries.Count -eq 0) {
            throw "ZIP contains no entries."
        }

        foreach ($entry in $zip.Entries) {

            $fullName = $entry.FullName.Replace("\", "/")

            # --------------------------------------------
            # Prevent path traversal.
            # --------------------------------------------

            if (
                $fullName.StartsWith("/") -or
                $fullName.StartsWith("../") -or
                $fullName.Contains("/../") -or
                $fullName.Contains(":/")
            ) {
                throw "Unsafe ZIP path detected: $fullName"
            }
        }

        Restore-Log "ZIP validation successful."
        Restore-Log "ZIP entries: $($zip.Entries.Count)"
    }
    finally {

        $zip.Dispose()
    }
}
catch {

    Restore-Log `
        "ZIP validation failed: $($_.Exception.Message)"

    Set-Restore-Status "INVALID ZIP"

    exit 0
}

# ============================================================
# EXTRACT
# ============================================================

Restore-Log "Extracting backup ZIP..."

try {

    Expand-Archive `
        -LiteralPath $ArtifactZip `
        -DestinationPath $ExtractDir `
        -Force `
        -ErrorAction Stop

    Restore-Log "ZIP extraction completed."
}
catch {

    Restore-Log `
        "ZIP extraction failed: $($_.Exception.Message)"

    Set-Restore-Status "EXTRACTION FAILED"

    exit 0
}

# ============================================================
# SHOW EXTRACTED STRUCTURE
# ============================================================

Restore-Log "Inspecting extracted backup..."

try {

    Get-ChildItem `
        -LiteralPath $ExtractDir `
        -Force `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Select-Object `
            FullName,
            Length,
            PSIsContainer |
        Format-Table -AutoSize |
        Out-String -Width 240 |
        ForEach-Object {
            Restore-Log $_
        }
}
catch {
}

# ============================================================
# LOCATE BACKUP PAYLOAD
#
# upload-artifact can produce slightly different root layouts.
# We therefore locate workspace/FileZilla/Geany/dao-data
# recursively instead of assuming one exact root directory.
# ============================================================

function Find-BackupDirectory {
    param(
        [string]$Root,
        [string]$DirectoryName
    )

    # First try direct child.
    $direct = Join-Path $Root $DirectoryName

    if (Test-Path -LiteralPath $direct -PathType Container) {
        return $direct
    }

    # Then recursively search.
    try {

        $found = Get-ChildItem `
            -LiteralPath $Root `
            -Directory `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -eq $DirectoryName
            } |
            Select-Object -First 1

        if ($found) {
            return $found.FullName
        }
    }
    catch {
    }

    return $null
}

# ============================================================
# FIND WORKSPACE
# ============================================================

$workspaceBackup = Find-BackupDirectory `
    -Root $ExtractDir `
    -DirectoryName "workspace"

if ($workspaceBackup) {

    Restore-Log "Workspace backup found:"
    Restore-Log $workspaceBackup

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
# FILEZILLA
# ============================================================

$filezillaBackup = Find-BackupDirectory `
    -Root $ExtractDir `
    -DirectoryName "FileZilla"

if ($filezillaBackup) {

    $filezillaDestination = Join-Path `
        $env:APPDATA `
        "FileZilla"

    Restore-Log "FileZilla backup found."

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $filezillaDestination |
        Out-Null

    Restore-Log "Restoring FileZilla configuration..."

    Copy-SafeTree `
        -Source $filezillaBackup `
        -Destination $filezillaDestination

    Restore-Log "FileZilla restore completed."
}
else {

    Restore-Log "No FileZilla configuration in backup."
}

# ============================================================
# GEANY
# ============================================================

$geanyBackup = Find-BackupDirectory `
    -Root $ExtractDir `
    -DirectoryName "Geany"

if ($geanyBackup) {

    $geanyDestination = Join-Path `
        $env:APPDATA `
        "geany"

    Restore-Log "Geany backup found."

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $geanyDestination |
        Out-Null

    Restore-Log "Restoring Geany configuration..."

    Copy-SafeTree `
        -Source $geanyBackup `
        -Destination $geanyDestination

    Restore-Log "Geany restore completed."
}
else {

    Restore-Log "No Geany configuration in backup."
}

# ============================================================
# DAO DATA
# ============================================================

$daoDataBackup = Find-BackupDirectory `
    -Root $ExtractDir `
    -DirectoryName "dao-data"

if ($daoDataBackup) {

    Restore-Log "DAO-specific data backup found."

    Restore-Log "Restoring DAO-specific data..."

    Copy-SafeTree `
        -Source $daoDataBackup `
        -Destination $Workspace

    Restore-Log "DAO-specific data restore completed."
}
else {

    Restore-Log "No DAO-specific data directory in backup."
}

# ============================================================
# RESTORE METADATA
# ============================================================

$metadataBackup = Find-BackupDirectory `
    -Root $ExtractDir `
    -DirectoryName "metadata"

if ($metadataBackup) {

    $metadataDestination = Join-Path `
        $Workspace `
        ".dao-metadata"

    Restore-Log "Restoring DAO metadata..."

    Copy-SafeTree `
        -Source $metadataBackup `
        -Destination $metadataDestination

    Restore-Log "DAO metadata restore completed."
}

# ============================================================
# SUMMARY
# ============================================================

$workspaceExists = Test-Path `
    -LiteralPath $Workspace `
    -PathType Container

$workspaceFileCount = 0

if ($workspaceExists) {

    try {

        $workspaceFileCount = @(
            Get-ChildItem `
                -LiteralPath $Workspace `
                -Recurse `
                -File `
                -ErrorAction SilentlyContinue
        ).Count
    }
    catch {
        $workspaceFileCount = 0
    }
}

# ============================================================
# STATUS
# ============================================================

Set-Restore-Status `
    "RESTORE COMPLETED`r`nWorkspace files restored/present: $workspaceFileCount"

Restore-Log "=============================================="
Restore-Log "DAO RESTORE COMPLETED"
Restore-Log "=============================================="

Restore-Log "Workspace: $Workspace"
Restore-Log "Files currently present: $workspaceFileCount"

# ============================================================
# CLEAN TEMP
# ============================================================

try {

    Remove-Item `
        -LiteralPath $TempRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}
catch {
}

Restore-Log "Temporary restore files cleaned."

Restore-Log "DAO restore process finished."
