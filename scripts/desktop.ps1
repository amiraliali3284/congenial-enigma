[CmdletBinding()]
param(
    [string]$WorkspaceRoot = "D:\DAO-Workspace",
    [string]$LogsRoot      = "D:\DAO-Logs",
    [string]$ToolsRoot     = "D:\DAO-Tools",

    [string]$VncPassword     = "",
    [string]$AnyDeskPassword = "",

    [switch]$SupervisorOnly,
    [switch]$StopServices
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ============================================================
# PATHS
# ============================================================

$Workspace = $WorkspaceRoot
$Logs      = $LogsRoot
$Tools     = $ToolsRoot

$AppsDir   = Join-Path $Workspace "Applications"
$NoVncDir  = Join-Path $AppsDir "noVNC"

$VncPort = 5900
$WebPort = 6080

$TunnelUrlFile = Join-Path $Logs "tunnel-url.txt"
$NoVncUrlFile  = Join-Path $Logs "novnc-url.txt"
$AnyDeskIdFile = Join-Path $Logs "anydesk-id.txt"

$VncLog      = Join-Path $Logs "vnc.log"
$WebLog      = Join-Path $Logs "websockify.log"
$WebErrorLog = Join-Path $Logs "websockify-error.log"
$CloudLog    = Join-Path $Logs "cloudflared.log"
$CloudErrLog = Join-Path $Logs "cloudflared-error.log"
$AnyDeskLog  = Join-Path $Logs "anydesk.log"
$Connection  = Join-Path $Logs "connection-info.txt"

# ============================================================
# DIRECTORIES
# ============================================================

New-Item -ItemType Directory -Force -Path $Workspace | Out-Null
New-Item -ItemType Directory -Force -Path $Logs      | Out-Null
New-Item -ItemType Directory -Force -Path $Tools     | Out-Null
New-Item -ItemType Directory -Force -Path $AppsDir   | Out-Null

# ============================================================
# HELPERS
# ============================================================

function Write-Log {
    param(
        [string]$Message,
        [string]$File = ""
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"

    Write-Host $line

    if (-not [string]::IsNullOrWhiteSpace($File)) {
        try {
            Add-Content `
                -LiteralPath $File `
                -Value $line `
                -ErrorAction SilentlyContinue
        }
        catch {
        }
    }
}

function Test-TcpPort {
    param(
        [string]$HostName = "127.0.0.1",
        [int]$Port,
        [int]$TimeoutMs = 1000
    )

    $client = $null

    try {
        $client = [System.Net.Sockets.TcpClient]::new()

        $async = $client.BeginConnect(
            $HostName,
            $Port,
            $null,
            $null
        )

        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            return $false
        }

        $client.EndConnect($async)

        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $client) {
            try {
                $client.Close()
            }
            catch {
            }
        }
    }
}

function Get-PortOwner {
    param(
        [int]$Port
    )

    try {
        $connections = Get-NetTCPConnection `
            -LocalPort $Port `
            -ErrorAction SilentlyContinue

        foreach ($connection in $connections) {

            $processId = $connection.OwningProcess

            if ($processId -and $processId -ne 0) {

                try {
                    $process = Get-Process `
                        -Id $processId `
                        -ErrorAction SilentlyContinue

                    if ($process) {
                        return "$($process.ProcessName) PID=$processId"
                    }
                }
                catch {
                }
            }
        }
    }
    catch {
    }

    return "unknown"
}

function Stop-ProcessesByName {
    param(
        [string[]]$Names
    )

    foreach ($name in $Names) {

        try {
            $processes = Get-Process `
                -Name $name `
                -ErrorAction SilentlyContinue

            foreach ($process in $processes) {

                Write-Log "Stopping $name PID=$($process.Id)"

                try {
                    Stop-Process `
                        -Id $process.Id `
                        -Force `
                        -ErrorAction SilentlyContinue
                }
                catch {
                }
            }
        }
        catch {
        }
    }
}

