# Copyright (c) 2026 Odetayo Josiah Inioluwa. All rights reserved.
# Licensed under the terms in LICENSE.md - see repository
#
# NexLink-WPF.ps1
# WPF-based UI overhaul with all backend logic preserved from NexLink-GUI.ps1
#
# HOW TO RUN (important - do NOT double-click the file):
#   1. Right-click Start -> "Windows PowerShell (Admin)" or "Terminal (Admin)"
#   2. cd to the folder where this file is saved, e.g.: cd "Downloads\wifi setup"
#   3. If blocked, run once:  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   4. Then run:  .\NexLink-WPF.ps1

# ---------- Top-level crash boundary ----------
# This try/catch wraps the entire script to catch any uncaught exceptions,
# including startup crashes that prevent the UI from loading. Writes to
# a local crash log file for diagnosability even when Telegram error
# reporting is unreachable.
try {
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Invoke-WebRequest reports download progress via Write-Progress. In a normal
# console this is invisible, but in a ps2exe -noConsole build, that progress
# event renders as an actual modal dialog that blocks the entire WinForms
# message loop - freezing the whole app. Suppress it entirely.
$ProgressPreference = 'SilentlyContinue'

# Crash log directory
$script:CrashLogDir = Join-Path $env:LOCALAPPDATA "NexLink"
$script:CrashLogFile = Join-Path $script:CrashLogDir "crash.log"
try {
    if (-not (Test-Path $script:CrashLogDir)) {
        New-Item -ItemType Directory -Path $script:CrashLogDir -Force | Out-Null
    }
} catch {}

# Global unhandled exception handler - catches exceptions ANYWHERE in the process,
# on any thread, including those that bypass per-handler try/catch wrappers.
# This is a last-resort backstop, not a replacement for existing handler wrapping.
[System.AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $e)
    $exception = $e.ExceptionObject
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "$timestamp [GLOBAL-UNHANDLED] $($exception.GetType().FullName) - $($exception.Message)`nStack: $($exception.StackTrace)"
    try {
        Add-Content -Path $script:CrashLogFile -Value $logEntry -ErrorAction SilentlyContinue
    }
    catch {
        # If even this fails, try to write to a fallback location
        try {
            $fallbackLog = Join-Path $env:TEMP "NexLink-crash-fallback.log"
            Add-Content -Path $fallbackLog -Value $logEntry -ErrorAction SilentlyContinue
        }
        catch {}
    }
    # Note: AppDomain.UnhandledException is notification-only in many cases.
    # The process may terminate regardless of what this handler does.
    # This handler guarantees a log write before termination, not prevention.
})

# ---------- Graceful exit signal ----------
# release.ps1 runs unelevated, but NexLink.exe runs elevated (-requireAdmin),
# so Stop-Process from release.ps1 fails with Access Denied and window
# messages are blocked by UIPI across the elevation boundary. File I/O isn't
# blocked though, so release.ps1 drops this file to ask for a graceful exit,
# and the timer loop below polls for it every tick.
$script:ExitSignalFile = Join-Path $env:TEMP "NexLink.exitsignal"
Remove-Item $script:ExitSignalFile -ErrorAction SilentlyContinue

# ---------- Single-instance guard ----------
# Prevents two copies (e.g. a manual .ps1 run plus the .exe) from running at
# once and hammering the login endpoint independently of each other.
$script:InstanceMutex = New-Object System.Threading.Mutex($false, "Global\NexLink-SingleInstance")
try {
    $acquired = $script:InstanceMutex.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] {
    # Previous instance crashed/exited without releasing - we now own it, proceed.
    $acquired = $true
}
if (-not $acquired) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("NexLink is already running (check your system tray).", "NexLink") | Out-Null
    exit
}

# ---------- Backend Functions (UNCHANGED from NexLink-GUI.ps1) ----------
function Get-WifiAdapter {
    try {
        return Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Wi-Fi|Wireless' } | Select-Object -First 1
    }
    catch {
        return $null
    }
}

function Enable-WifiAdapterIfDisabled {
    $adapter = Get-WifiAdapter
    if (-not $adapter) {
        Add-Log "No Wi-Fi adapter found on this system."
        return $false
    }
    
    if ($adapter.Status -eq 'Disabled') {
        try {
            Add-Log "Wi-Fi adapter '$($adapter.Name)' is disabled. Enabling automatically..."
            Enable-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction Stop
            Start-Sleep -Seconds 2
            Add-Log "Wi-Fi adapter '$($adapter.Name)' enabled successfully."
            return $true
        }
        catch {
            Add-Log "Failed to enable Wi-Fi adapter '$($adapter.Name)': $($_.Exception.Message)"
            return $false
        }
    }
    else {
        return $false
    }
}

function Set-MaxWiFiPerformance {
    [CmdletBinding()]
    param(
        [switch]$WhatIf
    )
    
    $result = [PSCustomObject]@{
        Timestamp           = Get-Date
        AdapterName         = $null
        PowerSavingDisabled = $false
        TcpAutotuning       = 'Skipped'
        BufferTuning        = @{}
        Errors              = @()
    }
    
    # Get the active physical WiFi adapter
    try {
        $adapter = Get-NetAdapter -Physical | Where-Object { $_.MediaType -eq "Native 802.11" } | Select-Object -First 1
        if (-not $adapter) {
            Add-Log "Set-MaxWiFiPerformance: No physical WiFi adapter found."
            $result.Errors += "No physical WiFi adapter found"
            return $result
        }
        $result.AdapterName = $adapter.Name
        Add-Log "Set-MaxWiFiPerformance: Targeting adapter '$($adapter.Name)'"
    }
    catch {
        Add-Log "Set-MaxWiFiPerformance: Failed to get WiFi adapter: $($_.Exception.Message)"
        $result.Errors += "Failed to get WiFi adapter: $($_.Exception.Message)"
        return $result
    }
    
    # Tweak 1: Disable adapter power saving
    try {
        Add-Log "Set-MaxWiFiPerformance: Checking adapter power management settings..."
        try {
            $powerMgmt = Get-NetAdapterPowerManagement -Name $adapter.Name -ErrorAction Stop
            if ($powerMgmt.AllowComputerToTurnOffDevice -eq 'Enabled') {
                if (-not $WhatIf) {
                    Set-NetAdapterPowerManagement -Name $adapter.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
                    Add-Log "Set-MaxWiFiPerformance: Disabled 'Allow computer to turn off this device to save power' on adapter '$($adapter.Name)'."
                    $result.PowerSavingDisabled = $true
                }
                else {
                    Add-Log "Set-MaxWiFiPerformance [WhatIf]: Would disable 'Allow computer to turn off this device to save power' on adapter '$($adapter.Name)'."
                    $result.PowerSavingDisabled = 'WouldChange'
                }
            }
            else {
                Add-Log "Set-MaxWiFiPerformance: Power saving already disabled on adapter '$($adapter.Name)'."
                $result.PowerSavingDisabled = 'AlreadyDisabled'
            }
        }
        catch {
            Add-Log "Set-MaxWiFiPerformance: Power management property not supported on adapter '$($adapter.Name)': $($_.Exception.Message)"
            $result.PowerSavingDisabled = 'Skipped-Unsupported'
        }
    }
    catch {
        Add-Log "Set-MaxWiFiPerformance: Failed to disable power saving: $($_.Exception.Message)"
        $result.Errors += "Failed to disable power saving: $($_.Exception.Message)"
    }
    
    # Tweak 2: Reset TCP autotuning to normal
    try {
        Add-Log "Set-MaxWiFiPerformance: Checking TCP autotuning level..."
        try {
            $currentLevel = netsh interface tcp show global | Select-String "Receive Window Auto-Tuning Level"
            if ($currentLevel -and $currentLevel -match 'normal') {
                Add-Log "Set-MaxWiFiPerformance: TCP autotuning already set to normal."
                $result.TcpAutotuning = 'AlreadyNormal'
            }
            else {
                if (-not $WhatIf) {
                    netsh interface tcp set global autotuninglevel=normal | Out-Null
                    Add-Log "Set-MaxWiFiPerformance: Set TCP autotuning to normal."
                    $result.TcpAutotuning = 'ChangedToNormal'
                }
                else {
                    Add-Log "Set-MaxWiFiPerformance [WhatIf]: Would set TCP autotuning to normal."
                    $result.TcpAutotuning = 'WouldChange'
                }
            }
        }
        catch {
            Add-Log "Set-MaxWiFiPerformance: Failed to check/set TCP autotuning: $($_.Exception.Message)"
            $result.TcpAutotuning = 'Failed'
            $result.Errors += "Failed to check/set TCP autotuning: $($_.Exception.Message)"
        }
    }
    catch {
        Add-Log "Set-MaxWiFiPerformance: Failed to check TCP autotuning: $($_.Exception.Message)"
        $result.TcpAutotuning = 'Failed'
        $result.Errors += "Failed to check TCP autotuning: $($_.Exception.Message)"
    }
    
    # Tweak 3: Interrupt moderation / buffer size tuning
    try {
        Add-Log "Set-MaxWiFiPerformance: Checking advanced adapter properties..."
        try {
            $advancedProps = Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction Stop
            $result.BufferTuning = @{}
            
            # InterruptModeration
            $interruptProp = $advancedProps | Where-Object { $_.DisplayName -like '*InterruptModeration*' -or $_.RegistryKeyword -like '*InterruptModeration*' }
            if ($interruptProp) {
                try {
                    if ($interruptProp.DisplayValue -ne 'Disabled') {
                        if (-not $WhatIf) {
                            Set-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword $interruptProp.RegistryKeyword -RegistryValue 0 -ErrorAction Stop
                            Add-Log "Set-MaxWiFiPerformance: Set InterruptModeration to Disabled on adapter '$($adapter.Name)'."
                            $result.BufferTuning.InterruptModeration = 'ChangedToDisabled'
                        }
                        else {
                            Add-Log "Set-MaxWiFiPerformance [WhatIf]: Would set InterruptModeration to Disabled on adapter '$($adapter.Name)'."
                            $result.BufferTuning.InterruptModeration = 'WouldChange'
                        }
                    }
                    else {
                        Add-Log "Set-MaxWiFiPerformance: InterruptModeration already Disabled on adapter '$($adapter.Name)'."
                        $result.BufferTuning.InterruptModeration = 'AlreadyDisabled'
                    }
                }
                catch {
                    Add-Log "Set-MaxWiFiPerformance: Failed to set InterruptModeration: $($_.Exception.Message)"
                    $result.BufferTuning.InterruptModeration = 'Failed'
                    $result.Errors += "Failed to set InterruptModeration: $($_.Exception.Message)"
                }
            }
            else {
                Add-Log "Set-MaxWiFiPerformance: InterruptModeration property not exposed by driver on adapter '$($adapter.Name)'."
                $result.BufferTuning.InterruptModeration = 'NotExposed'
            }
            
            # ReceiveBuffers
            $receiveProp = $advancedProps | Where-Object { $_.DisplayName -like '*ReceiveBuffers*' -or $_.RegistryKeyword -like '*ReceiveBuffers*' }
            if ($receiveProp) {
                try {
                    $currentValue = [int]$receiveProp.DisplayValue
                    $maxValue = if ($receiveProp.ValidValueCount -gt 0) { [int]($receiveProp.ValidValues | Measure-Object -Maximum).Maximum } else { 2048 }
                    $targetValue = [Math]::Min($maxValue, 2048)
                    
                    if ($currentValue -lt $targetValue) {
                        if (-not $WhatIf) {
                            Set-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword $receiveProp.RegistryKeyword -RegistryValue $targetValue -ErrorAction Stop
                            Add-Log "Set-MaxWiFiPerformance: Set ReceiveBuffers to $targetValue on adapter '$($adapter.Name)' (was $currentValue)."
                            $result.BufferTuning.ReceiveBuffers = "ChangedTo$targetValue"
                        }
                        else {
                            Add-Log "Set-MaxWiFiPerformance [WhatIf]: Would set ReceiveBuffers to $targetValue on adapter '$($adapter.Name)' (currently $currentValue)."
                            $result.BufferTuning.ReceiveBuffers = "WouldChangeTo$targetValue"
                        }
                    }
                    else {
                        Add-Log "Set-MaxWiFiPerformance: ReceiveBuffers already at $currentValue on adapter '$($adapter.Name)'."
                        $result.BufferTuning.ReceiveBuffers = 'AlreadyOptimal'
                    }
                }
                catch {
                    Add-Log "Set-MaxWiFiPerformance: Failed to set ReceiveBuffers: $($_.Exception.Message)"
                    $result.BufferTuning.ReceiveBuffers = 'Failed'
                    $result.Errors += "Failed to set ReceiveBuffers: $($_.Exception.Message)"
                }
            }
            else {
                Add-Log "Set-MaxWiFiPerformance: ReceiveBuffers property not exposed by driver on adapter '$($adapter.Name)'."
                $result.BufferTuning.ReceiveBuffers = 'NotExposed'
            }
            
            # TransmitBuffers
            $transmitProp = $advancedProps | Where-Object { $_.DisplayName -like '*TransmitBuffers*' -or $_.RegistryKeyword -like '*TransmitBuffers*' }
            if ($transmitProp) {
                try {
                    $currentValue = [int]$transmitProp.DisplayValue
                    $maxValue = if ($transmitProp.ValidValueCount -gt 0) { [int]($transmitProp.ValidValues | Measure-Object -Maximum).Maximum } else { 2048 }
                    $targetValue = [Math]::Min($maxValue, 2048)
                    
                    if ($currentValue -lt $targetValue) {
                        if (-not $WhatIf) {
                            Set-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword $transmitProp.RegistryKeyword -RegistryValue $targetValue -ErrorAction Stop
                            Add-Log "Set-MaxWiFiPerformance: Set TransmitBuffers to $targetValue on adapter '$($adapter.Name)' (was $currentValue)."
                            $result.BufferTuning.TransmitBuffers = "ChangedTo$targetValue"
                        }
                        else {
                            Add-Log "Set-MaxWiFiPerformance [WhatIf]: Would set TransmitBuffers to $targetValue on adapter '$($adapter.Name)' (currently $currentValue)."
                            $result.BufferTuning.TransmitBuffers = "WouldChangeTo$targetValue"
                        }
                    }
                    else {
                        Add-Log "Set-MaxWiFiPerformance: TransmitBuffers already at $currentValue on adapter '$($adapter.Name)'."
                        $result.BufferTuning.TransmitBuffers = 'AlreadyOptimal'
                    }
                }
                catch {
                    Add-Log "Set-MaxWiFiPerformance: Failed to set TransmitBuffers: $($_.Exception.Message)"
                    $result.BufferTuning.TransmitBuffers = 'Failed'
                    $result.Errors += "Failed to set TransmitBuffers: $($_.Exception.Message)"
                }
            }
            else {
                Add-Log "Set-MaxWiFiPerformance: TransmitBuffers property not exposed by driver on adapter '$($adapter.Name)'."
                $result.BufferTuning.TransmitBuffers = 'NotExposed'
            }
            
            if ($result.BufferTuning.Count -gt 0) {
                Add-Log "Set-MaxWiFiPerformance: Buffer tuning complete. Some changes may require reconnect to take effect."
            }
        }
        catch {
            Add-Log "Set-MaxWiFiPerformance: Failed to enumerate advanced properties: $($_.Exception.Message)"
            $result.Errors += "Failed to enumerate advanced properties: $($_.Exception.Message)"
        }
    }
    catch {
        Add-Log "Set-MaxWiFiPerformance: Failed to check advanced properties: $($_.Exception.Message)"
        $result.Errors += "Failed to check advanced properties: $($_.Exception.Message)"
    }
    
    Add-Log "Set-MaxWiFiPerformance: Complete. Result: $($result.Errors.Count) error(s)."
    return $result
}

