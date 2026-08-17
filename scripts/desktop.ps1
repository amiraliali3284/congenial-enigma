[CmdletBinding()]
param(
    [switch]$RuntimeOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$Workspace = "D:\DAO-Workspace"
$Logs      = "D:\DAO-Logs"
$Tools     = "D:\DAO-Tools"

$VncPort   = 5900
$NoVncPort = 6080

$NoVncVersion     = "1.7.0"
$WebsockifyVersion = "0.13.0"

$NoVncRoot = Join-Path $Tools "noVNC"

$DesktopLog = Join-Path $Logs "desktop.log"

New-Item -ItemType Directory -Path $Workspace -Force | Out-Null
New-Item -ItemType Directory -Path $Logs -Force | Out-Null
New-Item -ItemType Directory -Path $Tools -Force | Out-Null


# ==============================================================
# LOGGING
# ==============================================================

function Write-DaoLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )

    $line = "[{0}] [{1}] {2}" -f `
        (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), `
        $Level, `
        $Message

    Add-Content `
        -LiteralPath $DesktopLog `
        -Value $line `
        -Encoding UTF8

    switch ($Level) {
        "ERROR" {
            Write-Host "[ERROR] $Message"
        }

        "WARN" {
            Write-Host "[WARN]  $Message"
        }

        default {
            Write-Host "[INFO]  $Message"
        }
    }
}


# ==============================================================
# SAFE FILE READ
# ==============================================================

function Read-SafeText {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    try {
        $content = Get-Content `
            -LiteralPath $Path `
            -Raw `
            -ErrorAction SilentlyContinue

        if ($null -eq $content) {
            return ""
        }

        return [string]$content
    }
    catch {
        return ""
    }
}


# ==============================================================
# PORT CHECK
# ==============================================================

function Test-PortListening {
    param(
        [Parameter(Mandatory)]
        [int]$Port,

        [string]$Address = "127.0.0.1"
    )

    try {
        $result = Test-NetConnection `
            -ComputerName $Address `
            -Port $Port `
            -InformationLevel Quiet `
            -WarningAction SilentlyContinue `
            -ErrorAction SilentlyContinue

        return [bool]$result
    }
    catch {
        return $false
    }
}


function Wait-Port {
    param(
        [Parameter(Mandatory)]
        [int]$Port,

        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {

        if (Test-PortListening -Port $Port) {
            return $true
        }

        Start-Sleep -Seconds 1
    }

    return $false
}


# ==============================================================
# PORT OWNER
# ==============================================================

function Get-PortOwner {
    param(
        [Parameter(Mandatory)]
        [int]$Port
    )

    try {
        $connection = Get-NetTCPConnection `
            -LocalPort $Port `
            -State Listen `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($null -eq $connection) {
            return $null
        }

        return Get-Process `
            -Id $connection.OwningProcess `
            -ErrorAction SilentlyContinue
    }
    catch {
        return $null
    }
}


# ==============================================================
# PROCESS CLEANUP
# ==============================================================

function Stop-ProcessSafe {
    param(
        [string]$Name
    )

    try {
        $processes = Get-Process `
            -Name $Name `
            -ErrorAction SilentlyContinue

        foreach ($process in $processes) {
            Write-DaoLog `
                "Stopping stale $Name process PID $($process.Id)." `
                "WARN"

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


function Clear-PortIfSafe {
    param(
        [int]$Port,

        [string[]]$AllowedProcessNames
    )

    $owner = Get-PortOwner -Port $Port

    if ($null -eq $owner) {
        return $true
    }

    Write-DaoLog `
        "Port $Port is occupied by PID $($owner.Id) ($($owner.ProcessName))." `
        "WARN"

    $name = $owner.ProcessName.ToLowerInvariant()

    $allowed = $AllowedProcessNames |
        ForEach-Object { $_.ToLowerInvariant() }

    if ($allowed -contains $name) {
        Write-DaoLog `
            "Existing process appears to be an expected service." `
            "INFO"

        return $true
    }

    Write-DaoLog `
        "Port owner is not an expected DAO process. It will not be killed automatically." `
        "WARN"

    return $false
}


# ==============================================================
# EXECUTABLE DETECTION
# ==============================================================

function Find-Executable {
    param(
        [Parameter(Mandatory)]
        [string[]]$Names
    )

    foreach ($name in $Names) {

        try {
            $command = Get-Command `
                $name `
                -ErrorAction SilentlyContinue

            if ($null -ne $command) {

                if (-not [string]::IsNullOrWhiteSpace($command.Source)) {
                    return $command.Source
                }

                if (-not [string]::IsNullOrWhiteSpace($command.Path)) {
                    return $command.Path
                }
            }
        }
        catch {
        }
    }

    $roots = @(
        "C:\Program Files",
        "C:\Program Files (x86)",
        "C:\ProgramData\chocolatey\bin",
        "C:\tools"
    )

    foreach ($root in $roots) {

        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        foreach ($name in $Names) {

            try {
                $found = Get-ChildItem `
                    -LiteralPath $root `
                    -Filter $name `
                    -File `
                    -Recurse `
                    -ErrorAction SilentlyContinue |
                    Select-Object -First 1

                if ($null -ne $found) {
                    return $found.FullName
                }
            }
            catch {
            }
        }
    }

    return $null
}