function Wait-ForPort {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {

        if (Test-TcpPort -Port $Port) {
            return $true
        }

        Start-Sleep -Seconds 1
    }

    return $false
}

function Find-Executable {
    param(
        [string[]]$Names,
        [string[]]$Paths = @()
    )

    foreach ($name in $Names) {

        try {
            $cmd = Get-Command $name -ErrorAction SilentlyContinue

            if ($cmd) {
                return $cmd.Source
            }
        }
        catch {
        }
    }

    foreach ($path in $Paths) {

        try {
            if ($path -and (Test-Path -LiteralPath $path)) {
                return $path
            }
        }
        catch {
        }
    }

    return $null
}

function Install-WingetPackage {
    param(
        [string]$Id,
        [string]$DisplayName,
        [switch]$Optional
    )

    Write-Log "Checking $DisplayName..."

    try {

        $list = & winget list `
            --id $Id `
            --exact `
            --accept-source-agreements `
            --disable-interactivity `
            2>$null

        if ($LASTEXITCODE -eq 0 -and $list) {
            Write-Log "[OK] $DisplayName already installed."
            return $true
        }
    }
    catch {
    }

    Write-Log "Installing $DisplayName..."

    try {

        & winget install `
            --id $Id `
            --exact `
            --silent `
            --accept-package-agreements `
            --accept-source-agreements `
            --disable-interactivity

        if ($LASTEXITCODE -eq 0) {
            Write-Log "[OK] $DisplayName installed."
            return $true
        }

        Write-Log "[WARN] winget exit code $LASTEXITCODE for $DisplayName."

        if ($Optional) {
            return $false
        }

        return $false
    }
    catch {

        Write-Log `
            "[WARN] Could not install $DisplayName : $($_.Exception.Message)"

        return $false
    }
}

function Start-TightVnc {
    param(
        [string]$Executable
    )

    if (-not $Executable) {
        Write-Log "[WARN] TightVNC executable not found."
        return $false
    }

    try {

        & $Executable -start -silent 2>&1 |
            Out-File `
                -FilePath $VncLog `
                -Append `
                -Encoding utf8
    }
    catch {
        Write-Log `
            "[WARN] TightVNC start failed: $($_.Exception.Message)"
    }

    if (Wait-ForPort -Port $VncPort -TimeoutSeconds 15) {
        Write-Log "[OK] TightVNC TCP 5900 is listening."
        return $true
    }

    Write-Log "[WARN] TightVNC TCP 5900 is not listening."
    return $false
}

function Start-Websockify {
    param(
        [string]$Executable
    )

    if (-not $Executable) {
        Write-Log "[WARN] websockify executable not found."
        return $false
    }

    if (Test-TcpPort -Port $WebPort) {
        Write-Log "[OK] websockify TCP 6080 already listening."
        return $true
    }

    $args = @(
        "--web",
        $NoVncDir,
        "$WebPort",
        "127.0.0.1:$VncPort"
    )

    try {

        Start-Process `
            -FilePath $Executable `
            -ArgumentList $args `
            -WorkingDirectory $NoVncDir `
            -RedirectStandardOutput $WebLog `
            -RedirectStandardError $WebErrorLog `
            -WindowStyle Hidden `
            | Out-Null
    }
    catch {

        Write-Log `
            "[WARN] websockify start failed: $($_.Exception.Message)"

        return $false
    }

    if (Wait-ForPort -Port $WebPort -TimeoutSeconds 30) {
        Write-Log "[OK] websockify TCP 6080 is listening."
        return $true
    }

    Write-Log "[WARN] websockify TCP 6080 did not start."
    return $false
}