function Get-CurrentSSID {
    try {
        $result = netsh wlan show interfaces 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        $line = $result | Select-String '^\s{1,4}SSID\s*:\s*(.+)$'
        if ($line) { return ($line.Matches[0].Groups[1].Value).Trim() }
    }
    catch {}
    return $null
}

function Get-VisibleWifiNetworks {
    $networks = @()
    try {
        $output = netsh wlan show networks mode=BSSID 2>$null
        if ($LASTEXITCODE -ne 0) { return $networks }

        $currentNetwork = $null
        foreach ($line in $output) {
            if ($line -match '^\s*SSID\s+\d+\s*:\s*(.+?)\s*$') {
                if ($currentNetwork) { $networks += [PSCustomObject]$currentNetwork }
                $currentNetwork = [ordered]@{ SSID = $matches[1].Trim(); Signal = $null }
            }
            elseif ($currentNetwork -and $line -match '^\s*Signal\s*:\s*(\d+)\s*%') {
                $currentNetwork.Signal = [int]$matches[1]
            }
        }

        if ($currentNetwork) { $networks += [PSCustomObject]$currentNetwork }
    }
    catch {}

    return $networks
}

# ---------- Settings ----------
$NexLinkVersion = "1.3.46"
$UpdateManifestUrl = "https://raw.githubusercontent.com/highnine699-del/nexlink-updates/main/latest.json"
$UpdateCheckEnabled = $true
$PingTargets = @("8.8.8.8", "1.1.1.1")
$TestPageUrls = @(
    @{ Url = "http://www.msftconnecttest.com/connecttest.txt"; ExpectedText = "Microsoft Connect Test" },
    @{ Url = "http://detectportal.firefox.com/success.txt"; ExpectedText = "success" }
)
$LoginUrl = "https://internet.lmu.edu.ng/login"
$LogoutUrl = "https://internet.lmu.edu.ng/logout"
$CheckIntervalMs = 5000
$WifiFailsBeforeFix = 3
$ReconnectCooldownSec = 10
$PortalLoginRetryCooldownSec = 30
$MaxLogLines = 5000
$TrustedNetworks = @(
    'Abraham Metro Wifi |2|',
    'Abraham Reception',
    'Abraham-Metro Wifi',
    'CSC_WIFI',
    'CSIS|Eng Workshop|4',
    'CSIS|Mech Lab_50',
    'Daniel-Metro Wifi',
    'Jacob Metro Wifi',
    'Jacob Reception',
    'LMU-Metro Wifi',
    'Metro wifi cafeteria',
    'Sarah Metro Wifi',
    'Wing C Coutyard Wifi',
    'Wing C Coutyard Wifi| 5GHz|',
    'csis|eng workshop|1|31'
)
$ScriptDir = Split-Path -Path ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Parent
$script:DataDir = Join-Path $env:LOCALAPPDATA "NexLink"
$CredFile = Join-Path $script:DataDir "lmu_portal.cred"
$LogFile = Join-Path $script:DataDir "lmu_autoconnect.log"

# Ensure data directory exists
try {
    if (-not (Test-Path $script:DataDir)) {
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
    }
}
catch {
    # If we can't create the data directory, fall back to script directory
    $script:DataDir = $ScriptDir
    $CredFile = Join-Path $ScriptDir "lmu_portal.cred"
    $LogFile = Join-Path $ScriptDir "lmu_autoconnect.log"
}

$script:wifiFailCount = 0
$script:portalFailCount = 0
$script:portalUnknownCount = 0
$script:LastKnownSSID = $null
$script:PortalRetryAfter = [DateTime]::MinValue
$script:PortalCooldownShown = $false
$script:LastReconnectAt = [DateTime]::MinValue
$script:PortalSession = $null
$script:PortalSessionCreatedAt = [DateTime]::MinValue
$script:ReconnectInProgress = $false
$script:LastLogTrimAt = Get-Date
$script:LastLoggedStatus = ""
$script:LastHealthyLogAt = [DateTime]::MinValue
$script:LastUpdateCheckAt = [DateTime]::MinValue
$script:PendingUpdateManifest = $null
$script:StartTime = Get-Date
$script:LastHeartbeatAt = [DateTime]::MinValue

# ---------- Credential handling ----------
function Save-PortalCredential {
    $inputForm = New-Object System.Windows.Forms.Form
    $inputForm.Text = "LMU Portal Login"
    $inputForm.Size = New-Object System.Drawing.Size(340, 220)
    $inputForm.StartPosition = "CenterScreen"
    $inputForm.FormBorderStyle = "FixedDialog"
    $inputForm.MaximizeBox = $false
    $inputForm.TopMost = $false

    $lblUser = New-Object System.Windows.Forms.Label -Property @{ Text = "Portal Username:"; Location = "20,20"; Size = "280,20" }
    $txtUser = New-Object System.Windows.Forms.TextBox -Property @{ Location = "20,45"; Size = "280,20" }
    $lblPass = New-Object System.Windows.Forms.Label -Property @{ Text = "Portal Password:"; Location = "20,80"; Size = "280,20" }
    $txtPass = New-Object System.Windows.Forms.TextBox -Property @{ Location = "20,105"; Size = "280,20"; UseSystemPasswordChar = $true }
    $btnOk = New-Object System.Windows.Forms.Button -Property @{ Text = "Save"; Location = "110,145"; Size = "100,30"; DialogResult = "OK" }

    $inputForm.Controls.AddRange(@($lblUser, $txtUser, $lblPass, $txtPass, $btnOk))
    $inputForm.AcceptButton = $btnOk
    $inputForm.Add_Shown({ $inputForm.Activate(); $txtUser.Focus() })
    $result = $inputForm.ShowDialog()

    if ($result -eq "OK" -and $txtUser.Text -and $txtPass.Text) {
        $secure = ConvertTo-SecureString $txtPass.Text -AsPlainText -Force
        $encryptedPass = ConvertFrom-SecureString $secure
        try {
            @{ Username = $txtUser.Text; Password = $encryptedPass } | ConvertTo-Json | Set-Content -Path $CredFile -Encoding UTF8
            Add-Log "Credentials saved for user '$($txtUser.Text)' (password stored encrypted, never logged)."
            return $true
        }
        catch {
            Add-Log "FAILED to save credentials: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Unable to save credentials: $($_.Exception.Message)", "NexLink") | Out-Null
            return $false
        }
    }
    Add-Log "Credential entry cancelled or incomplete."
    return $false
}

function Get-PortalCredential {
    if (-not (Test-Path $CredFile)) {
        Add-Log "No credential file found at '$CredFile' - prompting for portal login."
        if (-not (Save-PortalCredential)) {
            Add-Log "No credentials entered. User cancelled credential entry."
            return $null
        }
    }

    try {
        $data = Get-Content $CredFile -Raw | ConvertFrom-Json
    }
    catch {
        Add-Log "Credential file is unreadable or corrupt: $($_.Exception.Message)"
        return $null
    }

    if (-not $data.Username -or -not $data.Password) {
        Add-Log "Credential file is missing username or password field."
        return $null
    }

    try {
        $securePass = ConvertTo-SecureString $data.Password
    }
    catch {
        Add-Log "Saved password could not be decrypted (DPAPI mismatch - different user/machine?): $($_.Exception.Message)"
        return $null
    }

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
    try {
        $plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    return @{ Username = [string]$data.Username; Password = $plainPass }
}

# ---------- Wifi helpers ----------
function Update-KnownSSID {
    $current = Get-CurrentSSID
    if ($current) { $script:LastKnownSSID = $current }
    return $current
}

function Clear-DnsCache {
    try {
        ipconfig /flushdns | Out-Null
    }
    catch {}
}

function Invoke-WebRequestWithRetry {
    param(
        [string]$Uri,
        [string]$Method,
        [object]$Body,
        [string]$ContentType,
        [int]$TimeoutSec,
        [int]$MaxRetries = 3,
        [object]$WebSession,
        [string]$SessionVariable,
        [hashtable]$Headers,
        [string]$OutFile
    )
    
    $backoffDelays = @(1, 2, 4)
    $attempt = 0
    
    while ($attempt -lt $MaxRetries) {
        try {
            $params = @{
                Uri = $Uri
                Method = $Method
                UseBasicParsing = $true
                TimeoutSec = $TimeoutSec
                ErrorAction = 'Stop'
            }
            if ($Body) { $params.Body = $Body }
            if ($ContentType) { $params.ContentType = $ContentType }
            if ($WebSession) { $params.WebSession = $WebSession }
            if ($SessionVariable) { $params.SessionVariable = $SessionVariable }
            if ($Headers) { $params.Headers = $Headers }
            if ($OutFile) { $params.OutFile = $OutFile }
            
            return Invoke-WebRequest @params
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
            }
            
            # Don't retry on 4xx client errors (auth failures, bad requests)
            if ($statusCode -ge 400 -and $statusCode -lt 500) {
                throw
            }
            
            # Retry on timeout or 5xx server errors
            $attempt++
            if ($attempt -lt $MaxRetries) {
                $backoff = $backoffDelays[$attempt - 1]
                Add-Log "[RETRY] Request failed (attempt $attempt/$MaxRetries), retrying in ${backoff}s..."
                Start-Sleep -Seconds $backoff
            }
            else {
                throw
            }
        }
    }
}