# ==============================================================
# CHOCOLATEY
# ==============================================================

function Install-ChocoPackage {
    param(
        [Parameter(Mandatory)]
        [string]$Package,

        [Parameter(Mandatory)]
        [scriptblock]$Detector
    )

    try {
        $existing = & $Detector

        if (-not [string]::IsNullOrWhiteSpace([string]$existing)) {
            Write-DaoLog "$Package already installed: $existing"
            return $true
        }
    }
    catch {
    }

    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-DaoLog `
            "Chocolatey is not available; cannot install $Package." `
            "ERROR"

        return $false
    }

    Write-DaoLog "Installing $Package."

    try {
        & choco install $Package `
            -y `
            --no-progress `
            --limit-output

        $code = $LASTEXITCODE

        if ($code -ne 0) {
            Write-DaoLog `
                "$Package installation returned exit code $code." `
                "ERROR"

            return $false
        }

        Start-Sleep -Seconds 2

        $existing = & $Detector

        if (-not [string]::IsNullOrWhiteSpace([string]$existing)) {
            Write-DaoLog "$Package installation verified."
            return $true
        }

        Write-DaoLog `
            "$Package installed but could not be detected afterward." `
            "ERROR"

        return $false
    }
    catch {
        Write-DaoLog `
            "Exception installing $Package: $($_.Exception.Message)" `
            "ERROR"

        return $false
    }
}


# ==============================================================
# NO-VNC
# ==============================================================

function Install-NoVnc {

    $vncHtml = Join-Path $NoVncRoot "vnc.html"

    if (Test-Path -LiteralPath $vncHtml) {
        Write-DaoLog "noVNC is already installed."
        return $true
    }

    $zip = Join-Path `
        $Tools `
        "noVNC-$NoVncVersion.zip"

    $extract = Join-Path `
        $Tools `
        "noVNC-extract"

    try {

        Write-DaoLog `
            "Downloading noVNC $NoVncVersion."

        Invoke-WebRequest `
            -Uri "https://github.com/novnc/noVNC/archive/refs/tags/v$NoVncVersion.zip" `
            -OutFile $zip `
            -UseBasicParsing `
            -ErrorAction Stop

        if (Test-Path -LiteralPath $extract) {
            Remove-Item `
                -LiteralPath $extract `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }

        New-Item `
            -ItemType Directory `
            -Path $extract `
            -Force | Out-Null

        Expand-Archive `
            -LiteralPath $zip `
            -DestinationPath $extract `
            -Force `
            -ErrorAction Stop

        $source = Get-ChildItem `
            -LiteralPath $extract `
            -Directory `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($null -eq $source) {
            throw "Could not locate extracted noVNC directory."
        }

        if (Test-Path -LiteralPath $NoVncRoot) {
            Remove-Item `
                -LiteralPath $NoVncRoot `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }

        Move-Item `
            -LiteralPath $source.FullName `
            -Destination $NoVncRoot `
            -Force

        Remove-Item `
            -LiteralPath $zip `
            -Force `
            -ErrorAction SilentlyContinue

        Remove-Item `
            -LiteralPath $extract `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

        if (-not (Test-Path -LiteralPath $vncHtml)) {
            throw "vnc.html was not found."
        }

        Write-DaoLog "noVNC installation verified."

        return $true
    }
    catch {

        Write-DaoLog `
            "noVNC installation failed: $($_.Exception.Message)" `
            "ERROR"

        return $false
    }
}


# ==============================================================
# WEBSOCKIFY
# ==============================================================