function Stop-DesktopServices {

    Write-Log "Stopping DAO remote-access services..."

    Stop-ProcessesByName @(
        "cloudflared",
        "websockify"
    )

    if ($script:tightVnc) {

        try {

            & $script:tightVnc -stop -silent 2>&1 |
                Out-File `
                    -FilePath $VncLog `
                    -Append `
                    -Encoding utf8
        }
        catch {
        }
    }

    Write-Log "DAO remote-access cleanup completed."
}

# ============================================================
# STOP MODE
# ============================================================

if ($StopServices) {

    Write-Log "=============================================="
    Write-Log "DAO DESKTOP STOP MODE"
    Write-Log "=============================================="

    $script:tightVnc = Find-Executable `
        -Names @(
            "tvnserver.exe",
            "winvnc.exe"
        ) `
        -Paths @(
            "$env:ProgramFiles\TightVNC\tvnserver.exe",
            "$env:ProgramFiles\TightVNC\winvnc.exe",
            "${env:ProgramFiles(x86)}\TightVNC\tvnserver.exe",
            "${env:ProgramFiles(x86)}\TightVNC\winvnc.exe"
        )

    Stop-DesktopServices

    exit 0
}

# ============================================================
# SUPERVISOR MODE
# ============================================================

if ($SupervisorOnly) {

    Write-Log "=============================================="
    Write-Log "DAO SUPERVISOR CHECK"
    Write-Log "=============================================="

    $script:tightVnc = Find-Executable `
        -Names @(
            "tvnserver.exe",
            "winvnc.exe"
        ) `
        -Paths @(
            "$env:ProgramFiles\TightVNC\tvnserver.exe",
            "$env:ProgramFiles\TightVNC\winvnc.exe",
            "${env:ProgramFiles(x86)}\TightVNC\tvnserver.exe",
            "${env:ProgramFiles(x86)}\TightVNC\winvnc.exe"
        )

    $python = Find-Executable `
        -Names @(
            "python.exe",
            "py.exe"
        )

    $websockify = Find-Executable `
        -Names @(
            "websockify.exe",
            "websockify"
        )

    $cloudflared = Find-Executable `
        -Names @(
            "cloudflared.exe"
        ) `
        -Paths @(
            "$env:ProgramFiles\cloudflared\cloudflared.exe",
            "${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe"
        )

    $vncOk = Test-TcpPort -Port $VncPort
    $webOk = Test-TcpPort -Port $WebPort

    Write-Log "VNC TCP 5900: $(if ($vncOk) { 'OK' } else { 'DOWN' })"
    Write-Log "Web TCP 6080: $(if ($webOk) { 'OK' } else { 'DOWN' })"

    # --------------------------------------------------------
    # Restart VNC if needed.
    # --------------------------------------------------------

    if (-not $vncOk -and $script:tightVnc) {

        Write-Log "[WARN] VNC is down. Attempting restart."

        [void](Start-TightVnc `
            -Executable $script:tightVnc)

        $vncOk = Test-TcpPort -Port $VncPort
    }

    # --------------------------------------------------------
    # Restart websockify if needed.
    # --------------------------------------------------------

    if (-not $webOk -and $websockify) {

        Write-Log "[WARN] websockify is down. Attempting restart."

        [void](Start-Websockify `
            -Executable $websockify)

        $webOk = Test-TcpPort -Port $WebPort
    }

    # --------------------------------------------------------
    # Cloudflared:
    #
    # Supervisor does not install anything and does not create
    # a second tunnel if an existing tunnel is alive.
    # --------------------------------------------------------

    $cloudAlive = $false

    try {

        $cloudProcess = Get-Process `
            -Name "cloudflared" `
            -ErrorAction SilentlyContinue

        if ($cloudProcess) {
            $cloudAlive = $true
        }
    }
    catch {
    }

    Write-Log `
        "cloudflared process: $(if ($cloudAlive) { 'RUNNING' } else { 'NOT RUNNING' })"

    if (-not $cloudAlive) {

        if ($cloudflared -and $webOk) {

            Write-Log "[WARN] cloudflared is down. Restarting Quick Tunnel."

            try {

                Start-Process `
                    -FilePath $cloudflared `
                    -ArgumentList @(
                        "tunnel",
                        "--no-autoupdate",
                        "--url",
                        "http://127.0.0.1:$WebPort"
                    ) `
                    -RedirectStandardOutput $CloudLog `
                    -RedirectStandardError $CloudErrLog `
                    -WindowStyle Hidden `
                    | Out-Null
            }
            catch {

                Write-Log `
                    "[WARN] cloudflared restart failed: $($_.Exception.Message)"
            }
        }
    }

    Write-Log "Supervisor check completed."

    exit 0
}

# ============================================================
# STARTUP
# ============================================================

Write-Log "=============================================="
Write-Log "DAO WINDOWS DESKTOP STARTING"
Write-Log "=============================================="

try {

    $os = Get-CimInstance Win32_OperatingSystem

    Write-Log "Windows: $($os.Caption)"
    Write-Log "Version: $($os.Version)"
    Write-Log "Computer: $env:COMPUTERNAME"
}
catch {
    Write-Log "[WARN] Could not read Windows information."
}

# ============================================================
# SECRETS
# ============================================================

if ([string]::IsNullOrWhiteSpace($VncPassword)) {
    $VncPassword = [Environment]::GetEnvironmentVariable(
        "VNC_PASSWORD"
    )
}

if ([string]::IsNullOrWhiteSpace($AnyDeskPassword)) {
    $AnyDeskPassword = [Environment]::GetEnvironmentVariable(
        "ANYDESK_PASSWORD"
    )
}

if ([string]::IsNullOrWhiteSpace($VncPassword)) {
    Write-Log "[WARN] VNC_PASSWORD is missing."
}
else {
    Write-Log "[OK] VNC password received."
}

if ([string]::IsNullOrWhiteSpace($AnyDeskPassword)) {
    Write-Log "[WARN] ANYDESK_PASSWORD is missing."
}
else {
    Write-Log "[OK] AnyDesk password received."
}

# ============================================================
# CLEAN STALE PROCESSES
# ============================================================

Stop-ProcessesByName @(
    "websockify",
    "cloudflared"
)

# ============================================================
# SOFTWARE INSTALLATION
# ============================================================

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue

if ($winget) {

    Write-Log "winget: $($winget.Source)"

    Install-WingetPackage `
        -Id "FileZilla.FileZilla" `
        -DisplayName "FileZilla" `
        -Optional | Out-Null

    Install-WingetPackage `
        -Id "Geany.Geany" `
        -DisplayName "Geany" `
        -Optional | Out-Null

    Install-WingetPackage `
        -Id "GlavSoft.TightVNC" `
        -DisplayName "TightVNC" | Out-Null

    Install-WingetPackage `
        -Id "AnyDeskSoftwareGmbH.AnyDesk" `
        -DisplayName "AnyDesk" `
        -Optional | Out-Null

    Install-WingetPackage `
        -Id "Cloudflare.cloudflared" `
        -DisplayName "Cloudflare cloudflared" | Out-Null
}
else {
    Write-Log "[WARN] winget.exe is unavailable."
}

# ============================================================
# FIND EXECUTABLES
# ============================================================

$filezilla = Find-Executable `
    -Names @("filezilla.exe") `
    -Paths @(
        "$env:ProgramFiles\FileZilla FTP Client\filezilla.exe",
        "${env:ProgramFiles(x86)}\FileZilla FTP Client\filezilla.exe"
    )

$geany = Find-Executable `
    -Names @("geany.exe") `
    -Paths @(
        "$env:ProgramFiles\Geany\bin\geany.exe",
        "$env:ProgramFiles\Geany\geany.exe",
        "${env:ProgramFiles(x86)}\Geany\bin\geany.exe",
        "${env:ProgramFiles(x86)}\Geany\geany.exe"
    )

$script:tightVnc = Find-Executable `
    -Names @(
        "tvnserver.exe",
        "winvnc.exe"
    ) `
    -Paths @(
        "$env:ProgramFiles\TightVNC\tvnserver.exe",
        "$env:ProgramFiles\TightVNC\winvnc.exe",
        "${env:ProgramFiles(x86)}\TightVNC\tvnserver.exe",
        "${env:ProgramFiles(x86)}\TightVNC\winvnc.exe"
    )

$cloudflared = Find-Executable `
    -Names @("cloudflared.exe") `
    -Paths @(
        "$env:ProgramFiles\cloudflared\cloudflared.exe",
        "${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe"
    )

$anydesk = Find-Executable `
    -Names @(
        "AnyDesk.exe",
        "anydesk.exe"
    ) `
    -Paths @(
        "$env:ProgramFiles\AnyDesk\AnyDesk.exe",
        "${env:ProgramFiles(x86)}\AnyDesk\AnyDesk.exe"
    )

Write-Log "FileZilla: $(if ($filezilla) { $filezilla } else { 'NOT FOUND' })"
Write-Log "Geany: $(if ($geany) { $geany } else { 'NOT FOUND' })"
Write-Log "TightVNC: $(if ($script:tightVnc) { $script:tightVnc } else { 'NOT FOUND' })"
Write-Log "cloudflared: $(if ($cloudflared) { $cloudflared } else { 'NOT FOUND' })"
Write-Log "AnyDesk: $(if ($anydesk) { $anydesk } else { 'NOT FOUND' })"

# ============================================================
# NOVNC
# ============================================================

Write-Log "Preparing noVNC..."

if (-not (Test-Path -LiteralPath (Join-Path $NoVncDir "vnc.html"))) {

    $git = Get-Command git.exe -ErrorAction SilentlyContinue

    if ($git) {

        Write-Log "Downloading noVNC..."

        try {

            if (Test-Path -LiteralPath $NoVncDir) {
                Remove-Item `
                    -LiteralPath $NoVncDir `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
            }

            & git clone `
                --depth 1 `
                --branch v1.7.0 `
                "https://github.com/novnc/noVNC.git" `
                $NoVncDir

            if ($LASTEXITCODE -ne 0) {
                throw "git clone failed with exit code $LASTEXITCODE"
            }
        }
        catch {

            Write-Log `
                "[WARN] noVNC git download failed: $($_.Exception.Message)"
        }
    }
    else {

        Write-Log "git unavailable. Using archive download."

        try {

            $zip = Join-Path $Tools "novnc.zip"

            Invoke-WebRequest `
                -Uri "https://github.com/novnc/noVNC/archive/refs/tags/v1.7.0.zip" `
                -OutFile $zip `
                -UseBasicParsing

            Expand-Archive `
                -LiteralPath $zip `
                -DestinationPath $Tools `
                -Force

            $sourceDir = Join-Path $Tools "noVNC-1.7.0"

            if (Test-Path -LiteralPath $sourceDir) {

                if (Test-Path -LiteralPath $NoVncDir) {
                    Remove-Item `
                        -LiteralPath $NoVncDir `
                        -Recurse `
                        -Force `
                        -ErrorAction SilentlyContinue
                }

                Move-Item `
                    -LiteralPath $sourceDir `
                    -Destination $NoVncDir
            }
        }
        catch {

            Write-Log `
                "[WARN] noVNC archive download failed: $($_.Exception.Message)"
        }
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $NoVncDir "vnc.html"))) {
    throw "noVNC vnc.html was not found."
}

Write-Log "[OK] noVNC is ready."

# ============================================================
# PYTHON
# ============================================================

$python = Find-Executable `
    -Names @(
        "python.exe",
        "py.exe"
    )

if (-not $python) {
    throw "Python is required for websockify."
}

Write-Log "Python: $python"

# ============================================================
# WEBSOCKIFY
# ============================================================

try {

    & $python -m pip install `
        --disable-pip-version-check `
        --no-input `
        --upgrade `
        websockify

    if ($LASTEXITCODE -ne 0) {
        throw "pip returned exit code $LASTEXITCODE"
    }
}
catch {

    throw `
        "websockify installation failed: $($_.Exception.Message)"
}

$websockify = Find-Executable `
    -Names @(
        "websockify.exe",
        "websockify"
    )

if (-not $websockify) {

    try {

        $pythonScripts = & $python -c `
            "import sysconfig; print(sysconfig.get_path('scripts'))"

        if ($pythonScripts) {

            $candidate = Join-Path `
                ([string]$pythonScripts).Trim() `
                "websockify.exe"

            if (Test-Path -LiteralPath $candidate) {
                $websockify = $candidate
            }
        }
    }
    catch {
    }
}

if (-not $websockify) {
    throw "websockify.exe could not be located."
}

Write-Log "websockify: $websockify"

# ============================================================
# TIGHTVNC CONFIGURATION
# ============================================================

if ($script:tightVnc) {

    if (-not [string]::IsNullOrWhiteSpace($VncPassword)) {

        Write-Log "Configuring TightVNC..."

        try {

            $regPath = "HKLM:\SOFTWARE\TightVNC\Server"

            New-Item `
                -Path $regPath `
                -Force `
                -ErrorAction Stop |
                Out-Null

            $password8 = $VncPassword

            if ($password8.Length -gt 8) {
                $password8 = $password8.Substring(0, 8)
                Write-Log "[INFO] TightVNC uses only first 8 characters."
            }

            while ($password8.Length -lt 8) {
                $password8 += [char]0
            }

            $key = [byte[]](
                0x17,
                0x52,
                0x6B,
                0x8E,
                0x17,
                0x52,
                0x6B,
                0x8E
            )

            $plain = [System.Text.Encoding]::ASCII.GetBytes($password8)

            $des = [System.Security.Cryptography.DES]::Create()

            try {

                $des.Mode = [System.Security.Cryptography.CipherMode]::ECB
                $des.Padding = [System.Security.Cryptography.PaddingMode]::None
                $des.Key = $key

                $encrypted = $des.CreateEncryptor().TransformFinalBlock(
                    $plain,
                    0,
                    8
                )
            }
            finally {
                $des.Dispose()
            }

            New-ItemProperty `
                -Path $regPath `
                -Name "Password" `
                -PropertyType Binary `
                -Value $encrypted `
                -Force `
                -ErrorAction Stop |
                Out-Null

            New-ItemProperty `
                -Path $regPath `
                -Name "UseVncAuthentication" `
                -PropertyType DWord `
                -Value 1 `
                -Force `
                -ErrorAction Stop |
                Out-Null

            New-ItemProperty `
                -Path $regPath `
                -Name "RfbPort" `
                -PropertyType DWord `
                -Value $VncPort `
                -Force `
                -ErrorAction Stop |
                Out-Null

            New-ItemProperty `
                -Path $regPath `
                -Name "LoopbackOnly" `
                -PropertyType DWord `
                -Value 0 `
                -Force `
                -ErrorAction Stop |
                Out-Null

            Write-Log "[OK] TightVNC configuration written."
        }
        catch {

            Write-Log `
                "[WARN] TightVNC configuration failed: $($_.Exception.Message)"
        }
    }

    try {
        & $script:tightVnc -stop -silent 2>&1 |
            Out-File `
                -FilePath $VncLog `
                -Append `
                -Encoding utf8
    }
    catch {
    }

    Start-Sleep -Seconds 2

    [void](Start-TightVnc `
        -Executable $script:tightVnc)
}
else {
    Write-Log "[WARN] TightVNC executable was not found."
}

# ============================================================
# ANYDESK
# ============================================================

$AnyDeskStatus = "UNAVAILABLE"
$AnyDeskId = ""

if ($anydesk) {

    Write-Log "Starting AnyDesk..."

    try {
        & $anydesk --start 2>&1 |
            Out-File `
                -FilePath $AnyDeskLog `
                -Append `
                -Encoding utf8
    }
    catch {
    }

    Start-Sleep -Seconds 5

    if (-not [string]::IsNullOrWhiteSpace($AnyDeskPassword)) {

        Write-Log "Configuring AnyDesk unattended access..."

        try {

            $psi = [System.Diagnostics.ProcessStartInfo]::new()

            $psi.FileName = $anydesk
            $psi.Arguments = "--set-password"
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true

            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $psi

            [void]$process.Start()

            $process.StandardInput.WriteLine($AnyDeskPassword)
            $process.StandardInput.Close()

            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()

            $process.WaitForExit()

            if ($stdout) {
                Add-Content `
                    -LiteralPath $AnyDeskLog `
                    -Value $stdout
            }

            if ($stderr) {
                Add-Content `
                    -LiteralPath $AnyDeskLog `
                    -Value $stderr
            }

            if ($process.ExitCode -eq 0) {
                Write-Log "[OK] AnyDesk password command completed."
            }
            else {
                Write-Log `
                    "[WARN] AnyDesk password command returned $($process.ExitCode)."
            }
        }
        catch {

            Write-Log `
                "[WARN] AnyDesk password configuration failed: $($_.Exception.Message)"
        }
    }

    try {

        $idOutput = & $anydesk --get-id 2>&1
        $idText = ($idOutput | Out-String)

        if ($idText) {

            $match = [regex]::Match(
                $idText,
                "\b\d{6,12}\b"
            )

            if ($match.Success) {
                $AnyDeskId = $match.Value
            }
        }
    }
    catch {
    }

    if ($AnyDeskId) {

        Set-Content `
            -LiteralPath $AnyDeskIdFile `
            -Value $AnyDeskId `
            -NoNewline `
            -Encoding utf8

        $AnyDeskStatus = "RUNNING"

        Write-Log "[OK] AnyDesk ID detected."
    }
    else {

        $AnyDeskStatus = "ID NOT DETECTED"

        Write-Log "[WARN] AnyDesk ID was not detected."
    }
}
else {
    Write-Log "[WARN] AnyDesk executable unavailable."
}

# ============================================================
# WEBSOCKIFY
# ============================================================

if (-not (Start-Websockify `
    -Executable $websockify)) {

    throw "websockify failed to listen on TCP 6080."
}