function Invoke-SendErrorReport {
    Add-Log "[DEBUG] Invoke-SendErrorReport started"

    # Collect diagnostic data: disk logs + memory logs + current status
    $diskLines = @()
    try {
        if (Test-Path $LogFile) {
            $diskLines = Get-Content $LogFile -ErrorAction SilentlyContinue | Select-Object -Last 500
            Add-Log "[DEBUG] Collected $($diskLines.Count) disk log lines"
        }
        else {
            Add-Log "[DEBUG] Log file not found: $LogFile"
        }
    }
    catch {
        Add-Log "[DEBUG] Error reading disk logs: $($_.Exception.Message)"
    }

    [System.Threading.Monitor]::Enter($script:LogLock)
    try {
        $memLines = $script:logLines | Select-Object -Last 100
        Add-Log "[DEBUG] Collected $($memLines.Count) memory log lines"
    }
    finally {
        [System.Threading.Monitor]::Exit($script:LogLock)
    }

    # Merge and deduplicate, keep newest 500
    $allLines = @($diskLines) + @($memLines) | Select-Object -Unique | Select-Object -Last 500

    # Redact the portal username before this ever leaves the machine.
    $allLines = $allLines | ForEach-Object {
        $_ -replace "user '[^']*'", "user '[redacted]'" `
           -replace "for user: [^\s]+", "for user: [redacted]"
    }
    Add-Log "[DEBUG] Total unique log lines after merge: $($allLines.Count)"

    # Gather current connection status and diagnostics
    $connectionState = if (Get-Variable -Name ConnectionState -Scope Script -ErrorAction SilentlyContinue) { $script:ConnectionState } else { "unknown" }
    $currentSsid = try { (netsh wlan show interfaces | Select-String "SSID" | Select-Object -First 1).ToString().Split(":")[1].Trim() } catch { "unknown" }
    $uptime = if (Get-Variable -Name StartTime -Scope Script -ErrorAction SilentlyContinue) { try { (Get-Date) - $script:StartTime } catch { [TimeSpan]::Zero } } else { [TimeSpan]::Zero }
    $uptimeStr = if ($uptime.TotalSeconds -gt 0) { "$([math]::Floor($uptime.TotalHours))h $([math]::Floor($uptime.Minutes))m" } else { "unknown" }
    $crashReason = if (Get-Variable -Name CrashReason -Scope Script -ErrorAction SilentlyContinue) { $script:CrashReason } else { $null }

    Add-Log "[DEBUG] Connection state: $connectionState, SSID: $currentSsid, Uptime: $uptimeStr"

    # If no diagnostic data exists
    if ($allLines.Count -eq 0 -and $connectionState -eq "unknown" -and $currentSsid -eq "unknown") {
        [System.Windows.Forms.MessageBox]::Show(
            "No diagnostic information found.",
            "Send Error Report",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    # Show comment dialog
    $reportForm = New-Object System.Windows.Forms.Form
    $reportForm.Text = "Send Error Report"
    $reportForm.Size = New-Object System.Drawing.Size(420, 240)
    $reportForm.StartPosition = "CenterScreen"
    $reportForm.FormBorderStyle = "FixedDialog"
    $reportForm.MaximizeBox = $false
    $reportForm.TopMost = $false
    $reportForm.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#14171F")

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Describe what went wrong (optional):"
    $lbl.Location = New-Object System.Drawing.Point(16, 16)
    $lbl.Size = New-Object System.Drawing.Size(380, 20)
    $lbl.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#F5F5F7")
    $lbl.BackColor = [System.Drawing.Color]::Transparent

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(16, 44)
    $txt.Size = New-Object System.Drawing.Size(378, 80)
    $txt.Multiline = $true
    $txt.ScrollBars = "Vertical"
    $txt.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#0B0D13")
    $txt.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#F5F5F7")
    $txt.BorderStyle = "FixedSingle"

    $infoLbl = New-Object System.Windows.Forms.Label
    $infoLbl.Text = "The last 24hrs of connection logs will be included. Your password and username are redacted before sending."
    $infoLbl.Location = New-Object System.Drawing.Point(16, 132)
    $infoLbl.Size = New-Object System.Drawing.Size(380, 32)
    $infoLbl.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#9CA3AF")
    $infoLbl.BackColor = [System.Drawing.Color]::Transparent

    $btnSend = New-Object System.Windows.Forms.Button
    $btnSend.Text = "Send Report"
    $btnSend.Location = New-Object System.Drawing.Point(196, 170)
    $btnSend.Size = New-Object System.Drawing.Size(100, 30)
    $btnSend.DialogResult = "OK"
    $btnSend.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#0EA5E9")
    $btnSend.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#FFFFFF")
    $btnSend.FlatStyle = "Flat"

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(304, 170)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 30)
    $btnCancel.DialogResult = "Cancel"
    $btnCancel.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#374151")
    $btnCancel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#F5F5F7")
    $btnCancel.FlatStyle = "Flat"

    $reportForm.Controls.AddRange(@($lbl, $txt, $infoLbl, $btnSend, $btnCancel))
    $reportForm.AcceptButton = $btnSend
    $reportForm.CancelButton = $btnCancel

    $result = $reportForm.ShowDialog()
    $reportForm.Dispose()

    if ($result -ne "OK") { return }

    $comment = $txt.Text.Trim()

    # Gather system metadata
    $osCaption = try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { "unknown" }
    $osBuild = try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).BuildNumber } catch { "unknown" }
    $psVersion = try { $PSVersionTable.PSVersion.ToString() } catch { "unknown" }
    $adapterInfo = Get-WifiAdapter
    $adapterName = if ($adapterInfo) { $adapterInfo.Name } else { "unknown" }
    $adapterDesc = if ($adapterInfo) { $adapterInfo.InterfaceDescription } else { "unknown" }
    $driverVersion = if ($adapterInfo) { try { (Get-NetAdapter -Name $adapterInfo.Name -ErrorAction Stop | Get-NetAdapterDriver).DriverVersion } catch { "unknown" } } else { "unknown" }
    $machineHash = try { Get-MachineFingerprint } catch { "" }
    $machinePrefix = if ($machineHash.Length -ge 8) { $machineHash.Substring(0, 8) } else { $machineHash }
    $timestamp = (Get-Date -Format 'o')
    $timeZone = try { [System.TimeZoneInfo]::Local.DisplayName } catch { "unknown" }
    $memoryInfo = try { $cs = Get-CimInstance Win32_ComputerSystem; "$([math]::Round($cs.TotalPhysicalMemory / 1GB, 2)) GB" } catch { "unknown" }
    $cpuArch = try { [System.Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE") } catch { "unknown" }

    # Build structured payload
    $payload = @{
        version = $NexLinkVersion
        system = @{
            os = $osCaption
            osBuild = $osBuild
            powerShellVersion = $psVersion
            cpuArchitecture = $cpuArch
            memory = $memoryInfo
            timeZone = $timeZone
        }
        network = @{
            adapterName = $adapterName
            adapterDescription = $adapterDesc
            driverVersion = $driverVersion
            currentSsid = $currentSsid
            connectionState = $connectionState
        }
        diagnostics = @{
            uptime = $uptimeStr
            crashReason = $crashReason
            machineId = $machinePrefix
            timestamp = $timestamp
        }
        logs = @($allLines)
        comment = $comment
    } | ConvertTo-Json -Compress -Depth 4

    Add-Log "[DEBUG] Payload size: $($payload.Length) characters"
    Add-Log "[DEBUG] Sending to: https://nexlink-license.highnine699.workers.dev/report"

    try {
        $sendReportBtn.IsEnabled = $false
        $sendReportBtn.Content = "Sending..."
        Add-Log "[DEBUG] Starting HTTP request..."
        $resp = Invoke-WebRequestWithRetry `
            -Uri "https://nexlink-license.highnine699.workers.dev/report" `
            -Method Post `
            -Body $payload `
            -ContentType "application/json" `
            -TimeoutSec 60 `
            -MaxRetries 3
        Add-Log "[DEBUG] HTTP response status: $($resp.StatusCode)"
        Add-Log "[DEBUG] HTTP response content: $($resp.Content)"
        Add-Log "Error report sent successfully."
        [System.Windows.Forms.MessageBox]::Show(
            "Report sent. Thank you - this helps make NexLink better.",
            "Report Sent",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        $errorMsg = $_.Exception.Message
        $errorType = $_.Exception.GetType().FullName
        $errorStackTrace = $_.ScriptStackTrace
        $respBody = ""
        if ($_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = [System.IO.StreamReader]::new($stream)
                $respBody = $reader.ReadToEnd()
                $reader.Close()
                $stream.Close()
            } catch {}
        }
        Add-Log "[DEBUG] Error type: $errorType"
        Add-Log "[DEBUG] Error message: $errorMsg"
        Add-Log "[DEBUG] Error stack trace: $errorStackTrace"
        Add-Log "[DEBUG] Response body: $respBody"
        Add-Log "Failed to send error report: $errorMsg"
        if ($respBody) {
            try {
                $errorJson = $respBody | ConvertFrom-Json
                if ($errorJson.error -and $errorJson.body) {
                    $errorMsg = "$($errorJson.error) - Status: $($errorJson.status)`n`nResponse: $($errorJson.body)"
                }
            } catch {
                Add-Log "[DEBUG] Failed to parse error JSON: $($_.Exception.Message)"
            }
        }
        [System.Windows.Forms.MessageBox]::Show(
            "Could not send the report. Check your connection and try again.`n`n$errorMsg",
            "Send Failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        $sendReportBtn.IsEnabled = $true
        $sendReportBtn.Content = "Send Error Report"
    }
}

function Test-ForUpdate {
    # Fully defensive by design: any failure here (network, bad JSON,
    # malformed version string) must be swallowed silently and never
    # affect the rest of the app. This function only ever returns a
    # manifest object when a genuinely newer version is confirmed.
    if (-not $UpdateCheckEnabled) { return $null }
    try {
        $resp = Invoke-WebRequestWithRetry -Uri $UpdateManifestUrl -Method Get -TimeoutSec 8 -MaxRetries 3
        $rawContent = $resp.Content.TrimStart([char]0xFEFF, [char]0x200B).Trim()
        $manifest = $rawContent | ConvertFrom-Json -ErrorAction Stop
        if (-not $manifest.version -or -not $manifest.installer_url -or -not $manifest.sha256) {
            Add-Log "Update check: manifest is missing required fields, ignoring."
            return $null
        }
        $remoteVersion = [version]$manifest.version
        $currentVersion = [version]$NexLinkVersion
        if ($remoteVersion -gt $currentVersion) {
            Add-Log "Update check: v$($manifest.version) is available (current: v$NexLinkVersion)."
            return $manifest
        }
        else {
            Add-Log "Update check: up to date (v$NexLinkVersion)."
            return $null
        }
    }
    catch {
        Add-Log "Update check failed (non-fatal, app continues normally): $($_.Exception.Message)"
        return $null
    }
}

function Start-NexLinkUpdate($manifest) {
    $tempInstaller = Join-Path $env:TEMP "NexLink-Update-$($manifest.version).exe"
    try {
        Add-Log "Downloading update v$($manifest.version)..."
        Invoke-WebRequestWithRetry -Uri $manifest.installer_url -Method Get -TimeoutSec 60 -MaxRetries 3 -OutFile $tempInstaller
    }
    catch {
        Add-Log "Update download FAILED (app unaffected, still running normally): $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show("Couldn't download the update. Your current version is unaffected and still running.`n`n$($_.Exception.Message)", "NexLink Update") | Out-Null
        Remove-Item $tempInstaller -ErrorAction SilentlyContinue
        return
    }

    try {
        $actualHash = (Get-FileHash -Path $tempInstaller -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($actualHash -ne $manifest.sha256.ToUpper()) {
            Add-Log "Update verification FAILED - hash mismatch. Aborting update, current app unaffected."
            [System.Windows.MessageBox]::Show("The downloaded update failed verification and will NOT be installed. Your current version is unaffected and still running.", "NexLink Update - Verification Failed") | Out-Null
            Remove-Item $tempInstaller -ErrorAction SilentlyContinue
            return
        }
        Add-Log "Update verified (SHA256 match). Proceeding with install."
    }
    catch {
        Add-Log "Update verification could not be completed: $($_.Exception.Message)"
        Remove-Item $tempInstaller -ErrorAction SilentlyContinue
        return
    }

    # CRITICAL: this process must fully exit BEFORE the installer runs -
    # Windows won't let an installer overwrite a currently-running exe.
    # A detached helper waits for this process to actually terminate,
    # then runs the installer, then relaunches the new exe.
    $exePath = Join-Path $ScriptDir "NexLink.exe"
    $currentPid = $PID
    $helperScript = @"
Start-Sleep -Milliseconds 500
`$deadline = (Get-Date).AddSeconds(15)
while ((Get-Process -Id $currentPid -ErrorAction SilentlyContinue) -and (Get-Date) -lt `$deadline) {
    Start-Sleep -Milliseconds 200
}
Start-Process -FilePath '$tempInstaller' -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Wait
if (Test-Path '$exePath') {
    Start-Process -FilePath '$exePath'
}
Remove-Item '$tempInstaller' -ErrorAction SilentlyContinue
Remove-Item `$MyInvocation.MyCommand.Path -ErrorAction SilentlyContinue
"@
    $helperPath = Join-Path $env:TEMP "NexLink-UpdateHelper-$($manifest.version).ps1"
    Set-Content -Path $helperPath -Value $helperScript -Encoding UTF8

    Add-Log "Handing off to update helper and exiting to release the file lock..."
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$helperPath`"" -WindowStyle Hidden

    $timer.Stop()
    $trayIcon.Visible = $false
    try { $script:InstanceMutex.ReleaseMutex() } catch {}
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
}

function Get-CurrentWifiState {
    try {
        $result = netsh wlan show interfaces 2>$null
        if ($LASTEXITCODE -ne 0) { return [PSCustomObject]@{ SSID = $null; Signal = 0 } }

        $ssid = $null
        $signal = 0
        $ssidLine = $result | Select-String '^\s{1,4}SSID\s*:\s*(.+)$'
        if ($ssidLine) { $ssid = ($ssidLine.Matches[0].Groups[1].Value).Trim() }

        $signalLine = $result | Select-String '^\s*Signal\s*:\s*(\d+)\s*%'
        if ($signalLine) { $signal = [int]$signalLine.Matches[0].Groups[1].Value }

        return [PSCustomObject]@{ SSID = $ssid; Signal = $signal }
    }
    catch {
        Add-Log "Get-CurrentWifiState failed: $($_.Exception.Message)"
        return [PSCustomObject]@{ SSID = $null; Signal = 0 }
    }
}

function Test-TrustedNetwork {
    param([string]$Ssid)
    if (-not $Ssid) { return $false }
    $normalized = $Ssid.Trim().ToLowerInvariant()
    foreach ($trusted in $TrustedNetworks) {
        if ($normalized -eq $trusted.Trim().ToLowerInvariant()) { return $true }
    }
    return $false
}

function Get-BestFreeNetwork {
    param([psobject]$CurrentWifiState = $null, [array]$VisibleNetworks = $null)

    if (-not $CurrentWifiState) { $CurrentWifiState = Get-CurrentWifiState }
    if (-not $VisibleNetworks) { $VisibleNetworks = Get-VisibleWifiNetworks | Where-Object { Test-TrustedNetwork -Ssid $_.SSID } }
    $visibleNetworks = @($VisibleNetworks)
    if (-not $visibleNetworks -or $visibleNetworks.Count -eq 0) { return $null }

    $currentSsid = if ($CurrentWifiState) { $CurrentWifiState.SSID } else { $null }
    $currentSignal = if ($CurrentWifiState) { $CurrentWifiState.Signal } else { 0 }

    $scored = foreach ($network in $visibleNetworks) {
        $name = [string]$network.SSID
        $signal = if ($null -ne $network.Signal) { [int]$network.Signal } else { 0 }
        $score = $signal
        if ($currentSsid -and $name -eq $currentSsid) { $score += 5 }
        if ($currentSsid -and $signal -ge ($currentSignal + 5)) { $score += 10 }
        [PSCustomObject]@{ SSID = $name; Signal = $signal; Score = $score }
    }

    $best = $scored | Sort-Object Score -Descending | Select-Object -First 1
    if ($best) { return $best.SSID }
    return $null
}

function Get-AllTrustedNetworksByScore {
    param([psobject]$CurrentWifiState = $null, [array]$VisibleNetworks = $null)

    if (-not $CurrentWifiState) { $CurrentWifiState = Get-CurrentWifiState }
    if (-not $VisibleNetworks) { $VisibleNetworks = Get-VisibleWifiNetworks | Where-Object { Test-TrustedNetwork -Ssid $_.SSID } }
    $visibleNetworks = @($VisibleNetworks)
    if (-not $visibleNetworks -or $visibleNetworks.Count -eq 0) { return @() }

    $currentSsid = if ($CurrentWifiState) { $CurrentWifiState.SSID } else { $null }
    $currentSignal = if ($CurrentWifiState) { $CurrentWifiState.Signal } else { 0 }

    $scored = foreach ($network in $visibleNetworks) {
        $name = [string]$network.SSID
        $signal = if ($null -ne $network.Signal) { [int]$network.Signal } else { 0 }
        $score = $signal
        if ($currentSsid -and $name -eq $currentSsid) { $score += 5 }
        if ($currentSsid -and $signal -ge ($currentSignal + 5)) { $score += 10 }
        [PSCustomObject]@{ SSID = $name; Signal = $signal; Score = $score }
    }

    return $scored | Sort-Object Score -Descending
}

function Connect-ToWifiNetwork {
    param([string]$Ssid)
    if (-not $Ssid) { return $false }
    netsh wlan connect name="$Ssid" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }
    netsh wlan connect ssid="$Ssid" name="$Ssid" 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Test-WifiSwitchNeeded {
    param(
        [string]$TargetSsid,
        [psobject]$CurrentWifiState,
        [array]$VisibleNetworks = $null
    )
    if (-not $TargetSsid) { return $false }
    if (-not (Test-TrustedNetwork -Ssid $TargetSsid)) { return $false }
    if (-not $CurrentWifiState -or -not $CurrentWifiState.SSID) { return $true }
    if ($TargetSsid -eq $CurrentWifiState.SSID) { return $false }
    if ($script:LastReconnectAt -and ((Get-Date) - $script:LastReconnectAt).TotalSeconds -lt $ReconnectCooldownSec) { return $false }

    $currentSignal = [int]$CurrentWifiState.Signal
    $targetSignal = 0
    if ($VisibleNetworks) {
        $targetNetwork = $VisibleNetworks | Where-Object { $_.SSID -eq $TargetSsid } | Select-Object -First 1
    }
    else {
        $targetNetwork = Get-VisibleWifiNetworks | Where-Object { $_.SSID -eq $TargetSsid } | Select-Object -First 1
    }
    if ($targetNetwork -and $null -ne $targetNetwork.Signal) { $targetSignal = [int]$targetNetwork.Signal }

    if ($targetSignal -ge ($currentSignal + 5)) { return $true }
    if ($targetSignal -ge 70 -and $currentSignal -lt 70) { return $true }
    return $false
}

function Restart-WifiConnection {
    if ($script:ReconnectInProgress) {
        Add-Log "Reconnect already in progress, skipping duplicate call"
        return $script:LastKnownSSID
    }

    try {
        $script:ReconnectInProgress = $true
        $currentWifiState = Get-CurrentWifiState
        $visibleNetworks = Get-VisibleWifiNetworks | Where-Object { Test-TrustedNetwork -Ssid $_.SSID }
        $targetSsid = Get-BestFreeNetwork -CurrentWifiState $currentWifiState -VisibleNetworks $visibleNetworks
        if (-not $targetSsid) { $targetSsid = $script:LastKnownSSID }
        if (-not $targetSsid) { $targetSsid = $currentWifiState.SSID }
        Add-Log "Restart-WifiConnection: current='$($currentWifiState.SSID)' ($($currentWifiState.Signal)%), target='$targetSsid'"
        if ($targetSsid -and -not (Test-WifiSwitchNeeded -TargetSsid $targetSsid -CurrentWifiState $currentWifiState -VisibleNetworks $visibleNetworks)) {
            Add-Log "Restart-WifiConnection: switch not needed/allowed right now (cooldown or same network), skipping."
            return $currentWifiState.SSID
        }

        Add-Log "Disconnecting current Wi-Fi connection..."
        netsh wlan disconnect 2>$null | Out-Null
        Start-Sleep -Seconds 2

        $candidates = Get-AllTrustedNetworksByScore -CurrentWifiState $currentWifiState -VisibleNetworks $visibleNetworks
        if ($candidates -and $candidates.Count -gt 0) {
            $connected = $false
            foreach ($candidate in $candidates) {
                Add-Log "Attempting to connect to '$($candidate.SSID)' (score $($candidate.Score))..."
                if (Connect-ToWifiNetwork -Ssid $candidate.SSID) {
                    Add-Log "Connected to '$($candidate.SSID)' successfully. Flushing DNS and resetting portal session."
                    Clear-DnsCache
                    $script:LastKnownSSID = $candidate.SSID
                    $script:LastReconnectAt = Get-Date
                    $script:PortalSession = $null
                    $script:PortalSessionCreatedAt = [DateTime]::MinValue
                    $connected = $true
                    break
                }
                Add-Log "Connect attempt to '$($candidate.SSID)' failed, trying next trusted network..."
            }

            if (-not $connected) {
                Add-Log "All trusted network connect attempts failed. Attempting DHCP release/renew before power-cycling adapter..."
                try {
                    ipconfig /release | Out-Null
                    Start-Sleep -Milliseconds 500
                    ipconfig /renew | Out-Null
                    Add-Log "DHCP release/renew completed. Retrying connection to best network..."
                    $bestRetry = Get-BestFreeNetwork -CurrentWifiState $currentWifiState -VisibleNetworks $visibleNetworks
                    if ($bestRetry -and (Connect-ToWifiNetwork -Ssid $bestRetry)) {
                        Add-Log "Connected to '$bestRetry' successfully after DHCP renew. Flushing DNS and resetting portal session."
                        Clear-DnsCache
                        $script:LastKnownSSID = $bestRetry
                        $script:LastReconnectAt = Get-Date
                        $script:PortalSession = $null
                        $script:PortalSessionCreatedAt = [DateTime]::MinValue
                        $connected = $true
                    }
                }
                catch {
                    Add-Log "DHCP release/renew failed: $($_.Exception.Message)"
                }

                if (-not $connected) {
                    Add-Log "DHCP renew did not restore connectivity. Falling back to power-cycling the adapter."
                    $adapter = Get-WifiAdapter
                    if ($adapter) {
                        Add-Log "Power-cycling adapter '$($adapter.Name)' ($($adapter.InterfaceDescription))..."
                        Disable-NetAdapter -Name $adapter.Name -Confirm:$false
                        Start-Sleep -Seconds 2
                        Enable-NetAdapter -Name $adapter.Name -Confirm:$false
                        Add-Log "Adapter '$($adapter.Name)' re-enabled."
                    }
                    else {
                        Add-Log "No Wi-Fi adapter found to power-cycle."
                    }
                }
            }
        }
        else {
            Add-Log "No target SSID available at all (not even a last-known one). Power-cycling adapter as a last resort."
            $adapter = Get-WifiAdapter
            if ($adapter) {
                Add-Log "Power-cycling adapter '$($adapter.Name)' ($($adapter.InterfaceDescription))..."
                Disable-NetAdapter -Name $adapter.Name -Confirm:$false
                Start-Sleep -Seconds 2
                Enable-NetAdapter -Name $adapter.Name -Confirm:$false
                Add-Log "Adapter '$($adapter.Name)' re-enabled."
            }
            else {
                Add-Log "No Wi-Fi adapter found to power-cycle."
            }
        }
        Start-Sleep -Seconds 3
        # Return the SSID we actually ended up on, not the originally-targeted one.
        # $script:LastKnownSSID is updated on every successful connect above.
        return if ($script:LastKnownSSID) { $script:LastKnownSSID } else { $targetSsid }
    }
    finally {
        $script:ReconnectInProgress = $false
    }
}

function Test-PortalSession {
    foreach ($testPage in $TestPageUrls) {
        try {
            $resp = $null
            if ($script:PortalSession) {
                if ($script:PortalSessionCreatedAt -ne [DateTime]::MinValue -and ((Get-Date) - $script:PortalSessionCreatedAt).TotalMinutes -ge 15) {
                    Add-Log "Portal session is stale (15+ minutes old). Clearing and creating fresh session."
                    $script:PortalSession = $null
                    $script:PortalSessionCreatedAt = [DateTime]::MinValue
                }
                else {
                    $resp = Invoke-WebRequestWithRetry -Uri $testPage.Url -Method Get -TimeoutSec 6 -MaxRetries 3 -WebSession $script:PortalSession -Headers @{ 'Cache-Control' = 'no-cache'; Pragma = 'no-cache' }
                }
            }
            if (-not $script:PortalSession) {
                $resp = Invoke-WebRequestWithRetry -Uri $testPage.Url -Method Get -TimeoutSec 6 -MaxRetries 3 -SessionVariable 'newSession' -Headers @{ 'Cache-Control' = 'no-cache'; Pragma = 'no-cache' }
                $script:PortalSession = $newSession
                $script:PortalSessionCreatedAt = Get-Date
            }
            if (-not $resp) {
                Add-Log "Portal connectivity check: No response received from $($testPage.Url)"
                continue
            }
            $content = $resp.Content.Trim()
            if ($content -eq $testPage.ExpectedText) { return 'Active' }
            $preview = $content.Substring(0, [Math]::Min(120, $content.Length)) -replace '[\r\n]+', ' '
            Add-Log "Portal check returned unexpected content from $($testPage.Url) (first 120 chars): $preview"
            return 'LoggedOut'
        }
        catch {
            Add-Log "Portal connectivity check failed for $($testPage.Url): $($_.Exception.Message) - trying next endpoint..."
            continue
        }
    }
    Add-Log "All portal connectivity check endpoints failed."
    return 'Unknown'
}

function Invoke-PortalLogin {
    $cred = Get-PortalCredential
    if (-not $cred) {
        Add-Log "Invoke-PortalLogin: No credentials available (Get-PortalCredential returned null)."
        throw "No credentials available"
    }
    $body = @{ dst = ""; popup = "true"; username = $cred.Username; password = $cred.Password }
    $loginUrls = @($LoginUrl, ($LoginUrl -replace '^https://', 'http://'))
    foreach ($url in $loginUrls) {
        try {
            if (-not $script:PortalSession) {
                $resp = Invoke-WebRequestWithRetry -Uri $url -Method Post -Body $body -TimeoutSec 10 -MaxRetries 3 -SessionVariable 'newSession' -Headers @{ 'Cache-Control' = 'no-cache'; Pragma = 'no-cache' }
                $script:PortalSession = $newSession
                $script:PortalSessionCreatedAt = Get-Date
            }
            else {
                $resp = Invoke-WebRequestWithRetry -Uri $url -Method Post -Body $body -TimeoutSec 10 -MaxRetries 3 -WebSession $script:PortalSession -Headers @{ 'Cache-Control' = 'no-cache'; Pragma = 'no-cache' }
            }
            $content = $resp.Content
            
            # Check for invalid credentials error - this is not retryable
            if ($content -match 'invalid username or password') {
                Add-Log "Portal rejected credentials: invalid username or password. Prompting for re-entry."
                throw "INVALID_CREDENTIALS"
            }
            
            # Check for traffic limit reached - this is not retryable
            if ($content -match 'traffic limit reached') {
                Add-Log "Portal reports traffic limit reached. Data allowance exhausted - reconnection will not resolve this."
                throw "TRAFFIC_LIMIT_REACHED"
            }
            
            if ($resp.BaseResponse.ResponseUri -match '/login' -or $content -match "Landmark University Hotspot Login" -or $content -match 'action="https://internet\.lmu\.edu\.ng/login"') {
                if ($url -eq $loginUrls[-1]) { throw "Portal login page returned after submitting credentials." }
                continue
            }
            if ($content -match 'already logged in|already login|logged in|connected') {
                return @{ Success = $true; AlreadyLoggedIn = $true; Url = $url }
            }
            return @{ Success = $true; AlreadyLoggedIn = $false; Url = $url }
        }
        catch {
            if ($url -like 'http://*') {
                Add-Log "WARNING: Portal login fell back to an unencrypted HTTP connection for this attempt."
            }
            if ($url -eq $loginUrls[-1]) { throw $_ }
        }
    }
    throw "Portal login failed: all URLs exhausted without a successful response."
}

function Invoke-PortalLogout {
    if (-not $script:PortalSession) { return $false }
    $logoutUrls = @($LogoutUrl, ($LogoutUrl -replace '^https://', 'http://'))
    foreach ($url in $logoutUrls) {
        try {
            Invoke-WebRequestWithRetry -Uri $url -Method Get -TimeoutSec 8 -MaxRetries 3 -WebSession $script:PortalSession -Headers @{ 'Cache-Control' = 'no-cache'; Pragma = 'no-cache' } | Out-Null
            $script:PortalSession = $null
            return $true
        }
        catch {
            if ($url -eq $logoutUrls[-1]) { return $false }
        }
    }
    return $false
}

# ---------- WPF UI Setup ----------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -Name Win32ForegroundHelper -Namespace NexLink -MemberDefinition '
[DllImport("user32.dll")]
public static extern bool AllowSetForegroundWindow(int dwProcessId);
'

# XAML for the main window
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="NexLink" 
        Width="360" Height="520"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen">
    <Border Name="MainBorder" Background="#0B0D13" CornerRadius="12" BorderBrush="#1F2937" BorderThickness="1">
        <Grid>
            <!-- Custom Title Bar -->
            <Grid Name="TitleBar" Height="40" VerticalAlignment="Top" Background="#14171F">
                <TextBlock Text="NexLink" FontFamily="Segoe UI" FontSize="14" FontWeight="SemiBold" 
                           Foreground="#F5F5F7" VerticalAlignment="Center" Margin="16,0,0,0"/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,0,8,0">
                    <Button Name="MinimizeBtn" Content="-" Width="30" Height="30" 
                            Background="Transparent" Foreground="#9CA3AF" 
                            BorderThickness="0" FontFamily="Segoe UI" FontSize="16"
                            Cursor="Hand"/>
                    <Button Name="CloseBtn" Width="30" Height="30"
                            Background="Transparent" Foreground="#9CA3AF"
                            BorderThickness="0" Cursor="Hand">
                        <Path Data="M18 6L6 18M6 6l12 12" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="2" Width="16" Height="16" Stretch="Uniform"/>
                    </Button>
                </StackPanel>
            </Grid>
            
            <!-- Status Orb with Pulse Animation -->
            <Ellipse Name="StatusOrb" Width="120" Height="120" 
                     Fill="#22D3AA" Stroke="#22D3AA" StrokeThickness="2"
                     VerticalAlignment="Top" Margin="0,60,0,0" HorizontalAlignment="Center">
                <Ellipse.Triggers>
                    <EventTrigger RoutedEvent="Ellipse.Loaded">
                        <BeginStoryboard>
                            <Storyboard RepeatBehavior="Forever" Name="PulseStoryboard">
                                <DoubleAnimation Storyboard.TargetProperty="(Ellipse.Opacity)"
                                               From="1.0" To="0.7" Duration="0:0:1.5"
                                               AutoReverse="True"/>
                            </Storyboard>
                        </BeginStoryboard>
                    </EventTrigger>
                </Ellipse.Triggers>
            </Ellipse>
            
            <!-- Status Text -->
            <TextBlock Name="StatusText" Text="Starting..." 
                       FontFamily="Segoe UI" FontSize="22" FontWeight="SemiBold"
                       Foreground="#F5F5F7" TextAlignment="Center"
                       VerticalAlignment="Top" Margin="0,200,0,0" HorizontalAlignment="Center"/>
            
            <!-- Network Name -->
            <TextBlock Name="NetworkName" Text="" 
                       FontFamily="Segoe UI" FontSize="12" FontWeight="Regular"
                       Foreground="#9CA3AF" TextAlignment="Center"
                       VerticalAlignment="Top" Margin="0,240,0,0" HorizontalAlignment="Center"/>
            
            <!-- Primary Action Button -->
            <Button Name="ActionButton" Content="Disconnect" 
                    Width="200" Height="44" 
                    FontFamily="Segoe UI" FontSize="14" FontWeight="SemiBold"
                    Foreground="#FFFFFF" 
                    VerticalAlignment="Top" Margin="0,300,0,0" HorizontalAlignment="Center"
                    Cursor="Hand">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border Name="ButtonBorder" Background="#7C3AED" CornerRadius="22" BorderThickness="0">
                            <Border.Background>
                                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                    <GradientStop Color="#7C3AED" Offset="0"/>
                                    <GradientStop Color="#06B6D4" Offset="1"/>
                                </LinearGradientBrush>
                            </Border.Background>
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Button.Template>
            </Button>
            
            <!-- Update banner - hidden unless an update is actually found -->
            <Border Name="UpdateBanner" Background="#14171F" CornerRadius="10"
                    VerticalAlignment="Bottom" Margin="16,0,16,44" Padding="10,8"
                    Visibility="Collapsed" BorderBrush="#06B6D4" BorderThickness="1">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Name="UpdateBannerText" Grid.Column="0" Text="Update available"
                               FontFamily="Segoe UI" FontSize="11" Foreground="#F5F5F7"
                               VerticalAlignment="Center" TextWrapping="Wrap"/>
                    <Button Name="UpdateRestartBtn" Grid.Column="1" Content="Restart to Update"
                            FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold"
                            Background="#06B6D4" Foreground="White" BorderThickness="0"
                            Padding="8,4" Cursor="Hand" Margin="8,0,0,0"/>
                </Grid>
            </Border>

            <!-- Footer -->
            <Grid Height="30" VerticalAlignment="Bottom" Margin="16,0,16,8">
                <TextBlock Name="VersionText" Text="v1.3.0" 
                           FontFamily="Segoe UI" FontSize="10" 
                           Foreground="#6B7280" VerticalAlignment="Center" HorizontalAlignment="Left"/>
                <Button Name="SettingsBtn" Width="24" Height="24"
                        Background="Transparent" Foreground="#6B7280"
                        BorderThickness="0" Cursor="Hand" HorizontalAlignment="Right" VerticalAlignment="Center">
                    <Path Data="M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="2" Width="16" Height="16" Stretch="Uniform"/>
                </Button>
            </Grid>
        </Grid>
    </Border>
</Window>
"@

# Parse XAML
$stringReader = [System.IO.StringReader]::new($xaml)
$reader = [System.Xml.XmlReader]::Create($stringReader)
try {
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
}
finally {
    $reader.Close()
    $stringReader.Dispose()
}

# Get UI elements
$statusOrb = $window.FindName("StatusOrb")
$statusText = $window.FindName("StatusText")
$networkName = $window.FindName("NetworkName")
$actionButton = $window.FindName("ActionButton")
$settingsBtn = $window.FindName("SettingsBtn")
$updateBanner = $window.FindName("UpdateBanner")
$updateBannerText = $window.FindName("UpdateBannerText")
$updateRestartBtn = $window.FindName("UpdateRestartBtn")
$versionText = $window.FindName("VersionText")
$versionText.Text = "v$NexLinkVersion"
$minimizeBtn = $window.FindName("MinimizeBtn")
$closeBtn = $window.FindName("CloseBtn")
$pulseStoryboard = $window.FindName("PulseStoryboard")

# Window dragging (manual implementation to avoid lag)
$script:isDragging = $false
$script:dragStartPoint = $null

$window.Add_MouseLeftButtonDown({
    $script:isDragging = $true
    $script:dragStartPoint = [System.Windows.Point]::new($_.GetPosition($this).X, $_.GetPosition($this).Y)
    $this.CaptureMouse()
})

$window.Add_MouseLeftButtonUp({
    $script:isDragging = $false
    $this.ReleaseMouseCapture()
})

$window.Add_MouseMove({
    if ($script:isDragging) {
        if (-not $script:dragStartPoint) { return }
        $currentPoint = $_.GetPosition($this)
        $deltaX = $currentPoint.X - $script:dragStartPoint.X
        $deltaY = $currentPoint.Y - $script:dragStartPoint.Y
        $this.Left += $deltaX
        $this.Top += $deltaY
    }
})

# Close button - behaves like minimize (sends to tray), matching standard
# background-app convention (Discord, Spotify, etc). Real exit only via the
# tray icon's right-click "Exit" menu item below.
$closeBtn.Add_Click({
    try {
        $window.WindowState = [System.Windows.WindowState]::Minimized
        $window.Hide()
        $trayIcon.ShowBalloonTip(2500, "NexLink", "Still running - look for this icon in your system tray (click the ^ arrow if you don't see it).", [System.Windows.Forms.ToolTipIcon]::Info)
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] closeBtn.Add_Click: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

# Minimize button
$minimizeBtn.Add_Click({
    try {
        $window.WindowState = [System.Windows.WindowState]::Minimized
        $window.Hide()
        $trayIcon.ShowBalloonTip(2500, "NexLink", "Still running - look for this icon in your system tray (click the ^ arrow if you don't see it).", [System.Windows.Forms.ToolTipIcon]::Info)
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] minimizeBtn.Add_Click: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

# ---------- Logging Functions ----------
$script:logLines = @()
$script:LogLock = New-Object Object
$script:LogWriteCounter = 0
$script:MaxLogSizeBytes = 5MB

function Add-Log($text) {
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $line = "[$timestamp] $text"
    [System.Threading.Monitor]::Enter($script:LogLock)
    try {
        $script:logLines += $line
    }
    finally {
        [System.Threading.Monitor]::Exit($script:LogLock)
    }
    
    # Check log size every 100th write to avoid disk I/O on hot path
    $script:LogWriteCounter++
    if ($script:LogWriteCounter -ge 100) {
        $script:LogWriteCounter = 0
        try {
            if (Test-Path $LogFile) {
                $fileSize = (Get-Item $LogFile -ErrorAction SilentlyContinue).Length
                if ($fileSize -gt $script:MaxLogSizeBytes) {
                    # Safe rotation: read -> write temp -> replace
                    try {
                        $content = Get-Content -Path $LogFile -ErrorAction Stop
                        # Keep last 80% of lines when exceeding 5MB to preserve most history
                        # This maintains ~86 hours of history at 5MB cap (not just 5000 lines)
                        $keepCount = [Math]::Max(5000, [Math]::Floor($content.Count * 0.8))
                        $linesToKeep = $content[-$keepCount..-1]
                        $tempFile = $LogFile + ".tmp"
                        $rotationLine = "[$(Get-Date -Format 'HH:mm:ss')] [LOG ROTATED] Previous entries truncated - log exceeded 5MB"
                        $linesToKeep = @($rotationLine) + $linesToKeep
                        Set-Content -Path $tempFile -Value $linesToKeep -Encoding UTF8 -ErrorAction Stop
                        Move-Item -Path $tempFile -Destination $LogFile -Force -ErrorAction Stop
                    }
                    catch {
                        # If rotation fails, skip this cycle and try again next time
                        # Log nothing to avoid infinite loop on log failure
                    }
                }
            }
        }
        catch {
            # Silently fail size check - don't block normal logging
        }
    }
    
    try {
        $logDir = Split-Path -Parent $LogFile
        if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    }
    catch {}
}

function Limit-LogFile {
    try {
        if (-not (Test-Path $LogFile)) { return }
        $lines = Get-Content -Path $LogFile -ErrorAction SilentlyContinue
        if ($lines -and $lines.Count -gt ($MaxLogLines * 2)) {
            $trimmed = $lines[-$MaxLogLines..-1]
            Set-Content -Path $LogFile -Value $trimmed -Encoding UTF8
        }
        # Also trim in-memory array to prevent unbounded growth.
        # Use the same lock as Add-Log to prevent a race with background-thread callers.
        [System.Threading.Monitor]::Enter($script:LogLock)
        try {
            if ($script:logLines.Count -gt ($MaxLogLines * 2)) {
                $script:logLines = $script:logLines[-$MaxLogLines..-1]
            }
        }
        finally {
            [System.Threading.Monitor]::Exit($script:LogLock)
        }
    }
    catch {}
}

# ---------- Pro License Functions ----------
# Embedded ECDSA public key for license verification (safe to expose)
# This is the public key corresponding to the private key in the Cloudflare Worker
# MANUAL ACTION REQUIRED: After generating ECDSA keys, replace the placeholder values below
# with the actual x and y coordinates from ecdsa_public_key.json
$script:ProPublicKey = @{
    curve = "P-256"
    x = "wysF6y9aP0lNP193gRQA8udaNffqT4UKjecDw0SyLbk="
    y = "zpMEBAovSc0ANwby8/vR6nOID6p58omnqFqmDqFUzVM="
}

$script:ProLicenseFile = Join-Path $ScriptDir "nexlink_pro_license.cred"
$script:IsProLicensed = $false

function Get-MachineFingerprint {
    try {
        $guid = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
    }
    catch {
        # Registry key inaccessible for some reason - fall back to CIM, then hostname
        try {
            $guid = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop).UUID
        }
        catch {
            $guid = $env:COMPUTERNAME
        }
    }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$guid)
    $hashBytes = $sha256.ComputeHash($bytes)
    $sha256.Dispose()
    return [Convert]::ToBase64String($hashBytes)
}

function Invoke-LicenseActivation($licenseKey) {
    $activateUrl = "https://nexlink-license.highnine699.workers.dev/activate"
    $machineHash = Get-MachineFingerprint
    $body = @{ licenseKey = $licenseKey; machineHash = $machineHash } | ConvertTo-Json -Compress

    try {
        $resp = Invoke-WebRequestWithRetry -Uri $activateUrl -Method Post -Body $body -ContentType "application/json" -TimeoutSec 10 -MaxRetries 3
        $respData = $resp.Content | ConvertFrom-Json
        if (-not $respData.deviceToken) {
            Add-Log "Activation succeeded but server did not return a device token - rejecting."
            return @{ Success = $false; Reason = "NoDeviceToken" }
        }
        return @{ Success = $true; MachineHash = $machineHash; DeviceToken = $respData.deviceToken }
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
        }
        if ($statusCode -eq 409) {
            Add-Log "License activation rejected: this key is already active on another device."
            return @{ Success = $false; Reason = "AlreadyActivated" }
        }
        Add-Log "License activation could not reach the server: $($_.Exception.Message)"
        return @{ Success = $false; Reason = "NetworkError" }
    }
}

function Get-ProLicense {
    try {
        if (-not (Test-Path $script:ProLicenseFile)) { return $null }
        $encrypted = (Get-Content -Path $script:ProLicenseFile -Raw -ErrorAction Stop).Trim()
        $secure = ConvertTo-SecureString $encrypted
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $payload = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        return $payload | ConvertFrom-Json
    }
    catch {
        Add-Log "Pro license file could not be read/decrypted (may be from a different user/machine): $($_.Exception.Message)"
        return $null
    }
}

function Save-ProLicense($licenseKey, $machineHash, $deviceToken) {
    try {
        $payload = @{ LicenseKey = $licenseKey; MachineHash = $machineHash; DeviceToken = $deviceToken } | ConvertTo-Json -Compress
        $secure = ConvertTo-SecureString $payload -AsPlainText -Force
        $encrypted = ConvertFrom-SecureString $secure
        Set-Content -Path $script:ProLicenseFile -Value $encrypted -Encoding UTF8 -Force -NoNewline
        return $true
    }
    catch {
        Add-Log "Failed to save Pro license: $($_.Exception.Message)"
        return $false
    }
}

function Verify-ProLicense($licenseKey) {
    if (-not $licenseKey -or $licenseKey.Trim() -eq "") { return $false }
    $parts = $licenseKey.Trim().Split(".")
    if ($parts.Count -ne 2) { return $false }

    try {
        $referenceBytes = [Convert]::FromBase64String($parts[0])
        $signatureBytes = [Convert]::FromBase64String($parts[1])
        $reference = [System.Text.Encoding]::UTF8.GetString($referenceBytes)

        $X = [Convert]::FromBase64String($script:ProPublicKey.x)
        $Y = [Convert]::FromBase64String($script:ProPublicKey.y)
        $magicBytes = [BitConverter]::GetBytes([UInt32]0x31534345)
        $keySizeBytes = [BitConverter]::GetBytes([UInt32]32)
        $blob = $magicBytes + $keySizeBytes + $X + $Y

        $cngKey = [System.Security.Cryptography.CngKey]::Import($blob, [System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
        $ecdsa = New-Object System.Security.Cryptography.ECDsaCng($cngKey)

        $messageBytes = [System.Text.Encoding]::UTF8.GetBytes($reference)
        $isValid = $ecdsa.VerifyData($messageBytes, $signatureBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $ecdsa.Dispose()
        $cngKey.Dispose()

        if ($isValid) {
            Add-Log "License verified for reference: $reference"
        }
        return $isValid
    }
    catch {
        Add-Log "License verification error: $($_.Exception.Message)"
        return $false
    }
}

function Verify-DeviceToken($reference, $machineHash, $deviceTokenB64) {
    if (-not $deviceTokenB64 -or $deviceTokenB64.Trim() -eq "") { return $false }
    try {
        $message = "$reference" + ":" + "$machineHash"
        $messageBytes = [System.Text.Encoding]::UTF8.GetBytes($message)
        $signatureBytes = [Convert]::FromBase64String($deviceTokenB64)

        $X = [Convert]::FromBase64String($script:ProPublicKey.x)
        $Y = [Convert]::FromBase64String($script:ProPublicKey.y)
        $magicBytes = [BitConverter]::GetBytes([UInt32]0x31534345)
        $keySizeBytes = [BitConverter]::GetBytes([UInt32]32)
        $blob = $magicBytes + $keySizeBytes + $X + $Y

        $cngKey = [System.Security.Cryptography.CngKey]::Import($blob, [System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
        $ecdsa = New-Object System.Security.Cryptography.ECDsaCng($cngKey)
        $isValid = $ecdsa.VerifyData($messageBytes, $signatureBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $ecdsa.Dispose()
        $cngKey.Dispose()
        return $isValid
    }
    catch {
        Add-Log "Device token verification error: $($_.Exception.Message)"
        return $false
    }
}

function Show-LicenseInputDialog {
    $licenseKey = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Enter your NexLink Pro license key:",
        "NexLink Pro License",
        "",
        -1, -1
    )

    if ($licenseKey -and $licenseKey.Trim() -ne "") {
        $licenseKey = $licenseKey.Trim()
        if (Verify-ProLicense $licenseKey) {
            $activation = Invoke-LicenseActivation $licenseKey
            if ($activation.Success) {
                if (Save-ProLicense $licenseKey $activation.MachineHash $activation.DeviceToken) {
                    $script:IsProLicensed = $true
                    Add-Log "Pro license activated successfully on this device."
                    [System.Windows.Forms.MessageBox]::Show("Pro license activated successfully!", "NexLink Pro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
                }
                else {
                    Add-Log "Failed to save Pro license locally."
                    [System.Windows.Forms.MessageBox]::Show("License verified but could not be saved locally. Try again.", "NexLink Pro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                }
            }
            elseif ($activation.Reason -eq "AlreadyActivated") {
                [System.Windows.Forms.MessageBox]::Show("This license key is already active on another device. Each purchase is valid for one device. If you believe this is an error, contact support.", "NexLink Pro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            }
            else {
                [System.Windows.Forms.MessageBox]::Show("Could not reach the activation server. Check your internet connection and try again.", "NexLink Pro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            }
        }
        else {
            Add-Log "Invalid Pro license key provided."
            [System.Windows.Forms.MessageBox]::Show("Invalid license key. Please check and try again.", "NexLink Pro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }
}

# Check for existing Pro license on startup
try {
    $savedLicense = Get-ProLicense
    if ($savedLicense -and (Verify-ProLicense $savedLicense.LicenseKey)) {
        try {
            $currentMachineHash = Get-MachineFingerprint
            $referenceBytesForCheck = [Convert]::FromBase64String($savedLicense.LicenseKey.Split(".")[0])
            $referenceForCheck = [System.Text.Encoding]::UTF8.GetString($referenceBytesForCheck)
            if (Verify-DeviceToken $referenceForCheck $currentMachineHash $savedLicense.DeviceToken) {
                $script:IsProLicensed = $true
                Add-Log "Pro license detected and valid for this device."
            }
            else {
                Add-Log "Pro license found but it's bound to a different device (or predates device-token verification) - Pro features disabled here. Re-activate to restore."
            }
        }
        catch {
            Add-Log "Startup license check failed unexpectedly: $($_.Exception.Message)"
        }
    }
}
catch {
    Add-Log "Startup license check failed (license file may be corrupt or unreadable): $($_.Exception.Message)"
}

# Theme definitions
$script:Themes = @{
    "Cyberpunk" = @{
        Background = "#0B0D13"
        TitleBar = "#14171F"
        AccentStart = "#7C3AED"
        AccentEnd = "#06B6D4"
        StatusConnected = "#22D3AA"
        StatusReconnecting = "#FBBF24"
        StatusError = "#F43F5E"
        StatusOffline = "#6B7280"
    }
    "Sunset" = @{
        Background = "#1A1414"
        TitleBar = "#2D1F1F"
        AccentStart = "#F97316"
        AccentEnd = "#EC4899"
        StatusConnected = "#22D3AA"
        StatusReconnecting = "#FBBF24"
        StatusError = "#F43F5E"
        StatusOffline = "#6B7280"
    }
    "Midnight" = @{
        Background = "#0F172A"
        TitleBar = "#1E293B"
        AccentStart = "#3B82F6"
        AccentEnd = "#6366F1"
        StatusConnected = "#22D3AA"
        StatusReconnecting = "#FBBF24"
        StatusError = "#F43F5E"
        StatusOffline = "#6B7280"
    }
}

$script:CurrentTheme = "Cyberpunk"
$script:ThemeFile = Join-Path $ScriptDir "nexlink_theme.txt"

# Load saved theme preference
if (Test-Path $script:ThemeFile) {
    $savedTheme = Get-Content $script:ThemeFile -ErrorAction SilentlyContinue
    if ($script:Themes.ContainsKey($savedTheme)) {
        $script:CurrentTheme = $savedTheme
    }
}

function Show-ThemePickerDialog {
    $themeForm = New-Object System.Windows.Forms.Form
    $themeForm.Text = "Choose Theme"
    $themeForm.Width = 300
    $themeForm.Height = 200
    $themeForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $themeForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $themeForm.MaximizeBox = $false
    $themeForm.MinimizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Select a theme:"
    $label.Location = New-Object System.Drawing.Point(20, 20)
    $label.AutoSize = $true
    $themeForm.Controls.Add($label)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Location = New-Object System.Drawing.Point(20, 50)
    $combo.Width = 240
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    foreach ($themeName in $script:Themes.Keys) {
        $combo.Items.Add($themeName) | Out-Null
    }
    $combo.SelectedIndex = [Array]::IndexOf($script:Themes.Keys, $script:CurrentTheme)
    $themeForm.Controls.Add($combo)

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = "Apply"
    $okBtn.Location = New-Object System.Drawing.Point(20, 90)
    $okBtn.Width = 100
    $okBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $themeForm.Controls.Add($okBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Location = New-Object System.Drawing.Point(140, 90)
    $cancelBtn.Width = 100
    $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $themeForm.Controls.Add($cancelBtn)

    $result = $themeForm.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        $selectedTheme = $combo.SelectedItem
        Apply-Theme $selectedTheme
        $script:CurrentTheme = $selectedTheme
        $selectedTheme | Out-File $script:ThemeFile -Encoding UTF8
        Add-Log "Theme changed to: $selectedTheme"
    }

    $themeForm.Dispose()
}

function Apply-Theme($themeName) {
    $theme = $script:Themes[$themeName]
    if (-not $theme) { return }

    # Update main window background
    $mainBorder = $window.FindName("MainBorder")
    if ($mainBorder) {
        $mainBorder.Background = $theme.Background
    }

    # Update title bar background
    $titleBar = $window.FindName("TitleBar")
    if ($titleBar) {
        $titleBar.Background = $theme.TitleBar
    }

    # Update action button gradient by recreating the template
    $actionButton = $window.FindName("ActionButton")
    if ($actionButton) {
        $newTemplate = @'
<ControlTemplate TargetType="Button" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
    <Border Name="ButtonBorder" CornerRadius="22" BorderThickness="0">
        <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                <GradientStop Color="ACCENT_START" Offset="0"/>
                <GradientStop Color="ACCENT_END" Offset="1"/>
            </LinearGradientBrush>
        </Border.Background>
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
</ControlTemplate>
'@
        $newTemplate = $newTemplate -replace "ACCENT_START", $theme.AccentStart
        $newTemplate = $newTemplate -replace "ACCENT_END", $theme.AccentEnd
        
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($newTemplate))
        try {
            $actionButton.Template = [System.Windows.Markup.XamlReader]::Load($reader)
        }
        finally {
            $reader.Dispose()
        }
    }

    # Update update banner
    $updateBanner = $window.FindName("UpdateBanner")
    if ($updateBanner) {
        $updateBanner.Background = $theme.TitleBar
    }

    # Trigger status update to refresh orb colors with new theme
    $statusText = $window.FindName("StatusText")
    if ($statusText) {
        Set-Status $statusText.Text "default"
    }
}

# ---------- Status Update Function ----------
function Set-Status($text, $state) {
    $statusText.Text = $text
    $trayIcon.Text = "NexLink: $text"
    
    # Get current theme colors
    $theme = $script:Themes[$script:CurrentTheme]
    if (-not $theme) { $theme = $script:Themes["Cyberpunk"] }
    
    # Update orb color and animation based on state using theme colors
    switch ($state) {
        "Connected" {
            $statusOrb.Fill = $theme.StatusConnected
            $statusOrb.Stroke = $theme.StatusConnected
            if ($pulseStoryboard) { try { $pulseStoryboard.Begin() } catch {} }
        }
        "Reconnecting" {
            $statusOrb.Fill = $theme.StatusReconnecting
            $statusOrb.Stroke = $theme.StatusReconnecting
            if ($pulseStoryboard) { try { $pulseStoryboard.Begin() } catch {} }
        }
        "Error" {
            $statusOrb.Fill = $theme.StatusError
            $statusOrb.Stroke = $theme.StatusError
            if ($pulseStoryboard) { try { $pulseStoryboard.Stop() } catch {} }
        }
        default {
            $statusOrb.Fill = $theme.StatusOffline
            $statusOrb.Stroke = $theme.StatusOffline
            if ($pulseStoryboard) { try { $pulseStoryboard.Stop() } catch {} }
        }
    }
}

# ---------- Manual Disconnect/Reconnect ----------
$script:ManuallyDisconnected = $false

function Disconnect-Manually {
    $timer.Stop()
    Set-Status "Logging out..." "Reconnecting"
    $loggedOut = Invoke-PortalLogout
    if ($loggedOut) {
        Add-Log "Portal session logged out."
    }
    else {
        Add-Log "Portal logout could not be confirmed (already logged out, or no active session)."
    }
    netsh wlan disconnect 2>$null | Out-Null
    $script:ManuallyDisconnected = $true
    $actionButton.Content = "Reconnect Now"
    Set-Status "Disconnected" "Error"
    Add-Log "Manually disconnected. Auto-reconnect is paused until you click Reconnect."
}

function Reconnect-Manually {
    $script:ManuallyDisconnected = $false
    $actionButton.Content = "Disconnect"
    Add-Log "Manual reconnect requested."
    Set-Status "Reconnecting..." "Reconnecting"
    Restart-WifiConnection | Out-Null
    $script:wifiFailCount = 0
    $script:portalFailCount = 0
    $timer.Interval = [TimeSpan]::FromMilliseconds($CheckIntervalMs)
    $timer.Start()
}

$actionButton.Add_Click({
    try {
        if ($script:ManuallyDisconnected) {
            Reconnect-Manually
        }
        else {
            Disconnect-Manually
        }
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] actionButton.Add_Click: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

# ---------- System Tray (Hybrid: WPF + WinForms) ----------
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$iconPath = Join-Path $ScriptDir "wifi_icon.ico"
if (Test-Path $iconPath) {
    $trayIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconPath)
} else {
    $trayIcon.Icon = [System.Drawing.SystemIcons]::Application
}
$trayIcon.Text = "NexLink v$NexLinkVersion Monitor"
$trayIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuShow = $trayMenu.Items.Add("Show Window")
$menuDisconnect = $trayMenu.Items.Add("Disconnect")
$menuBoost = $trayMenu.Items.Add("Boost WiFi Performance")
$trayMenu.Items.Add("-") | Out-Null
$menuExit = $trayMenu.Items.Add("Exit")
$trayIcon.ContextMenuStrip = $trayMenu

$script:allowExit = $false

$menuShow.Add_Click({ 
    try {
        $window.Show(); 
        $window.WindowState = "Normal"; 
        $window.Activate() 
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] menuShow.Add_Click: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})
$trayIcon.Add_DoubleClick({ 
    try {
        $window.Show(); 
        $window.WindowState = "Normal"; 
        $window.Activate() 
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] trayIcon.Add_DoubleClick: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

$trayMenu.Add_Opening({
    try {
        $menuDisconnect.Text = if ($script:ManuallyDisconnected) { "Reconnect" } else { "Disconnect" }
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] trayMenu.Add_Opening: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

$menuDisconnect.Add_Click({
    try {
        if ($script:ManuallyDisconnected) {
            Reconnect-Manually
        }
        else {
            Disconnect-Manually
        }
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] menuDisconnect.Add_Click: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

$menuBoost.Add_Click({
    try {
        Add-Log "Boost WiFi Performance triggered via tray menu."
        $result = Set-MaxWiFiPerformance
        Add-Log "Boost WiFi Performance result: PowerSavingDisabled=$($result.PowerSavingDisabled), TcpAutotuning=$($result.TcpAutotuning), BufferTuning=$($result.BufferTuning.Count) properties tuned."
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] menuBoost.Add_Click: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

function Invoke-GracefulExit {
    $script:allowExit = $true
    Add-Log "===== Session ending (tray exit) ====="
    $timer.Stop()
    $trayIcon.Visible = $false
    try { Unregister-Event -SourceIdentifier $powerModeChangedHandler.Name -ErrorAction SilentlyContinue } catch {}
    try { [System.Net.NetworkInformation.NetworkChange]::remove_NetworkAddressChanged($script:NetworkAddressChangedHandler) } catch {}
    try { $script:InstanceMutex.ReleaseMutex() } catch {}
    Remove-Item $script:ExitSignalFile -ErrorAction SilentlyContinue
    $window.Close()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
}

$menuExit.Add_Click({
    try {
        Invoke-GracefulExit
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] menuExit.Add_Click: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

# ---------- Timer-driven check loop ----------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds($CheckIntervalMs)

# Debounce state for NetworkAddressChanged (prevents duplicate checks during a single roam event)
$script:LastNetworkChangeCheckAt = [DateTime]::MinValue
$script:NetworkChangeDebounceSec = 2

# Shared immediate-check function used by both PowerModeChanged and NetworkAddressChanged handlers.
# Marshals back onto the WPF Dispatcher thread and sets a 1ms timer interval so the tick fires
# on the very next dispatcher frame instead of waiting up to $CheckIntervalMs.
function Invoke-ImmediateConnectivityCheck {
    Add-Log "Immediate connectivity check triggered (network or power event)."
    $window.Dispatcher.BeginInvoke([Action]{
        $timer.Stop()
        $timer.Interval = [TimeSpan]::FromMilliseconds(1)
        $timer.Start()
    })
}

# Power mode change event handler - fires an immediate check on wake from sleep.
$powerModeChangedHandler = Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName "PowerModeChanged" -Action {
    try {
        if ($EventArgs.Mode -eq [Microsoft.Win32.PowerModes]::Resume) {
            Add-Log "System resumed from sleep."
            # Auto-enable Wi-Fi adapter if it's disabled after wake
            Enable-WifiAdapterIfDisabled | Out-Null
            Invoke-ImmediateConnectivityCheck
        }
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] PowerModeChanged: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
}

# Network address change handler - fires an immediate check when the SSID, IP address,
# or adapter state changes (e.g. roaming between APs while walking between buildings).
# The debounce prevents the same physical roam event from triggering the check 2-3 times
# in rapid succession (IP release -> IP acquire -> adapter settle all fire this event).
$script:NetworkAddressChangedHandler = {
    try {
        if (((Get-Date) - $script:LastNetworkChangeCheckAt).TotalSeconds -lt $script:NetworkChangeDebounceSec) {
            return
        }
        $script:LastNetworkChangeCheckAt = Get-Date
        Add-Log "Network address change detected (SSID/IP/adapter change)."
        Invoke-ImmediateConnectivityCheck
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] NetworkAddressChanged: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
}
[System.Net.NetworkInformation.NetworkChange]::add_NetworkAddressChanged($script:NetworkAddressChangedHandler)

$timer.Add_Tick({
    if (Test-Path $script:ExitSignalFile) {
        Invoke-GracefulExit
        return
    }
    if ($script:ManuallyDisconnected) { return }
    if (((Get-Date) - $script:LastLogTrimAt).TotalHours -ge 1) {
        Limit-LogFile
        $script:LastLogTrimAt = Get-Date
    }
    if (-not $script:PendingUpdateManifest -and ((Get-Date) - $script:LastUpdateCheckAt).TotalHours -ge 24) {
        $script:LastUpdateCheckAt = Get-Date
        $foundUpdate = Test-ForUpdate
        if ($foundUpdate) {
            $script:PendingUpdateManifest = $foundUpdate
            $updateBannerText.Text = "v$($foundUpdate.version) is available"
            $updateBanner.Visibility = [System.Windows.Visibility]::Visible
        }
    }
    # Heartbeat: log every 5 minutes to bound crash time if app dies silently
    if ($script:LastHeartbeatAt -eq [DateTime]::MinValue -or ((Get-Date) - $script:LastHeartbeatAt).TotalMinutes -ge 5) {
        $uptime = (Get-Date) - $script:StartTime
        $uptimeStr = "$([math]::Floor($uptime.TotalHours))h $([math]::Floor($uptime.Minutes))m"
        Add-Log "[HEARTBEAT] Still running, uptime=$uptimeStr"
        $script:LastHeartbeatAt = Get-Date
    }
    try {
        $currentWifiState = Get-CurrentWifiState
        $targetSsid = Get-BestFreeNetwork -CurrentWifiState $currentWifiState
        if (Test-WifiSwitchNeeded -TargetSsid $targetSsid -CurrentWifiState $currentWifiState) {
            Add-Log "Better Wi-Fi available ('$targetSsid'). Switching now."
            Set-Status "Switching Wi-Fi..." "Reconnecting"
            Restart-WifiConnection | Out-Null
            $script:wifiFailCount = 0
            $script:portalFailCount = 0
            $currentWifiState = Get-CurrentWifiState
        }

        $pingOk = $false
        foreach ($target in $PingTargets) {
            if (Test-Connection -ComputerName $target -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                $pingOk = $true
                break
            }
        }

        if ($pingOk) {
            if ($script:wifiFailCount -gt 0) {
                Add-Log "Ping recovered after $script:wifiFailCount failure(s)."
            }
            $script:wifiFailCount = 0
            Update-KnownSSID | Out-Null
        }
        else {
            $script:wifiFailCount++
            Add-Log "Ping failed ($script:wifiFailCount/$WifiFailsBeforeFix) - targets=$($PingTargets -join ', ')"
            Set-Status "Fixing your connection..." "Reconnecting"
        }

        $portalStatus = Test-PortalSession
        Add-Log "[Check] Ping=$(if ($pingOk) {'OK'} else {'FAIL'}) Portal=$portalStatus SSID='$($currentWifiState.SSID)' Signal=$($currentWifiState.Signal)% Interval=$($timer.Interval.TotalMilliseconds)ms"
        
        if ($portalStatus -eq 'LoggedOut') {
            $now = Get-Date
            if ($script:PortalRetryAfter -gt $now) {
                if (-not $script:PortalCooldownShown) {
                    $remaining = [Math]::Ceiling(($script:PortalRetryAfter - $now).TotalSeconds)
                    Add-Log "Portal still appears logged out. Waiting $remaining seconds before retrying"
                    $script:PortalCooldownShown = $true
                }
            }
            else {
                $script:PortalCooldownShown = $false
                Set-Status "Logging into portal..." "Reconnecting"
                Add-Log "Portal session inactive - logging back in"
                try {
                    $result = Invoke-PortalLogin
                    Clear-DnsCache
                    Add-Log "Portal login submitted via '$($result.Url)' (AlreadyLoggedIn=$($result.AlreadyLoggedIn))"
                    $script:portalFailCount = 0
                    $script:wifiFailCount = 0
                    $script:portalUnknownCount = 0
                    $script:PortalRetryAfter = [DateTime]::MinValue
                }
                catch {
                    # Check for invalid credentials specifically
                    if ($_.Exception.Message -eq 'INVALID_CREDENTIALS') {
                        Add-Log "Invalid credentials detected - prompting for re-entry."
                        Set-Status "Invalid credentials - please re-enter" "Error"
                        # Trigger credential re-entry flow
                        if (Save-PortalCredential) {
                            $script:PortalSession = $null
                            $script:PortalSessionCreatedAt = [DateTime]::MinValue
                            Add-Log "Credentials updated. Will retry login on next check."
                        }
                        else {
                            Add-Log "Credential re-entry was cancelled by user."
                        }
                        $script:portalFailCount = 0
                        $script:PortalRetryAfter = [DateTime]::MinValue
                    }
                    # Check for traffic limit reached - not retryable by app
                    elseif ($_.Exception.Message -eq 'TRAFFIC_LIMIT_REACHED') {
                        Add-Log "Traffic limit reached. Data allowance exhausted - reconnection will not resolve this."
                        Set-Status "Data limit reached" "Error"
                        # Set long cooldown (30 minutes) - traffic limits typically reset on a schedule
                        $script:PortalRetryAfter = $now.AddMinutes(30)
                        $script:portalFailCount = 0
                        Add-Log "Will re-check portal status in 30 minutes."
                    }
                    else {
                        # Normal retry logic for other failures
                        $script:portalFailCount++
                        $cooldownSeconds = [Math]::Min($PortalLoginRetryCooldownSec, 10 + ($script:portalFailCount * 5))
                        $script:PortalRetryAfter = $now.AddSeconds($cooldownSeconds)
                        Add-Log "Portal login FAILED ($script:portalFailCount). Retrying in $cooldownSeconds seconds: $($_.Exception.Message)"
                        Set-Status "Portal login error" "Error"
                    }
                }
            }
        }
        elseif ($portalStatus -eq 'Active') {
            $script:wifiFailCount = 0
            $script:portalFailCount = 0
            $script:portalUnknownCount = 0
            $script:PortalRetryAfter = [DateTime]::MinValue
            $script:PortalCooldownShown = $false
        }
        else {
            # 'Unknown' - can't even reach the connectivity-check endpoint.
            # Ping alone succeeding doesn't mean much if this keeps failing;
            # some networks allow ICMP but throttle/block specific HTTP
            # endpoints. Escalate after repeated Unknowns instead of waiting
            # forever with no action.
            $script:portalUnknownCount++
            Add-Log "Portal status Unknown ($script:portalUnknownCount/$WifiFailsBeforeFix) - can't reach connectivity-check endpoint"
            $script:PortalRetryAfter = [DateTime]::MinValue
            $script:PortalCooldownShown = $false
        }

        if ($script:wifiFailCount -ge $WifiFailsBeforeFix -or $script:portalFailCount -ge $WifiFailsBeforeFix -or $script:portalUnknownCount -ge $WifiFailsBeforeFix) {
            Set-Status "Reconnecting..." "Reconnecting"
            $ssid = Restart-WifiConnection
            Add-Log "Wi-Fi reconnect attempted (SSID: $ssid)"
            $script:wifiFailCount = 0
            $script:portalFailCount = 0
            $script:portalUnknownCount = 0
        }
        elseif ($portalStatus -eq 'Active') {
            Set-Status "You're connected" "Connected"
            $networkName.Text = $currentWifiState.SSID
            $now2 = Get-Date
            if ($script:LastLoggedStatus -ne 'Active') {
                Add-Log "Connected & Logged In (SSID: $($currentWifiState.SSID))"
                $script:LastLoggedStatus = 'Active'
                $script:LastHealthyLogAt = $now2
            }
            elseif (($now2 - $script:LastHealthyLogAt).TotalMinutes -ge 10) {
                Add-Log "Still connected & logged in (heartbeat, SSID: $($currentWifiState.SSID))"
                $script:LastHealthyLogAt = $now2
            }
        }
        else {
            $script:LastLoggedStatus = ""
        }

        $timer.Interval = [TimeSpan]::FromMilliseconds($CheckIntervalMs)
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] timer.Add_Tick: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
        Set-Status "Error - see log" "Error"
        # Reset fail counters so the next tick starts fresh rather than
        # immediately triggering another reconnect on a potentially stale state.
        $script:wifiFailCount = 0
        $script:portalFailCount = 0
        $script:portalUnknownCount = 0
        # Ensure the timer interval is back to normal in case it was set to 1ms
        # by Invoke-ImmediateConnectivityCheck just before the error occurred.
        $timer.Interval = [TimeSpan]::FromMilliseconds($CheckIntervalMs)
    }
})

# ---------- Window Entrance Animation ----------
$window.Add_Loaded({
    try {
        # Fade-in animation
        $fadeIn = [System.Windows.Media.Animation.DoubleAnimation]::new(0, 1, [TimeSpan]::FromSeconds(0.25))
        $window.BeginAnimation([System.Windows.Window]::OpacityProperty, $fadeIn)

        Limit-LogFile
        $osInfo = try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { "unknown OS" }
        $adapterInfo = Get-WifiAdapter
        $adapterDesc = if ($adapterInfo) { "$($adapterInfo.Name) - $($adapterInfo.InterfaceDescription)" } else { "NOT FOUND" }
        Add-Log "===== Session starting (NexLink v$NexLinkVersion) ====="
        Add-Log "===== Monitor started. Checking every $($CheckIntervalMs / 1000)s. ====="
        Add-Log "Version=$NexLinkVersion OS='$osInfo' Adapter='$adapterDesc'"
        
        # Auto-enable Wi-Fi adapter if it's disabled on startup
        Enable-WifiAdapterIfDisabled | Out-Null
        # Pre-load credentials to prompt user if needed (non-blocking - continues even if fails)
        Get-PortalCredential | Out-Null
        Update-KnownSSID | Out-Null
        $currentWifiState = Get-CurrentWifiState
        Add-Log "Startup Wi-Fi state: SSID='$($currentWifiState.SSID)' Signal=$($currentWifiState.Signal)%"
        $bestSsid = Get-BestFreeNetwork -CurrentWifiState $currentWifiState
        $currentSsid = $currentWifiState.SSID
        if ($bestSsid -and $currentSsid -and $currentSsid -ne $bestSsid) {
            Add-Log "Starting on '$currentSsid'; switching to preferred network '$bestSsid'"
            Restart-WifiConnection | Out-Null
        }
        $trayIcon.ShowBalloonTip(4000, "NexLink is running", "Look for this icon in your system tray. If you don't see it, click the small ^ arrow next to your other tray icons.", [System.Windows.Forms.ToolTipIcon]::Info)
        $timer.Start()

        # Update check runs last, after the core monitor is already active.
        # A slow or failed network check here can never delay or block the
        # app's actual job of keeping you connected.
        $script:LastUpdateCheckAt = Get-Date
        $foundUpdate = Test-ForUpdate
        if ($foundUpdate) {
            $script:PendingUpdateManifest = $foundUpdate
            $updateBannerText.Text = "v$($foundUpdate.version) is available"
            $updateBanner.Visibility = [System.Windows.Visibility]::Visible
        }
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] window.Add_Loaded: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

# ---------- Advanced Panel ----------
$advancedXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="NexLink Advanced"
        Width="500" Height="460"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen">
    <Window.Resources>
        <!-- Primary Action Button (Upgrade to Pro) -->
        <Style x:Key="PrimaryActionButton" TargetType="Button">
            <Setter Property="Background">
                <Setter.Value>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                        <GradientStop Color="#7C3AED" Offset="0"/>
                        <GradientStop Color="#06B6D4" Offset="1"/>
                    </LinearGradientBrush>
                </Setter.Value>
            </Setter>
            <Setter Property="Foreground" Value="#F5F5F7"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="ButtonBorder" Background="{TemplateBinding Background}" CornerRadius="6" BorderThickness="0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.9"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder" Property="RenderTransform">
                                    <Setter.Value>
                                        <ScaleTransform ScaleX="0.98" ScaleY="0.98" CenterX="0.5" CenterY="0.5"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Standard Action Button (5 buttons: Enter License, Re-enter Credentials, Change Theme, Open Log, Send Report) -->
        <Style x:Key="StandardActionButton" TargetType="Button">
            <Setter Property="Background" Value="#1F2937"/>
            <Setter Property="Foreground" Value="#F5F5F7"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="ButtonBorder" Background="{TemplateBinding Background}" CornerRadius="6" BorderBrush="#374151" BorderThickness="1">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="#374151"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder" Property="RenderTransform">
                                    <Setter.Value>
                                        <ScaleTransform ScaleX="0.98" ScaleY="0.98" CenterX="0.5" CenterY="0.5"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Destructive Action Button (Deactivate License) -->
        <Style x:Key="DestructiveActionButton" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#F43F5E"/>
            <Setter Property="BorderBrush" Value="#F43F5E"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="ButtonBorder" Background="{TemplateBinding Background}" CornerRadius="6" BorderBrush="#F43F5E" BorderThickness="1">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="#1AF43F5E"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder" Property="RenderTransform">
                                    <Setter.Value>
                                        <ScaleTransform ScaleX="0.98" ScaleY="0.98" CenterX="0.5" CenterY="0.5"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Section Label Style -->
        <Style x:Key="SectionLabel" TargetType="TextBlock">
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="FontSize" Value="10"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="#06B6D4"/>
        </Style>
    </Window.Resources>
    <Border Background="#14171F" CornerRadius="8" BorderBrush="#1F2937" BorderThickness="1">
        <Grid>
            <!-- Title Bar -->
            <Grid Height="35" VerticalAlignment="Top" Background="#1F2937">
                <TextBlock Text="Advanced" FontFamily="Segoe UI" FontSize="12" FontWeight="SemiBold" 
                           Foreground="#F5F5F7" VerticalAlignment="Center" Margin="12,0,0,0"/>
                <Button Name="AdvCloseBtn" Width="30" Height="30"
                        Background="Transparent" Foreground="#9CA3AF"
                        BorderThickness="0" Cursor="Hand" HorizontalAlignment="Right" Margin="0,0,8,0">
                    <Path Data="M18 6L6 18M6 6l12 12" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="2" Width="16" Height="16" Stretch="Uniform"/>
                </Button>
            </Grid>
            
            <!-- Log Viewer -->
            <TextBox Name="LogViewer"
                     Background="#0B0D13" Foreground="#22D3AA"
                     BorderBrush="#1F2937" BorderThickness="1"
                     FontFamily="Consolas" FontSize="10"
                     VerticalAlignment="Top" Margin="12,45,12,0" Height="140"
                     TextWrapping="Wrap" IsReadOnly="True" VerticalScrollBarVisibility="Auto"/>
            
            <!-- Buttons -->
            <StackPanel VerticalAlignment="Bottom" Margin="12,195,12,12">
                <!-- LICENSE Group -->
                <TextBlock Text="LICENSE" Style="{StaticResource SectionLabel}" Margin="0,0,0,8"/>
                <WrapPanel Orientation="Horizontal" Margin="0,0,0,16">
                    <Button Name="UpgradeBtn" Content="Upgrade to Pro" Width="130" Height="32"
                            Style="{StaticResource PrimaryActionButton}" Margin="0,0,6,0"/>
                    <Button Name="EnterLicenseBtn" Content="Enter Pro License" Width="140" Height="32"
                            Style="{StaticResource StandardActionButton}" Margin="0,0,6,0"/>
                    <Button Name="DeactivateLicenseBtn" Content="Deactivate License" Width="140" Height="32"
                            Style="{StaticResource DestructiveActionButton}"/>
                </WrapPanel>

                <!-- SETTINGS Group -->
                <TextBlock Text="SETTINGS" Style="{StaticResource SectionLabel}" Margin="0,0,0,8"/>
                <WrapPanel Orientation="Horizontal" Margin="0,0,0,16">
                    <Button Name="ReenterCredBtn" Content="Re-enter Credentials" Width="150" Height="32"
                            Style="{StaticResource StandardActionButton}" Margin="0,0,6,0"/>
                    <Button Name="ThemePickerBtn" Content="Change Theme" Width="120" Height="32"
                            Style="{StaticResource StandardActionButton}"/>
                </WrapPanel>

                <!-- SUPPORT Group -->
                <TextBlock Text="SUPPORT" Style="{StaticResource SectionLabel}" Margin="0,0,0,8"/>
                <WrapPanel Orientation="Horizontal">
                    <Button Name="OpenLogBtn" Content="Open Log File" Width="130" Height="32"
                            Style="{StaticResource StandardActionButton}" Margin="0,0,6,0"/>
                    <Button Name="SendReportBtn" Content="Send Error Report" Width="150" Height="32"
                            Style="{StaticResource StandardActionButton}"/>
                </WrapPanel>
            </StackPanel>
            
            <!-- Version -->
            <TextBlock Name="AdvVersionText" Text="v1.3.0" 
                       FontFamily="Segoe UI" FontSize="9" 
                       Foreground="#6B7280" VerticalAlignment="Bottom" HorizontalAlignment="Left" Margin="12,0,0,8"/>
        </Grid>
    </Border>
</Window>
"@

$advStringReader = [System.IO.StringReader]::new($advancedXaml)
$advReader = [System.Xml.XmlReader]::Create($advStringReader)
try {
    $advWindow = [System.Windows.Markup.XamlReader]::Load($advReader)
}
finally {
    $advReader.Close()
    $advStringReader.Dispose()
}

$advLogViewer = $advWindow.FindName("LogViewer")
$advCloseBtn = $advWindow.FindName("AdvCloseBtn")
$reenterCredBtn = $advWindow.FindName("ReenterCredBtn")
$upgradeBtn = $advWindow.FindName("UpgradeBtn")
$enterLicenseBtn = $advWindow.FindName("EnterLicenseBtn")
$deactivateLicenseBtn = $advWindow.FindName("DeactivateLicenseBtn")
$themePickerBtn = $advWindow.FindName("ThemePickerBtn")
$openLogBtn = $advWindow.FindName("OpenLogBtn")
$sendReportBtn = $advWindow.FindName("SendReportBtn")
$advVersionText = $advWindow.FindName("AdvVersionText")
$advVersionText.Text = "v$NexLinkVersion"

# Advanced window entrance animation
$advWindow.Add_Loaded({
    try {
        $fadeIn = [System.Windows.Media.Animation.DoubleAnimation]::new(0, 1, [TimeSpan]::FromSeconds(0.25))
        $advWindow.BeginAnimation([System.Windows.Window]::OpacityProperty, $fadeIn)
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] advWindow.Add_Loaded: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

# Advanced window dragging
$advWindow.Add_MouseLeftButtonDown({
    try {
        $this.DragMove()
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] advWindow.Add_MouseLeftButtonDown: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

# Close advanced panel
$advCloseBtn.Add_Click({
    try {
        $advWindow.Hide()
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] advCloseBtn.Add_Click: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

# Re-enter credentials
$reenterCredBtn.Add_Click({
    try {
        if (Save-PortalCredential) {
            $script:PortalSession = $null
            Add-Log "Credentials re-entered by user."
            [System.Windows.Forms.MessageBox]::Show("Credentials updated successfully.", "NexLink") | Out-Null
        }
        else {
            Add-Log "Credential re-entry cancelled by user - existing credentials unchanged, app continues running."
        }
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] reenterCredBtn.Add_Click: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

# Upgrade to Pro
$upgradeBtn.Add_Click({
    try {
        $paymentUrl = "https://paystack.shop/pay/nexlink-license"
        [System.Windows.Forms.MessageBox]::Show("This will open the Paystack payment page in your browser. Complete the payment to receive your Pro license key.", "NexLink Pro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        Start-Process $paymentUrl
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] upgradeBtn.Add_Click: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

# Enter Pro License
$enterLicenseBtn.Add_Click({
    try {
        Show-LicenseInputDialog
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] enterLicenseBtn.Add_Click: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

# Theme picker (Pro feature)
$themePickerBtn.Add_Click({
    try {
        if (-not $script:IsProLicensed) {
            [System.Windows.Forms.MessageBox]::Show("Theme customization is a Pro feature. Please activate your license first.", "NexLink Pro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        Show-ThemePickerDialog
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] themePickerBtn.Add_Click: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

# Deactivate License
$deactivateLicenseBtn.Add_Click({
    try {
        if (-not $script:IsProLicensed) {
            [System.Windows.Forms.MessageBox]::Show("No active Pro license to deactivate.", "NexLink Pro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        
        $result = [System.Windows.Forms.MessageBox]::Show("Are you sure you want to deactivate your Pro license? This will remove all Pro features.", "NexLink Pro", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        
        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            try {
                Remove-Item $script:ProLicenseFile -ErrorAction Stop
                $script:IsProLicensed = $false
                Add-Log "Pro license deactivated by user."
                [System.Windows.Forms.MessageBox]::Show("Pro license deactivated successfully.", "NexLink Pro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            }
            catch {
                Add-Log "Failed to deactivate Pro license: $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show("Failed to deactivate license. Please check logs for details.", "NexLink Pro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            }
        }
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] deactivateLicenseBtn.Add_Click: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

# Open log file
$openLogBtn.Add_Click({
    try {
        if (Test-Path $LogFile) {
            [NexLink.Win32ForegroundHelper]::AllowSetForegroundWindow(-1) | Out-Null
            Start-Process explorer.exe -ArgumentList "/select,`"$LogFile`""
            Add-Log "Opened log file location in Explorer: $LogFile"
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Log file not found.", "NexLink") | Out-Null
        }
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] openLogBtn.Add_Click: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

# Send error report
$sendReportBtn.Add_Click({
    try {
        Invoke-SendErrorReport
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] sendReportBtn.Add_Click: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

# Update log viewer when advanced panel opens
$updateRestartBtn.Add_Click({
    try {
        if ($script:PendingUpdateManifest) {
            $updateRestartBtn.IsEnabled = $false
            $updateRestartBtn.Content = "Updating..."
            Start-NexLinkUpdate $script:PendingUpdateManifest
            # If we reach this line, the update did NOT proceed (download or
            # verification failed) - Start-NexLinkUpdate already logged why and
            # showed the user a message. Re-enable the button so they can retry.
            $updateRestartBtn.IsEnabled = $true
            $updateRestartBtn.Content = "Restart to Update"
        }
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] updateRestartBtn.Add_Click: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

$settingsBtn.Add_Click({
    try {
        $advLogViewer.Text = $script:logLines -join "`r`n"
        $advLogViewer.ScrollToEnd()
        $advWindow.Show() | Out-Null
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] settingsBtn.Add_Click: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})

# ---------- Show Window ----------
$window.Add_Closed({
    try {
        # Safety net: if the window closes through any path we haven't
        # explicitly handled (Alt+F4, system menu, etc.), still clean up
        # properly instead of leaving a zombie process or orphaned tray icon.
        # Guard with $script:allowExit so Invoke-GracefulExit (which calls
        # $window.Close() itself) doesn't double-fire InvokeShutdown.
        if (-not $script:allowExit) {
            Add-Log "===== Session ending (window close) ====="
            $timer.Stop()
            $trayIcon.Visible = $false
            try { Unregister-Event -SourceIdentifier $powerModeChangedHandler.Name -ErrorAction SilentlyContinue } catch {}
            try { [System.Net.NetworkInformation.NetworkChange]::remove_NetworkAddressChanged($script:NetworkAddressChangedHandler) } catch {}
            try { $script:InstanceMutex.ReleaseMutex() } catch {}
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
        }
    }
    catch {
        $errorMsg = "[HANDLER-CRASH] window.Add_Closed: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
        try { Add-Log $errorMsg } catch {}
        try { Add-Content -Path $script:CrashLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMsg`nStack: $($_.ScriptStackTrace)" -ErrorAction SilentlyContinue } catch {}
    }
})
$window.Show()
[System.Windows.Threading.Dispatcher]::Run()

} catch {
    # Top-level crash handler - write to crash log before exiting
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $errorMsg = $_.Exception.Message
    $errorType = $_.Exception.GetType().FullName
    $errorStackTrace = $_.ScriptStackTrace
    $crashEntry = "[$timestamp] CRASH: $errorType - $errorMsg`nStack: $errorStackTrace`n"
    try {
        Add-Content -Path $script:CrashLogFile -Value $crashEntry -ErrorAction SilentlyContinue
    } catch {}
    # In ps2exe builds, also try to show a message box if possible
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            "NexLink encountered a fatal error and must close.`n`nError: $errorMsg`n`nA crash log has been saved to:`n$script:CrashLogFile",
            "NexLink - Fatal Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch {}
    exit 1
}