function Install-Websockify {

    try {

        $python = Get-Command `
            python `
            -ErrorAction SilentlyContinue

        if ($null -eq $python) {
            Write-DaoLog `
                "Python is unavailable." `
                "ERROR"

            return $false
        }

        $script:PythonExe = $python.Source

        $installed = & $script:PythonExe `
            -m pip show websockify `
            2>$null

        if ($installed) {

            $versionLine = $installed |
                Where-Object { $_ -match "^Version:" } |
                Select-Object -First 1

            if ($versionLine -match [regex]::Escape($WebsockifyVersion)) {
                Write-DaoLog `
                    "websockify $WebsockifyVersion is already installed."

                return $true
            }
        }

        Write-DaoLog `
            "Installing websockify $WebsockifyVersion."

        & $script:PythonExe `
            -m pip install `
            --disable-pip-version-check `
            --no-input `
            "websockify==$WebsockifyVersion"

        if ($LASTEXITCODE -ne 0) {

            Write-DaoLog `
                "websockify installation failed." `
                "ERROR"

            return $false
        }

        & $script:PythonExe `
            -m websockify `
            --help `
            > $null `
            2>&1

        if ($LASTEXITCODE -ne 0) {

            Write-DaoLog `
                "websockify verification failed." `
                "ERROR"

            return $false
        }

        Write-DaoLog "websockify verified."

        return $true
    }
    catch {

        Write-DaoLog `
            "websockify exception: $($_.Exception.Message)" `
            "ERROR"

        return $false
    }
}


# ==============================================================
# LOGGED PROCESS
# ==============================================================

function Start-LoggedProcess {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$StdOut,

        [Parameter(Mandatory)]
        [string]$StdErr,

        [string]$WorkingDirectory
    )

    $parentOut = Split-Path -Parent $StdOut
    $parentErr = Split-Path -Parent $StdErr

    New-Item `
        -ItemType Directory `
        -Path $parentOut `
        -Force | Out-Null

    New-Item `
        -ItemType Directory `
        -Path $parentErr `
        -Force | Out-Null

    Remove-Item `
        -LiteralPath $StdOut `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        -LiteralPath $StdErr `
        -Force `
        -ErrorAction SilentlyContinue

    $params = @{
        FilePath               = $FilePath
        ArgumentList           = $Arguments
        RedirectStandardOutput = $StdOut
        RedirectStandardError  = $StdErr
        WindowStyle            = "Hidden"
        PassThru                = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $params.WorkingDirectory = $WorkingDirectory
    }

    return Start-Process @params
}


# ==============================================================
# TIGHTVNC
# ==============================================================

function Get-TightVncService {

    try {
        return Get-Service `
            -Name "tvnserver" `
            -ErrorAction SilentlyContinue
    }
    catch {
        return $null
    }
}


function Start-TightVnc {

    if ([string]::IsNullOrWhiteSpace($env:VNC_PASSWORD)) {

        Write-DaoLog `
            "VNC_PASSWORD secret is missing." `
            "ERROR"

        return $false
    }

    $service = Get-TightVncService

    if ($null -eq $service) {

        Write-DaoLog `
            "TightVNC service was not found." `
            "ERROR"

        return $false
    }

    try {

        Stop-Service `
            -Name "tvnserver" `
            -Force `
            -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 2

        Start-Service `
            -Name "tvnserver" `
            -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 3

        if (-not (Wait-Port -Port $VncPort -TimeoutSeconds 30)) {

            Write-DaoLog `
                "TightVNC is not listening on TCP $VncPort." `
                "ERROR"

            $owner = Get-PortOwner -Port $VncPort

            if ($null -ne $owner) {
                Write-DaoLog `
                    "TCP $VncPort owner: PID $($owner.Id), $($owner.ProcessName)." `
                    "ERROR"
            }

            return $false
        }

        Write-DaoLog `
            "TightVNC is listening on TCP $VncPort."

        return $true
    }
    catch {

        Write-DaoLog `
            "TightVNC startup exception: $($_.Exception.Message)" `
            "ERROR"

        return $false
    }
}


# ==============================================================
# ANYDESK
# ==============================================================

function Configure-AnyDesk {

    $idFile = Join-Path $Logs "anydesk-id.txt"
    $anydeskLog = Join-Path $Logs "anydesk.log"

    $exe = Find-Executable `
        -Names @("AnyDesk.exe")

    if ([string]::IsNullOrWhiteSpace($exe)) {

        Write-DaoLog `
            "AnyDesk executable not found." `
            "WARN"

        Set-Content `
            -LiteralPath $idFile `
            -Value "Unavailable" `
            -Encoding UTF8

        return $false
    }

    try {

        # Start AnyDesk.
        & $exe --start `
            >> $anydeskLog `
            2>&1

        Start-Sleep -Seconds 5

        if (-not [string]::IsNullOrWhiteSpace($env:ANYDESK_PASSWORD)) {

            Write-DaoLog `
                "Configuring AnyDesk unattended access."

            $psi = New-Object `
                System.Diagnostics.ProcessStartInfo

            $psi.FileName = $exe
            $psi.Arguments = "--set-password _unattended_access"
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true

            $process = New-Object `
                System.Diagnostics.Process

            $process.StartInfo = $psi

            [void]$process.Start()

            # Secret goes to stdin.
            # It is never written to a log.
            $process.StandardInput.WriteLine(
                $env:ANYDESK_PASSWORD
            )

            $process.StandardInput.Close()

            $null = $process.StandardOutput.ReadToEnd()
            $null = $process.StandardError.ReadToEnd()

            $process.WaitForExit()

            if ($process.ExitCode -ne 0) {

                Write-DaoLog `
                    "AnyDesk password configuration returned exit code $($process.ExitCode)." `
                    "WARN"
            }
        }
        else {

            Write-DaoLog `
                "ANYDESK_PASSWORD is missing; unattended access not configured." `
                "WARN"
        }

        $idOutput = & $exe --get-id 2>$null | Out-String

        if ($null -eq $idOutput) {
            $idOutput = ""
        }

        $id = (
            $idOutput -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match "^\d{6,20}$" } |
            Select-Object -First 1
        )

        if ([string]::IsNullOrWhiteSpace($id)) {

            Write-DaoLog `
                "AnyDesk ID could not be retrieved." `
                "WARN"

            Set-Content `
                -LiteralPath $idFile `
                -Value "Unavailable" `
                -Encoding UTF8

            return $false
        }

        Set-Content `
            -LiteralPath $idFile `
            -Value $id `
            -Encoding UTF8

        $status = & $exe --get-status 2>$null | Out-String

        if ($null -eq $status) {
            $status = ""
        }

        $status = $status.Trim()

        Add-Content `
            -LiteralPath $anydeskLog `
            -Value (
                "[{0}] AnyDesk status: {1}" -f `
                (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), `
                $status
            ) `
            -Encoding UTF8

        Write-DaoLog "AnyDesk ID: $id"
        Write-DaoLog "AnyDesk status: $status"

        return $true
    }
    catch {

        Write-DaoLog `
            "AnyDesk configuration failed: $($_.Exception.Message)" `
            "WARN"

        Set-Content `
            -LiteralPath $idFile `
            -Value "Unavailable" `
            -Encoding UTF8

        return $false
    }
}


# ==============================================================
# CLOUDFLARE URL PARSER
# ==============================================================

function Find-CloudflareUrl {
    param(
        [string]$StdOutPath,

        [string]$StdErrPath
    )

    $stdout = Read-SafeText -Path $StdOutPath
    $stderr = Read-SafeText -Path $StdErrPath

    # ----------------------------------------------------------
    # IMPORTANT:
    # Never allow null to reach Regex.Match().
    # ----------------------------------------------------------

    if ($null -eq $stdout) {
        $stdout = ""
    }

    if ($null -eq $stderr) {
        $stderr = ""
    }

    $combined = [string]::Concat(
        [string]$stdout,
        "`r`n",
        [string]$stderr
    )

    if ($null -eq $combined) {
        $combined = ""
    }

    try {

        $pattern = "https://[a-zA-Z0-9-]+\.trycloudflare\.com"

        $match = [regex]::Match(
            $combined,
            $pattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if (
            $match.Success -and
            -not [string]::IsNullOrWhiteSpace($match.Value)
        ) {
            return $match.Value.TrimEnd("/")
        }
    }
    catch {

        Write-DaoLog `
            "Cloudflare regex processing failed: $($_.Exception.Message)" `
            "WARN"
    }

    return $null
}


# ==============================================================
# CLOUDFLARE
# ==============================================================

function Start-Cloudflare {

    $exe = Find-Executable `
        -Names @("cloudflared.exe")

    if ([string]::IsNullOrWhiteSpace($exe)) {

        Write-DaoLog `
            "cloudflared.exe was not found." `
            "WARN"

        return $null
    }

    if (-not (Test-PortListening -Port $NoVncPort)) {

        Write-DaoLog `
            "Refusing to start Cloudflare because TCP $NoVncPort is not listening." `
            "ERROR"

        return $null
    }

    Stop-ProcessSafe -Name "cloudflared"

    $stdout = Join-Path `
        $Logs `
        "cloudflared.log"

    $stderr = Join-Path `
        $Logs `
        "cloudflared-error.log"

    $tunnelFile = Join-Path `
        $Logs `
        "tunnel-url.txt"

    $novncFile = Join-Path `
        $Logs `
        "novnc-url.txt"

    Remove-Item `
        -LiteralPath $tunnelFile `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        -LiteralPath $novncFile `
        -Force `
        -ErrorAction SilentlyContinue

    Write-DaoLog `
        "Starting Cloudflare Quick Tunnel -> http://127.0.0.1:$NoVncPort"

    try {

        $process = Start-LoggedProcess `
            -FilePath $exe `
            -Arguments @(
                "tunnel",
                "--url",
                "http://127.0.0.1:$NoVncPort",
                "--no-autoupdate"
            ) `
            -StdOut $stdout `
            -StdErr $stderr `
            -WorkingDirectory $Tools

        $deadline = (Get-Date).AddSeconds(120)

        $url = $null

        while ((Get-Date) -lt $deadline) {

            Start-Sleep -Seconds 2

            # --------------------------------------------------
            # Check process
            # --------------------------------------------------

            $exited = $false

            try {
                $exited = $process.HasExited
            }
            catch {
                $exited = $true
            }

            if ($exited) {

                Write-DaoLog `
                    "cloudflared exited during startup." `
                    "ERROR"

                try {
                    Write-DaoLog `
                        "cloudflared exit code: $($process.ExitCode)" `
                        "ERROR"
                }
                catch {
                }

                break
            }

            # --------------------------------------------------
            # Read BOTH streams safely.
            # --------------------------------------------------

            $url = Find-CloudflareUrl `
                -StdOutPath $stdout `
                -StdErrPath $stderr

            if (-not [string]::IsNullOrWhiteSpace($url)) {
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($url)) {

            Write-DaoLog `
                "Cloudflare URL was not detected after 120 seconds." `
                "ERROR"

            Write-DaoLog `
                "TCP 6080 listening: $(Test-PortListening -Port $NoVncPort)" `
                "ERROR"

            $alive = $false

            try {
                $alive = -not $process.HasExited
            }
            catch {
            }

            Write-DaoLog `
                "cloudflared process alive: $alive" `
                "ERROR"

            try {
                if ($process.HasExited) {
                    Write-DaoLog `
                        "cloudflared exit code: $($process.ExitCode)" `
                        "ERROR"
                }
            }
            catch {
            }

            $safeStdout = Read-SafeText -Path $stdout
            $safeStderr = Read-SafeText -Path $stderr

            if ([string]::IsNullOrWhiteSpace($safeStdout)) {

                Write-DaoLog `
                    "cloudflared stdout is empty." `
                    "WARN"
            }
            else {

                Write-DaoLog `
                    "cloudflared stdout:`n$safeStdout" `
                    "ERROR"
            }

            if ([string]::IsNullOrWhiteSpace($safeStderr)) {

                Write-DaoLog `
                    "cloudflared stderr is empty." `
                    "WARN"
            }
            else {

                Write-DaoLog `
                    "cloudflared stderr:`n$safeStderr" `
                    "ERROR"
            }

            return $null
        }

        $url = $url.TrimEnd("/")

        $browserUrl = "$url/vnc.html"

        Set-Content `
            -LiteralPath $tunnelFile `
            -Value $url `
            -Encoding UTF8

        Set-Content `
            -LiteralPath $novncFile `
            -Value $browserUrl `
            -Encoding UTF8

        Write-DaoLog `
            "Cloudflare URL: $url"

        Write-DaoLog `
            "noVNC URL: $browserUrl"

        return $process
    }
    catch {

        Write-DaoLog `
            "Cloudflare startup exception: $($_.Exception.Message)" `
            "ERROR"

        return $null
    }
}


# ==============================================================
# WEBSOCKIFY
# ==============================================================

function Start-Websockify {

    if (-not (Test-PortListening -Port $VncPort)) {

        Write-DaoLog `
            "Cannot start websockify because VNC TCP $VncPort is not listening." `
            "ERROR"

        return $null
    }

    if (-not (Test-Path -LiteralPath (Join-Path $NoVncRoot "vnc.html"))) {

        Write-DaoLog `
            "Cannot start websockify because noVNC is missing." `
            "ERROR"

        return $null
    }

    if (-not $script:PythonExe) {

        Write-DaoLog `
            "Python executable is unavailable." `
            "ERROR"

        return $null
    }

    # ----------------------------------------------------------
    # Existing listener
    # ----------------------------------------------------------

    if (Test-PortListening -Port $NoVncPort) {

        $owner = Get-PortOwner -Port $NoVncPort

        if ($null -ne $owner) {

            Write-DaoLog `
                "TCP $NoVncPort already belongs to PID $($owner.Id) ($($owner.ProcessName))."

            # Do not kill an unknown process.
            if (
                $owner.ProcessName -notmatch "^python" -and
                $owner.ProcessName -ne "websockify"
            ) {

                Write-DaoLog `
                    "TCP $NoVncPort is owned by an unexpected process." `
                    "ERROR"

                return $null
            }

            # Existing expected process can be reused.
            return $owner
        }
    }

    $stdout = Join-Path `
        $Logs `
        "websockify.log"

    $stderr = Join-Path `
        $Logs `
        "websockify-error.log"

    Write-DaoLog `
        "Starting websockify 127.0.0.1:$NoVncPort -> 127.0.0.1:$VncPort."

    try {

        $process = Start-LoggedProcess `
            -FilePath $script:PythonExe `
            -Arguments @(
                "-m",
                "websockify",
                "--web=$NoVncRoot",
                "127.0.0.1:$NoVncPort",
                "127.0.0.1:$VncPort",
                "--file-only",
                "--heartbeat=30"
            ) `
            -StdOut $stdout `
            -StdErr $stderr `
            -WorkingDirectory $NoVncRoot

        Start-Sleep -Seconds 2

        try {
            if ($process.HasExited) {

                Write-DaoLog `
                    "websockify exited immediately with code $($process.ExitCode)." `
                    "ERROR"

                return $null
            }
        }
        catch {
        }

        if (-not (Wait-Port -Port $NoVncPort -TimeoutSeconds 30)) {

            Write-DaoLog `
                "websockify did not open TCP $NoVncPort." `
                "ERROR"

            $out = Read-SafeText -Path $stdout
            $err = Read-SafeText -Path $stderr

            if (-not [string]::IsNullOrWhiteSpace($out)) {
                Write-DaoLog "websockify stdout:`n$out" "ERROR"
            }

            if (-not [string]::IsNullOrWhiteSpace($err)) {
                Write-DaoLog "websockify stderr:`n$err" "ERROR"
            }

            return $null
        }

        Write-DaoLog `
            "noVNC/websockify is listening on TCP $NoVncPort."

        return $process
    }
    catch {

        Write-DaoLog `
            "websockify startup exception: $($_.Exception.Message)" `
            "ERROR"

        return $null
    }
}


# ==============================================================
# APPLICATION INSTALLATION
# ==============================================================

function Install-Applications {

    $results = [ordered]@{}

    $results["FileZilla"] = Install-ChocoPackage `
        -Package "filezilla" `
        -Detector {
            Find-Executable `
                -Names @("filezilla.exe")
        }

    $results["Geany"] = Install-ChocoPackage `
        -Package "geany" `
        -Detector {
            Find-Executable `
                -Names @("geany.exe")
        }

    $results["AnyDesk"] = Install-ChocoPackage `
        -Package "anydesk" `
        -Detector {
            Find-Executable `
                -Names @("AnyDesk.exe")
        }

    $results["TightVNC"] = Install-ChocoPackage `
        -Package "tightvnc" `
        -Detector {
            $service = Get-TightVncService

            if ($null -ne $service) {
                return "tvnserver"
            }

            return $null
        }

    $results["Cloudflare"] = Install-ChocoPackage `
        -Package "cloudflared" `
        -Detector {
            Find-Executable `
                -Names @("cloudflared.exe")
        }

    return $results
}


# ==============================================================
# DASHBOARD
# ==============================================================

function Write-Dashboard {

    param(
        [hashtable]$Services
    )

    $idFile = Join-Path $Logs "anydesk-id.txt"
    $urlFile = Join-Path $Logs "novnc-url.txt"
    $tunnelFile = Join-Path $Logs "tunnel-url.txt"

    $anydeskId = "Unavailable"
    $novncUrl = "Unavailable"
    $tunnelUrl = "Unavailable"

    if (Test-Path -LiteralPath $idFile) {
        $value = Get-Content `
            -LiteralPath $idFile `
            -Raw `
            -ErrorAction SilentlyContinue

        if ($null -ne $value) {
            $anydeskId = $value.Trim()
        }
    }

    if (Test-Path -LiteralPath $urlFile) {
        $value = Get-Content `
            -LiteralPath $urlFile `
            -Raw `
            -ErrorAction SilentlyContinue

        if ($null -ne $value) {
            $novncUrl = $value.Trim()
        }
    }

    if (Test-Path -LiteralPath $tunnelFile) {
        $value = Get-Content `
            -LiteralPath $tunnelFile `
            -Raw `
            -ErrorAction SilentlyContinue

        if ($null -ne $value) {
            $tunnelUrl = $value.Trim()
        }
    }

    $vncStatus = if (
        Test-PortListening -Port $VncPort
    ) {
        "RUNNING"
    }
    else {
        "NOT LISTENING"
    }

    $novncStatus = if (
        Test-PortListening -Port $NoVncPort
    ) {
        "RUNNING"
    }
    else {
        "NOT LISTENING"
    }

    $lines = @(
        "============================================================",
        "                 DAO WINDOWS DESKTOP",
        "============================================================",
        "",
        "Windows:",
        "Windows Server 2025 Runner",
        "",
        "Applications:",
        "[{0}] FileZilla" -f $(if ($Services["FileZilla"]) { "OK" } else { "FAIL" }),
        "[{0}] Geany" -f $(if ($Services["Geany"]) { "OK" } else { "FAIL" }),
        "[{0}] AnyDesk" -f $(if ($Services["AnyDesk"]) { "OK" } else { "WARN" }),
        "[{0}] TightVNC" -f $(if ($Services["TightVNC"]) { "OK" } else { "FAIL" }),
        "[{0}] noVNC" -f $(if ($Services["noVNC"]) { "OK" } else { "FAIL" }),
        "[{0}] websockify" -f $(if ($Services["websockify"]) { "OK" } else { "FAIL" }),
        "[{0}] Cloudflare Tunnel" -f $(if ($Services["Cloudflare"]) { "OK" } else { "WARN" }),
        "",
        "============================================================",
        "",
        "Workspace:",
        $Workspace,
        "",
        "============================================================",
        "",
        "AnyDesk:",
        "Status: $(if ($Services["AnyDesk"]) { "RUNNING" } else { "UNAVAILABLE" })",
        "ID: $anydeskId",
        "",
        "============================================================",
        "",
        "VNC:",
        "Status: $vncStatus",
        "TCP: $VncPort",
        "",
        "noVNC:",
        "Status: $novncStatus",
        "TCP: $NoVncPort",
        "",
        "WEB URL:",
        $novncUrl,
        "",
        "Tunnel:",
        $tunnelUrl,
        "",
        "============================================================",
        "",
        "Backup:",
        "dao-windows-backup",
        "",
        "Restore:",
        "Latest valid dao-windows-backup artifact",
        "",
        "Runtime:",
        "Approximately 03:40:00 desktop runtime",
        "04:00:00 total job maximum",
        "",
        "============================================================",
        "",
        "IMPORTANT:",
        "Do not display the actual passwords.",
        "",
        "============================================================"
    )

    Set-Content `
        -LiteralPath (Join-Path $Logs "connection-info.txt") `
        -Value $lines `
        -Encoding UTF8

    Write-Host ""

    foreach ($line in $lines) {
        Write-Host $line
    }

    Write-Host ""
}


# ==============================================================
# STARTUP
# ==============================================================

function Initialize-Desktop {

    Write-DaoLog "Starting DAO Windows Desktop."

    $python = Get-Command `
        python `
        -ErrorAction SilentlyContinue

    if ($null -eq $python) {

        Write-DaoLog `
            "Python is unavailable." `
            "ERROR"

        return $false
    }

    $script:PythonExe = $python.Source

    $apps = Install-Applications

    $services = [ordered]@{
        FileZilla  = [bool]$apps["FileZilla"]
        Geany      = [bool]$apps["Geany"]
        AnyDesk    = $false
        TightVNC   = $false
        noVNC      = $false
        websockify = $false
        Cloudflare = $false
    }

    # ----------------------------------------------------------
    # noVNC
    # ----------------------------------------------------------

    $services["noVNC"] = Install-NoVnc

    # ----------------------------------------------------------
    # websockify package
    # ----------------------------------------------------------

    $services["websockify"] = Install-Websockify

    # ----------------------------------------------------------
    # TightVNC
    # ----------------------------------------------------------

    if ($apps["TightVNC"]) {
        $services["TightVNC"] = Start-TightVnc
    }

    # ----------------------------------------------------------
    # AnyDesk
    # ----------------------------------------------------------

    if ($apps["AnyDesk"]) {
        $services["AnyDesk"] = Configure-AnyDesk
    }

    # ----------------------------------------------------------
    # Start websockify ONLY after VNC.
    # ----------------------------------------------------------

    $script:WebsockifyProcess = $null

    if (
        $services["TightVNC"] -and
        $services["noVNC"] -and
        $services["websockify"]
    ) {

        $script:WebsockifyProcess = Start-Websockify

        if ($null -ne $script:WebsockifyProcess) {
            $services["websockify"] = $true
        }
        else {
            $services["websockify"] = $false
        }
    }

    # ----------------------------------------------------------
    # Cloudflare ONLY after 6080.
    # ----------------------------------------------------------

    $script:CloudflaredProcess = $null

    if (
        $services["websockify"] -and
        (Test-PortListening -Port $NoVncPort)
    ) {

        $script:CloudflaredProcess = Start-Cloudflare

        if ($null -ne $script:CloudflaredProcess) {
            $services["Cloudflare"] = $true
        }
    }

    $script:DaoServices = $services

    Write-Dashboard -Services $services

    return $true
}


# ==============================================================
# SERVICE HEALTH
# ==============================================================

function Repair-TightVnc {

    if (Test-PortListening -Port $VncPort) {
        return $true
    }

    Write-DaoLog `
        "TightVNC TCP $VncPort is down. Attempting restart." `
        "WARN"

    return Start-TightVnc
}


function Repair-Websockify {

    if (Test-PortListening -Port $NoVncPort) {
        return $true
    }

    if (-not (Test-PortListening -Port $VncPort)) {
        Write-DaoLog `
            "Cannot repair websockify because VNC is unavailable." `
            "WARN"

        return $false
    }

    Write-DaoLog `
        "websockify TCP $NoVncPort is down. Attempting restart." `
        "WARN"

    $newProcess = Start-Websockify

    if ($null -ne $newProcess) {

        $script:WebsockifyProcess = $newProcess

        return $true
    }

    return $false
}


function Repair-Cloudflare {

    $alive = $false

    if ($null -ne $script:CloudflaredProcess) {

        try {
            $alive = -not $script:CloudflaredProcess.HasExited
        }
        catch {
            $alive = $false
        }
    }

    if ($alive) {
        return $true
    }

    if (-not (Test-PortListening -Port $NoVncPort)) {

        Write-DaoLog `
            "Cloudflare cannot restart because noVNC is unavailable." `
            "WARN"

        return $false
    }

    Write-DaoLog `
        "cloudflared is not running. Attempting restart." `
        "WARN"

    $newProcess = Start-Cloudflare

    if ($null -ne $newProcess) {

        $script:CloudflaredProcess = $newProcess

        return $true
    }

    return $false
}


function Repair-AnyDesk {

    $exe = Find-Executable `
        -Names @("AnyDesk.exe")

    if ($null -eq $exe) {
        return $false
    }

    $process = Get-Process `
        -Name "AnyDesk" `
        -ErrorAction SilentlyContinue

    if ($null -ne $process) {
        return $true
    }

    Write-DaoLog `
        "AnyDesk process not detected; attempting restart." `
        "WARN"

    & $exe --start 2>$null | Out-Null

    Start-Sleep -Seconds 3

    $process = Get-Process `
        -Name "AnyDesk" `
        -ErrorAction SilentlyContinue

    return ($null -ne $process)
}


# ==============================================================
# RUNTIME SUPERVISOR
# ==============================================================

function Run-Supervisor {

    if ($null -eq $script:DaoServices) {

        if (-not (Initialize-Desktop)) {

            Write-DaoLog `
                "Desktop initialization failed." `
                "ERROR"

            return
        }
    }

    $services = $script:DaoServices

    $runtimeMinutes = 220

    $start = Get-Date
    $deadline = $start.AddMinutes($runtimeMinutes)

    $vncRepairs = 0
    $websockifyRepairs = 0
    $cloudflareRepairs = 0
    $anydeskRepairs = 0

    $lastDashboard = Get-Date
    $lastVncCheck = Get-Date

    Write-DaoLog `
        "Runtime supervisor started."

    Write-DaoLog `
        "Maximum runtime: $runtimeMinutes minutes."

    while ((Get-Date) -lt $deadline) {

        Start-Sleep -Seconds 30

        # ------------------------------------------------------
        # VNC
        # ------------------------------------------------------

        if (-not (Test-PortListening -Port $VncPort)) {

            if ($vncRepairs -lt 3) {

                if (Repair-TightVnc) {

                    $vncRepairs++

                    Write-DaoLog `
                        "TightVNC repair succeeded."
                }
                else {

                    $vncRepairs++

                    Write-DaoLog `
                        "TightVNC repair failed." `
                        "WARN"
                }
            }
            else {

                Write-DaoLog `
                    "TightVNC repair limit reached." `
                    "ERROR"
            }
        }

        # ------------------------------------------------------
        # WEBSOCKIFY
        # ------------------------------------------------------

        if (-not (Test-PortListening -Port $NoVncPort)) {

            if ($websockifyRepairs -lt 3) {

                if (Repair-Websockify) {

                    $websockifyRepairs++

                    Write-DaoLog `
                        "websockify repair succeeded."
                }
                else {

                    $websockifyRepairs++

                    Write-DaoLog `
                        "websockify repair failed." `
                        "WARN"
                }
            }
            else {

                Write-DaoLog `
                    "websockify repair limit reached." `
                    "ERROR"
            }
        }

        # ------------------------------------------------------
        # CLOUDFLARE
        # ------------------------------------------------------

        $cloudAlive = $false

        if ($null -ne $script:CloudflaredProcess) {

            try {
                $cloudAlive = `
                    -not $script:CloudflaredProcess.HasExited
            }
            catch {
                $cloudAlive = $false
            }
        }

        if (-not $cloudAlive) {

            if ($cloudflareRepairs -lt 3) {

                if (Repair-Cloudflare) {

                    $cloudflareRepairs++

                    $services["Cloudflare"] = $true

                    Write-DaoLog `
                        "Cloudflare repair succeeded."
                }
                else {

                    $cloudflareRepairs++

                    $services["Cloudflare"] = $false

                    Write-DaoLog `
                        "Cloudflare repair failed." `
                        "WARN"
                }
            }
            else {

                $services["Cloudflare"] = $false

                Write-DaoLog `
                    "Cloudflare repair limit reached." `
                    "ERROR"
            }
        }

        # ------------------------------------------------------
        # ANYDESK
        # ------------------------------------------------------

        if (-not (Repair-AnyDesk)) {

            if ($anydeskRepairs -lt 3) {

                $anydeskRepairs++

                Write-DaoLog `
                    "AnyDesk is unavailable." `
                    "WARN"
            }
        }

        # ------------------------------------------------------
        # DASHBOARD EVERY 5 MINUTES
        # ------------------------------------------------------

        if (
            ((Get-Date) - $lastDashboard).TotalMinutes -ge 5
        ) {

            Write-Dashboard `
                -Services $services

            $lastDashboard = Get-Date
        }

        # ------------------------------------------------------
        # RUNTIME
        # ------------------------------------------------------

        $elapsed = (Get-Date) - $start
        $remaining = $deadline - (Get-Date)

        if ($remaining.TotalSeconds -lt 0) {
            $remaining = [TimeSpan]::Zero
        }

        Write-Host (
            "DAO Desktop active | Runtime: {0:hh\:mm\:ss} / {1:hh\:mm\:ss} | Remaining: {2:hh\:mm\:ss}" -f `
            $elapsed,
            ([TimeSpan]::FromMinutes($runtimeMinutes)),
            $remaining
        )
    }

    Write-DaoLog `
        "DAO Desktop runtime limit reached."

    Write-Dashboard `
        -Services $services
}


# ==============================================================
# MAIN
# ==============================================================

try {

    if (-not [string]::IsNullOrWhiteSpace($env:VNC_PASSWORD)) {
        Write-Output "::add-mask::$env:VNC_PASSWORD"
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ANYDESK_PASSWORD)) {
        Write-Output "::add-mask::$env:ANYDESK_PASSWORD"
    }

    if ($RuntimeOnly) {

        Run-Supervisor

        exit 0
    }

    if (-not (Initialize-Desktop)) {

        Write-DaoLog `
            "Initialization completed with critical failures." `
            "ERROR"

        exit 1
    }

    Write-DaoLog `
        "Initial DAO Desktop setup completed."

    exit 0
}
catch {

    Write-DaoLog `
        "Fatal desktop script error: $($_.Exception.Message)" `
        "ERROR"

    exit 1
}