# ============================================================
# CLOUDFLARED
# ============================================================

if (-not $cloudflared) {
    throw "cloudflared executable was not found."
}

Write-Log "Starting Cloudflare Quick Tunnel..."

Remove-Item `
    -LiteralPath $TunnelUrlFile `
    -Force `
    -ErrorAction SilentlyContinue

Remove-Item `
    -LiteralPath $NoVncUrlFile `
    -Force `
    -ErrorAction SilentlyContinue

Stop-ProcessesByName @(
    "cloudflared"
)

Start-Sleep -Seconds 2

try {

    $cloudProcess = Start-Process `
        -FilePath $cloudflared `
        -ArgumentList @(
            "tunnel",
            "--no-autoupdate",
            "--url",
            "http://127.0.0.1:$WebPort"
        ) `
        -RedirectStandardOutput $CloudLog `
        -RedirectStandardError $CloudErrLog `
        -PassThru `
        -WindowStyle Hidden
}
catch {

    throw `
        "Could not start cloudflared: $($_.Exception.Message)"
}

# ============================================================
# CLOUD URL POLLING
# ============================================================

$publicBaseUrl = $null
$cloudDeadline = (Get-Date).AddSeconds(120)

while ((Get-Date) -lt $cloudDeadline) {

    try {

        if ($cloudProcess.HasExited) {
            Write-Log `
                "[ERROR] cloudflared exited with code $($cloudProcess.ExitCode)."
            break
        }
    }
    catch {
        break
    }

    $stdout = ""
    $stderr = ""

    try {
        if (Test-Path -LiteralPath $CloudLog) {
            $stdout = [string](Get-Content `
                -LiteralPath $CloudLog `
                -Raw `
                -ErrorAction SilentlyContinue)
        }
    }
    catch {
    }

    try {
        if (Test-Path -LiteralPath $CloudErrLog) {
            $stderr = [string](Get-Content `
                -LiteralPath $CloudErrLog `
                -Raw `
                -ErrorAction SilentlyContinue)
        }
    }
    catch {
    }

    $combined = "$stdout`n$stderr"

    if ($combined) {

        $match = [regex]::Match(
            $combined,
            'https://[a-zA-Z0-9-]+\.trycloudflare\.com'
        )

        if ($match.Success) {

            $publicBaseUrl = $match.Value.Trim()

            if ($publicBaseUrl) {
                break
            }
        }
    }

    Start-Sleep -Seconds 2
}

