[CmdletBinding()]
param(
    [int]$RuntimeMinutes = 225
)

Set-StrictMode -Version Latest

$ErrorActionPreference = "Continue"

# ============================================================
# PATHS
# ============================================================

$Workspace = "D:\DAO-Workspace"
$Logs      = "D:\DAO-Logs"

$VncPort   = 5900
$WebPort   = 6080

$NoVncDir  = "D:\DAO-Workspace\Applications\noVNC"
$ToolsDir  = "D:\DAO-Workspace\Applications"

$TunnelUrlFile = Join-Path $Logs "tunnel-url.txt"
$NoVncUrlFile  = Join-Path $Logs "novnc-url.txt"
$AnyDeskIdFile = Join-Path $Logs "anydesk-id.txt"

$VncLog       = Join-Path $Logs "vnc.log"
$WebLog       = Join-Path $Logs "websockify.log"
$WebErrorLog  = Join-Path $Logs "websockify-error.log"
$CloudLog     = Join-Path $Logs "cloudflared.log"
$CloudErrLog  = Join-Path $Logs "cloudflared-error.log"
$AnyDeskLog   = Join-Path $Logs "anydesk.log"
$Connection   = Join-Path $Logs "connection-info.txt"

New-Item -ItemType Directory -Force -Path $Workspace | Out-Null
New-Item -ItemType Directory -Force -Path $Logs | Out-Null
New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null

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

    if ($File) {
        try {
            Add-Content -LiteralPath $File -Value $line -ErrorAction SilentlyContinue
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

    try {
        $client = [System.Net.Sockets.TcpClient]::new()

        $async = $client.BeginConnect(
            $HostName,
            $Port,
            $null,
            $null
        )

        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $client.Close()
            return $false
        }

        $client.EndConnect($async)
        $client.Close()

        return $true
    }
    catch {
        return $false
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

            $pid = $connection.OwningProcess

            if ($pid -and $pid -ne 0) {

                try {
                    $process = Get-Process `
                        -Id $pid `
                        -ErrorAction SilentlyContinue

                    if ($process) {
                        return "$($process.ProcessName) PID=$pid"
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

                Write-Log "Stopping stale process $name PID=$($process.Id)"

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

        if (Test-Path $path) {
            return $path
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

    $installed = $false

    try {

        $list = & winget list `
            --id $Id `
            --exact `
            --accept-source-agreements `
            2>$null

        if ($LASTEXITCODE -eq 0 -and $list) {
            $installed = $true
        }
    }
    catch {
    }

    if ($installed) {
        Write-Log "[OK] $DisplayName already installed."
        return $true
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

        Write-Log "[WARN] winget returned exit code $LASTEXITCODE for $DisplayName."

        if ($Optional) {
            return $false
        }

        return $false
    }
    catch {

        Write-Log "[WARN] Could not install $DisplayName : $($_.Exception.Message)"

        if ($Optional) {
            return $false
        }

        return $false
    }
}

# ============================================================
# CHECK WINDOWS
# ============================================================

Write-Log "=============================================="
Write-Log "DAO WINDOWS DESKTOP STARTING"
Write-Log "=============================================="

$os = Get-CimInstance Win32_OperatingSystem

Write-Log "Windows: $($os.Caption)"
Write-Log "Version: $($os.Version)"
Write-Log "Computer: $env:COMPUTERNAME"

# ============================================================
# SECRET VALIDATION
# ============================================================

$VncPassword = [Environment]::GetEnvironmentVariable("VNC_PASSWORD")
$AnyDeskPassword = [Environment]::GetEnvironmentVariable("ANYDESK_PASSWORD")

if ([string]::IsNullOrWhiteSpace($VncPassword)) {
    Write-Log "[WARN] VNC_PASSWORD secret is missing. TightVNC cannot be configured."
}

if ([string]::IsNullOrWhiteSpace($AnyDeskPassword)) {
    Write-Log "[WARN] ANYDESK_PASSWORD secret is missing. AnyDesk unattended access will be unavailable."
}

# ============================================================
# CLEAN STALE PROCESSES
# ============================================================

Write-Log "Cleaning stale processes..."

Stop-ProcessesByName @(
    "websockify",
    "python",
    "cloudflared"
)

# AnyDesk is handled carefully and not blindly killed.

# ============================================================
# WINGET
# ============================================================

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue

if (-not $winget) {

    Write-Log "[WARN] winget.exe is not available on this runner."

}
else {

    Write-Log "winget: $($winget.Source)"

    # --------------------------------------------------------
    # FileZilla
    # --------------------------------------------------------

    $filezillaOk = Install-WingetPackage `
        -Id "FileZilla.FileZilla" `
        -DisplayName "FileZilla" `
        -Optional

    # --------------------------------------------------------
    # Geany
    # --------------------------------------------------------

    $geanyOk = Install-WingetPackage `
        -Id "Geany.Geany" `
        -DisplayName "Geany" `
        -Optional

    # --------------------------------------------------------
    # TightVNC
    # --------------------------------------------------------

    $tightOk = Install-WingetPackage `
        -Id "GlavSoft.TightVNC" `
        -DisplayName "TightVNC"

    # --------------------------------------------------------
    # AnyDesk
    # --------------------------------------------------------

    $anydeskOk = Install-WingetPackage `
        -Id "AnyDeskSoftwareGmbH.AnyDesk" `
        -DisplayName "AnyDesk" `
        -Optional

    # --------------------------------------------------------
    # cloudflared
    # --------------------------------------------------------

    $cloudOk = Install-WingetPackage `
        -Id "Cloudflare.cloudflared" `
        -DisplayName "Cloudflare cloudflared"

}

# ============================================================
# FIND APPLICATIONS
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

$tightVnc = Find-Executable `
    -Names @("tvnserver.exe", "winvnc.exe") `
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
        "${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Cloudflare.cloudflared*\cloudflared.exe"
    )

$anydesk = Find-Executable `
    -Names @("AnyDesk.exe", "anydesk.exe") `
    -Paths @(
        "$env:ProgramFiles\AnyDesk\AnyDesk.exe",
        "${env:ProgramFiles(x86)}\AnyDesk\AnyDesk.exe",
        "$env:ProgramFiles\AnyDesk\AnyDesk.exe"
    )

Write-Log "FileZilla: $filezilla"
Write-Log "Geany: $geany"
Write-Log "TightVNC: $tightVnc"
Write-Log "cloudflared: $cloudflared"
Write-Log "AnyDesk: $anydesk"

# ============================================================
# noVNC
# ============================================================

Write-Log "Preparing noVNC..."

New-Item -ItemType Directory -Force -Path $NoVncDir | Out-Null

$NoVncGit = Get-Command git.exe -ErrorAction SilentlyContinue

if ($NoVncGit) {

    if (-not (Test-Path (Join-Path $NoVncDir "vnc.html"))) {

        Write-Log "Downloading noVNC from official GitHub repository..."

        try {

            & git clone `
                --depth 1 `
                --branch v1.7.0 `
                "https://github.com/novnc/noVNC.git" `
                $NoVncDir

            if ($LASTEXITCODE -ne 0) {
                Write-Log "[WARN] noVNC git clone returned $LASTEXITCODE."
            }
        }
        catch {
            Write-Log "[WARN] noVNC download failed: $($_.Exception.Message)"
        }
    }
}
else {

    Write-Log "[WARN] git.exe unavailable. Trying archive download..."

    try {

        $zip = "$ToolsDir\novnc.zip"

        Invoke-WebRequest `
            -Uri "https://github.com/novnc/noVNC/archive/refs/tags/v1.7.0.zip" `
            -OutFile $zip `
            -UseBasicParsing

        if (Test-Path $zip) {

            Expand-Archive `
                -LiteralPath $zip `
                -DestinationPath $ToolsDir `
                -Force

            $extracted = Join-Path $ToolsDir "noVNC-1.7.0"

            if (Test-Path $extracted) {

                if (Test-Path $NoVncDir) {
                    Remove-Item $NoVncDir -Recurse -Force -ErrorAction SilentlyContinue
                }

                Move-Item `
                    -LiteralPath $extracted `
                    -Destination $NoVncDir
            }
        }
    }
    catch {
        Write-Log "[ERROR] noVNC download failed: $($_.Exception.Message)"
    }
}

if (-not (Test-Path (Join-Path $NoVncDir "vnc.html"))) {
    throw "noVNC vnc.html was not found."
}

Write-Log "[OK] noVNC files available."

# ============================================================
# PYTHON / WEBSOCKIFY
# ============================================================

$python = Find-Executable `
    -Names @("python.exe", "py.exe")

if (-not $python) {
    throw "Python is required for websockify but was not found."
}

Write-Log "Python: $python"

Write-Log "Installing/updating websockify..."

try {

    & $python -m pip install `
        --disable-pip-version-check `
        --no-input `
        --upgrade `
        websockify

    if ($LASTEXITCODE -ne 0) {
        throw "pip failed with exit code $LASTEXITCODE"
    }
}
catch {
    throw "websockify installation failed: $($_.Exception.Message)"
}

$websockify = Find-Executable `
    -Names @("websockify.exe", "websockify")

if (-not $websockify) {

    $scriptsPath = Join-Path `
        ([Environment]::GetFolderPath("LocalApplicationData")) `
        "Programs\Python"

    $possible = Get-ChildItem `
        -Path $scriptsPath `
        -Filter "websockify.exe" `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($possible) {
        $websockify = $possible.FullName
    }
}

if (-not $websockify) {
    throw "websockify executable could not be located."
}

Write-Log "websockify: $websockify"

# ============================================================
# TIGHTVNC
# ============================================================

if (-not $tightVnc) {

    Write-Log "[ERROR] TightVNC executable not found."
}
else {

    # --------------------------------------------------------
    # Configure VNC registry.
    #
    # TightVNC 2.8 uses:
    # HKLM\SOFTWARE\TightVNC\Server
    #
    # Password is written only as encrypted VNC registry bytes.
    # The actual secret is never written to logs.
    # --------------------------------------------------------

    if (-not [string]::IsNullOrWhiteSpace($VncPassword)) {

        Write-Log "Configuring TightVNC authentication..."

        try {

            $regPath = "HKLM:\SOFTWARE\TightVNC\Server"

            New-Item `
                -Path $regPath `
                -Force `
                -ErrorAction Stop |
                Out-Null

            # TightVNC uses an 8-byte VNC password.
            $password8 = $VncPassword

            if ($password8.Length -gt 8) {
                $password8 = $password8.Substring(0, 8)
                Write-Log "TightVNC password was longer than 8 characters; TightVNC uses its first 8 characters."
            }

            while ($password8.Length -lt 8) {
                $password8 += [char]0
            }

            # Standard VNC password DES key.
            $key = [byte[]](
                0x17, 0x52, 0x6B, 0x5B,
                0x9C, 0x64, 0x31, 0x87
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
                -Value 5900 `
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

            Write-Log "[OK] TightVNC registry configuration completed."

        }
        catch {

            Write-Log "[WARN] TightVNC registry configuration failed: $($_.Exception.Message)"
        }
    }

    # --------------------------------------------------------
    # Restart/start TightVNC service
    # --------------------------------------------------------

    try {

        & $tightVnc -stop -silent 2>&1 |
            Out-File -FilePath $VncLog -Append

    }
    catch {
    }

    Start-Sleep -Seconds 2

    try {

        & $tightVnc -start -silent 2>&1 |
            Out-File -FilePath $VncLog -Append

    }
    catch {
        Write-Log "[WARN] TightVNC start command failed."
    }

    Start-Sleep -Seconds 3

    if (-not (Test-TcpPort -Port $VncPort)) {

        Write-Log "[WARN] TCP 5900 is not listening."

        try {
            Get-Service |
                Where-Object {
                    $_.Name -match "tvn|tight|vnc"
                } |
                Format-Table -AutoSize |
                Out-String |
                Add-Content $VncLog
        }
        catch {
        }

    }
    else {

        Write-Log "[OK] TightVNC TCP 5900 is listening."
    }
}

# ============================================================
# ANYDESK
# ============================================================

$AnyDeskStatus = "UNAVAILABLE"
$AnyDeskId = ""

if ($anydesk) {

    Write-Log "Starting/configuring AnyDesk..."

    try {

        # Start installed service.
        & $anydesk --start 2>&1 |
            Out-File -FilePath $AnyDeskLog -Append

    }
    catch {
    }

    Start-Sleep -Seconds 5

    # --------------------------------------------------------
    # Configure unattended access.
    #
    # Password is passed over STDIN rather than as a command-line
    # argument, avoiding direct exposure in the process command line.
    # --------------------------------------------------------

    if (-not [string]::IsNullOrWhiteSpace($AnyDeskPassword)) {

        try {

            $psi = [System.Diagnostics.ProcessStartInfo]::new()

            $psi.FileName = $anydesk
            $psi.Arguments = "--set-password _unattended_access"
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true

            $p = [System.Diagnostics.Process]::new()
            $p.StartInfo = $psi

            [void]$p.Start()

            $p.StandardInput.WriteLine($AnyDeskPassword)
            $p.StandardInput.Close()

            $stdout = $p.StandardOutput.ReadToEnd()
            $stderr = $p.StandardError.ReadToEnd()

            $p.WaitForExit()

            if ($stdout) {
                Add-Content -Path $AnyDeskLog -Value $stdout
            }

            if ($stderr) {
                Add-Content -Path $AnyDeskLog -Value $stderr
            }

            if ($p.ExitCode -eq 0) {
                Write-Log "[OK] AnyDesk unattended-access password configured."
            }
            else {
                Write-Log "[WARN] AnyDesk password configuration returned exit code $($p.ExitCode)."
            }

        }
        catch {

            Write-Log "[WARN] AnyDesk password configuration failed: $($_.Exception.Message)"
        }
    }

    # --------------------------------------------------------
    # Get ID
    # --------------------------------------------------------

    try {

        $idOutput = & $anydesk --get-id 2>&1

        $AnyDeskId = (
            $idOutput |
            ForEach-Object {
                "$_"
            } |
            Select-String -Pattern "\d{6,}" -AllMatches |
            ForEach-Object {
                $_.Matches.Value
            } |
            Select-Object -First 1
        )

    }
    catch {
    }

    if ($AnyDeskId) {

        $AnyDeskId = "$AnyDeskId".Trim()

        Set-Content `
            -Path $AnyDeskIdFile `
            -Value $AnyDeskId `
            -NoNewline

        $AnyDeskStatus = "RUNNING"

        Write-Log "[OK] AnyDesk ID detected."

    }
    else {

        $AnyDeskStatus = "ID NOT DETECTED"

        Write-Log "[WARN] AnyDesk ID could not be detected."
    }

}
else {

    Write-Log "[WARN] AnyDesk executable unavailable."
}

# ============================================================
# WEBSOCKIFY
# ============================================================

Write-Log "Starting websockify..."

if (Test-TcpPort -Port $WebPort) {

    $owner = Get-PortOwner -Port $WebPort

    Write-Log "TCP 6080 already occupied by: $owner"

    Stop-ProcessesByName @(
        "websockify"
    )

    Start-Sleep -Seconds 2
}

$webArgs = @(
    "--web",
    $NoVncDir,
    "127.0.0.1:$WebPort",
    "127.0.0.1:$VncPort"
)

try {

    $webProcess = Start-Process `
        -FilePath $websockify `
        -ArgumentList $webArgs `
        -WorkingDirectory $NoVncDir `
        -RedirectStandardOutput $WebLog `
        -RedirectStandardError $WebErrorLog `
        -PassThru `
        -WindowStyle Hidden

}
catch {

    throw "Could not start websockify: $($_.Exception.Message)"
}

if (-not (Wait-ForPort -Port $WebPort -TimeoutSeconds 30)) {

    Write-Log "[ERROR] TCP 6080 did not start."

    if (Test-Path $WebLog) {
        Write-Host "----- websockify stdout -----"
        Get-Content $WebLog -Tail 100
    }

    if (Test-Path $WebErrorLog) {
        Write-Host "----- websockify stderr -----"
        Get-Content $WebErrorLog -Tail 100
    }

    throw "websockify failed to listen on TCP 6080."
}

Write-Log "[OK] websockify TCP 6080 is listening."

# ============================================================
# CLOUDFLARED
# ============================================================

if (-not $cloudflared) {
    throw "cloudflared executable was not found."
}

Write-Log "Starting Cloudflare Quick Tunnel..."

# Remove old URLs.
Remove-Item $TunnelUrlFile -Force -ErrorAction SilentlyContinue
Remove-Item $NoVncUrlFile -Force -ErrorAction SilentlyContinue

# Kill stale cloudflared.
Stop-ProcessesByName @("cloudflared")

Start-Sleep -Seconds 2

$cloudProcess = $null

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

    throw "Could not start cloudflared: $($_.Exception.Message)"
}

# ------------------------------------------------------------
# URL polling
# ------------------------------------------------------------

$publicBaseUrl = $null
$cloudDeadline = (Get-Date).AddSeconds(120)

while ((Get-Date) -lt $cloudDeadline) {

    # --------------------------------------------------------
    # Process check
    # --------------------------------------------------------

    if ($cloudProcess.HasExited) {

        Write-Log "[WARN] cloudflared exited unexpectedly with code $($cloudProcess.ExitCode)."

        # Do NOT call Regex.Match() on a null value.
        $stdoutText = ""
        $stderrText = ""

        try {
            if (Test-Path $CloudLog) {
                $stdoutText = [string](Get-Content -Raw -LiteralPath $CloudLog -ErrorAction SilentlyContinue)
            }
        }
        catch {
            $stdoutText = ""
        }

        try {
            if (Test-Path $CloudErrLog) {
                $stderrText = [string](Get-Content -Raw -LiteralPath $CloudErrLog -ErrorAction SilentlyContinue)
            }
        }
        catch {
            $stderrText = ""
        }

        if ([string]::IsNullOrWhiteSpace($stdoutText)) {
            $stdoutText = ""
        }

        if ([string]::IsNullOrWhiteSpace($stderrText)) {
            $stderrText = ""
        }

        Write-Host "----- cloudflared stdout -----"

        if ($stdoutText.Length -gt 0) {
            Write-Host $stdoutText
        }
        else {
            Write-Host "(empty)"
        }

        Write-Host "----- cloudflared stderr -----"

        if ($stderrText.Length -gt 0) {
            Write-Host $stderrText
        }
        else {
            Write-Host "(empty)"
        }

        Write-Host "----- diagnostics -----"
        Write-Host "Exit code: $($cloudProcess.ExitCode)"
        Write-Host "TCP 6080: $(Test-TcpPort -Port $WebPort)"
        Write-Host "cloudflared alive: $(-not $cloudProcess.HasExited)"

        throw "cloudflared exited before a Quick Tunnel URL was detected."
    }

    # --------------------------------------------------------
    # Safely read stdout/stderr
    # --------------------------------------------------------

    $stdout = ""
    $stderr = ""

    try {

        if (Test-Path $CloudLog) {

            $raw = Get-Content `
                -Raw `
                -LiteralPath $CloudLog `
                -ErrorAction SilentlyContinue

            if ($null -ne $raw) {
                $stdout = [string]$raw
            }
        }
    }
    catch {
        $stdout = ""
    }

    try {

        if (Test-Path $CloudErrLog) {

            $rawErr = Get-Content `
                -Raw `
                -LiteralPath $CloudErrLog `
                -ErrorAction SilentlyContinue

            if ($null -ne $rawErr) {
                $stderr = [string]$rawErr
            }
        }
    }
    catch {
        $stderr = ""
    }

    # --------------------------------------------------------
    # NEVER Regex.Match() with null.
    # --------------------------------------------------------

    if ($null -eq $stdout) {
        $stdout = ""
    }

    if ($null -eq $stderr) {
        $stderr = ""
    }

    $combined = "$stdout`n$stderr"

    if ($null -eq $combined) {
        $combined = ""
    }

    if (-not [string]::IsNullOrWhiteSpace($combined)) {

        try {

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
        catch {

            Write-Log "Cloudflare URL parsing warning: $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 2
}

# ============================================================
# CLOUDFLARE FAILURE
# ============================================================

if ([string]::IsNullOrWhiteSpace($publicBaseUrl)) {

    Write-Host ""
    Write-Host "=============================================="
    Write-Host "CLOUDFLARE QUICK TUNNEL FAILED"
    Write-Host "=============================================="

    Write-Host ""
    Write-Host "TCP 5900 listening: $(Test-TcpPort -Port $VncPort)"
    Write-Host "TCP 6080 listening: $(Test-TcpPort -Port $WebPort)"

    if ($cloudProcess) {

        $alive = $false

        try {
            $alive = -not $cloudProcess.HasExited
        }
        catch {
        }

        Write-Host "cloudflared process alive: $alive"

        if ($cloudProcess.HasExited) {
            Write-Host "cloudflared exit code: $($cloudProcess.ExitCode)"
        }
    }

    Write-Host ""
    Write-Host "----- cloudflared stdout -----"

    if (Test-Path $CloudLog) {

        $stdoutFinal = ""

        try {
            $stdoutFinal = [string](Get-Content -Raw -LiteralPath $CloudLog -ErrorAction SilentlyContinue)
        }
        catch {
            $stdoutFinal = ""
        }

        if ([string]::IsNullOrWhiteSpace($stdoutFinal)) {
            Write-Host "(empty)"
        }
        else {
            Write-Host $stdoutFinal
        }
    }
    else {
        Write-Host "(file not found)"
    }

    Write-Host ""
    Write-Host "----- cloudflared stderr -----"

    if (Test-Path $CloudErrLog) {

        $stderrFinal = ""

        try {
            $stderrFinal = [string](Get-Content -Raw -LiteralPath $CloudErrLog -ErrorAction SilentlyContinue)
        }
        catch {
            $stderrFinal = ""
        }

        if ([string]::IsNullOrWhiteSpace($stderrFinal)) {
            Write-Host "(empty)"
        }
        else {
            Write-Host $stderrFinal
        }
    }
    else {
        Write-Host "(file not found)"
    }

    throw "Cloudflare Quick Tunnel URL was not detected within 120 seconds."
}

# ============================================================
# SAVE URL
# ============================================================

$publicUrl = "$publicBaseUrl/vnc.html"

Set-Content `
    -LiteralPath $TunnelUrlFile `
    -Value $publicBaseUrl `
    -NoNewline

Set-Content `
    -LiteralPath $NoVncUrlFile `
    -Value $publicUrl `
    -NoNewline

Write-Log "[OK] Cloudflare Quick Tunnel URL detected."
Write-Log "Base URL: $publicBaseUrl"
Write-Log "noVNC URL: $publicUrl"

# ============================================================
# FINAL SERVICE VERIFICATION
# ============================================================

$vncListening = Test-TcpPort -Port $VncPort
$webListening = Test-TcpPort -Port $WebPort

if (-not $vncListening) {
    Write-Log "[WARN] TightVNC is not currently listening on TCP 5900."
}

if (-not $webListening) {
    throw "noVNC/websockify is no longer listening on TCP 6080."
}

$cloudAlive = $false

try {
    $cloudAlive = -not $cloudProcess.HasExited
}
catch {
}

# ============================================================
# CONNECTION INFO
# ============================================================

$dashboard = @"
==============================================
        DAO WINDOWS DESKTOP
==============================================

Windows:
$($os.Caption)

Applications:
FileZilla: $(if ($filezilla) {"OK"} else {"NOT FOUND"})
Geany: $(if ($geany) {"OK"} else {"NOT FOUND"})
AnyDesk: $(if ($anydesk) {"OK"} else {"NOT FOUND"})
TightVNC: $(if ($tightVnc) {"OK"} else {"NOT FOUND"})
noVNC: $(if (Test-Path (Join-Path $NoVncDir "vnc.html")) {"OK"} else {"NOT FOUND"})
Cloudflare Tunnel: $(if ($cloudAlive) {"OK"} else {"NOT RUNNING"})

==============================================

Workspace:
$Workspace

==============================================

AnyDesk:
Status: $AnyDeskStatus
ID: $(if ($AnyDeskId) {$AnyDeskId} else {"NOT DETECTED"})

==============================================

VNC:
Status: $(if ($vncListening) {"RUNNING"} else {"NOT LISTENING"})
TCP: $VncPort

noVNC:
Status: $(if ($webListening) {"RUNNING"} else {"NOT LISTENING"})
TCP: $WebPort

WEB URL:
$publicUrl

==============================================

Backup:
Will be created at workflow shutdown.

Restore:
Completed by restore.ps1 before desktop startup.

Runtime:
$RuntimeMinutes minutes active runtime
240 minutes workflow maximum

==============================================

IMPORTANT:
Do not display the actual passwords.
==============================================
"@

Set-Content `
    -LiteralPath $Connection `
    -Value $dashboard

Write-Host ""
Write-Host $dashboard

# ============================================================
# KEEP ALIVE / SUPERVISOR
# ============================================================

Write-Log "DAO desktop is now active."

$startTime = Get-Date
$endTime = $startTime.AddMinutes($RuntimeMinutes)

$vncRestartCount = 0
$webRestartCount = 0
$cloudRestartCount = 0
$anyDeskRestartCount = 0

while ((Get-Date) -lt $endTime) {

    $elapsed = (Get-Date) - $startTime

    $elapsedText = "{0:00}:{1:00}:{2:00}" -f `
        [int]$elapsed.TotalHours,
        $elapsed.Minutes,
        $elapsed.Seconds

    $total = [TimeSpan]::FromMinutes($RuntimeMinutes)

    $remaining = $endTime - (Get-Date)

    if ($remaining.TotalSeconds -lt 0) {
        $remaining = [TimeSpan]::Zero
    }

    $remainingText = "{0:00}:{1:00}:{2:00}" -f `
        [int]$remaining.TotalHours,
        $remaining.Minutes,
        $remaining.Seconds

    Write-Host ""
    Write-Host "DAO Desktop active"
    Write-Host "Runtime: $elapsedText / $($total.Hours.ToString('00')):$($total.Minutes.ToString('00')):00"
    Write-Host "Remaining: $remainingText"

    # --------------------------------------------------------
    # TightVNC supervisor
    # --------------------------------------------------------

    if (-not (Test-TcpPort -Port $VncPort)) {

        if ($vncRestartCount -lt 3 -and $tightVnc) {

            $vncRestartCount++

            Write-Log "TightVNC appears down. Restart attempt $vncRestartCount/3."

            try {
                & $tightVnc -stop -silent 2>&1 |
                    Out-File -FilePath $VncLog -Append
            }
            catch {
            }

            Start-Sleep -Seconds 2

            try {
                & $tightVnc -start -silent 2>&1 |
                    Out-File -FilePath $VncLog -Append
            }
            catch {
            }

            Start-Sleep -Seconds 3

        }
        else {

            Write-Log "TightVNC restart limit reached."
        }
    }

    # --------------------------------------------------------
    # websockify supervisor
    # --------------------------------------------------------

    if (-not (Test-TcpPort -Port $WebPort)) {

        if ($webRestartCount -lt 3) {

            $webRestartCount++

            Write-Log "websockify appears down. Restart attempt $webRestartCount/3."

            Stop-ProcessesByName @("websockify")

            Start-Sleep -Seconds 2

            try {

                $webProcess = Start-Process `
                    -FilePath $websockify `
                    -ArgumentList $webArgs `
                    -WorkingDirectory $NoVncDir `
                    -RedirectStandardOutput $WebLog `
                    -RedirectStandardError $WebErrorLog `
                    -PassThru `
                    -WindowStyle Hidden

            }
            catch {
                Write-Log "websockify restart failed."
            }
        }
        else {

            Write-Log "websockify restart limit reached."
        }
    }

    # --------------------------------------------------------
    # Cloudflare supervisor
    # --------------------------------------------------------

    $cloudAliveNow = $false

    try {
        $cloudAliveNow = -not $cloudProcess.HasExited
    }
    catch {
        $cloudAliveNow = $false
    }

    if (-not $cloudAliveNow) {

        if ($cloudRestartCount -lt 2) {

            $cloudRestartCount++

            Write-Log "cloudflared appears down. Restart attempt $cloudRestartCount/2."

            Stop-ProcessesByName @("cloudflared")

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

                Write-Log "cloudflared restart failed."
            }

        }
        else {

            Write-Log "cloudflared restart limit reached."
        }
    }

    # --------------------------------------------------------
    # AnyDesk supervisor
    # --------------------------------------------------------

    if ($anydesk) {

        try {

            $anydeskProcesses = Get-Process `
                -Name "AnyDesk" `
                -ErrorAction SilentlyContinue

            if (-not $anydeskProcesses) {

                if ($anyDeskRestartCount -lt 2) {

                    $anyDeskRestartCount++

                    Write-Log "AnyDesk process not detected. Restart attempt $anyDeskRestartCount/2."

                    try {
                        & $anydesk --start 2>&1 |
                            Out-File -FilePath $AnyDeskLog -Append
                    }
                    catch {
                    }
                }
            }

        }
        catch {
        }
    }

    # --------------------------------------------------------
    # Update connection info
    # --------------------------------------------------------

    $vncNow = Test-TcpPort -Port $VncPort
    $webNow = Test-TcpPort -Port $WebPort

    $status = @"
==============================================
        DAO WINDOWS DESKTOP
==============================================

Workspace:
$Workspace

AnyDesk:
Status: $AnyDeskStatus
ID: $(if ($AnyDeskId) {$AnyDeskId} else {"NOT DETECTED"})

VNC:
Status: $(if ($vncNow) {"RUNNING"} else {"DOWN"})
TCP: 5900

noVNC:
Status: $(if ($webNow) {"RUNNING"} else {"DOWN"})
TCP: 6080

WEB URL:
$publicUrl

Runtime:
$elapsedText / $($total.Hours.ToString('00')):$($total.Minutes.ToString('00')):00

Remaining:
$remainingText

==============================================
"@

    try {
        Set-Content -LiteralPath $Connection -Value $status
    }
    catch {
    }

    Start-Sleep -Seconds 30
}

# ============================================================
# SHUTDOWN
# ============================================================

Write-Log "Runtime limit reached."
Write-Log "Stopping remote-access services before backup."

# Stop Cloudflare.
Stop-ProcessesByName @(
    "cloudflared"
)

# Stop websockify.
Stop-ProcessesByName @(
    "websockify"
)

Write-Log "Remote-access processes stopped."
Write-Log "desktop.ps1 completed normally."