if ([string]::IsNullOrWhiteSpace($publicBaseUrl)) {

    Write-Host ""
    Write-Host "=============================================="
    Write-Host "CLOUDFLARE QUICK TUNNEL FAILED"
    Write-Host "=============================================="

    Write-Host ""
    Write-Host "TCP 5900: $(Test-TcpPort -Port $VncPort)"
    Write-Host "TCP 6080: $(Test-TcpPort -Port $WebPort)"

    if (Test-Path -LiteralPath $CloudLog) {
        Write-Host ""
        Write-Host "----- cloudflared stdout -----"
        Get-Content `
            -LiteralPath $CloudLog `
            -Tail 100 `
            -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $CloudErrLog) {
        Write-Host ""
        Write-Host "----- cloudflared stderr -----"
        Get-Content `
            -LiteralPath $CloudErrLog `
            -Tail 100 `
            -ErrorAction SilentlyContinue
    }

    throw `
        "Cloudflare Quick Tunnel URL was not detected within 120 seconds."
}

# ============================================================
# SAVE URL
# ============================================================

$publicUrl = "$publicBaseUrl/vnc.html"

Set-Content `
    -LiteralPath $TunnelUrlFile `
    -Value $publicBaseUrl `
    -NoNewline `
    -Encoding utf8

Set-Content `
    -LiteralPath $NoVncUrlFile `
    -Value $publicUrl `
    -NoNewline `
    -Encoding utf8

Write-Log "[OK] Cloudflare URL detected."
Write-Log "noVNC URL: $publicUrl"

# ============================================================
# FINAL STATUS
# ============================================================

$vncListening = Test-TcpPort -Port $VncPort
$webListening = Test-TcpPort -Port $WebPort

$cloudAlive = $false

try {
    $cloudAlive = -not $cloudProcess.HasExited
}
catch {
}

# ============================================================
# CONNECTION DASHBOARD
# ============================================================

$dashboard = @"
==============================================
        DAO WINDOWS DESKTOP
==============================================

Workspace:
$Workspace

Applications:

FileZilla:
$(if ($filezilla) { "OK" } else { "NOT FOUND" })

Geany:
$(if ($geany) { "OK" } else { "NOT FOUND" })

AnyDesk:
$(if ($anydesk) { "OK" } else { "NOT FOUND" })

TightVNC:
$(if ($script:tightVnc) { "OK" } else { "NOT FOUND" })

noVNC:
$(if (Test-Path (Join-Path $NoVncDir "vnc.html")) { "OK" } else { "NOT FOUND" })

Cloudflare:
$(if ($cloudAlive) { "RUNNING" } else { "NOT RUNNING" })

==============================================

AnyDesk:
Status: $AnyDeskStatus
ID: $(if ($AnyDeskId) { $AnyDeskId } else { "NOT DETECTED" })

==============================================

VNC:
Status: $(if ($vncListening) { "RUNNING" } else { "NOT LISTENING" })
TCP: $VncPort

noVNC:
Status: $(if ($webListening) { "RUNNING" } else { "NOT LISTENING" })
TCP: $WebPort

WEB URL:
$publicUrl

==============================================

Runtime:
Controlled by windows-desktop.yml

Passwords:
Not displayed or written to logs.

==============================================
"@

Set-Content `
    -LiteralPath $Connection `
    -Value $dashboard `
    -Encoding utf8

Write-Host ""
Write-Host $dashboard

Write-Log "DAO desktop initialization completed successfully."

exit 0
