# Copyright (c) 2026 Odetayo Josiah Inioluwa. All rights reserved.
# Licensed under the terms in LICENSE.md — see repository
#
# NexLink-GUI.ps1
# Same as before, but with a visible status window so you always know what's happening.
# Green = all good. Orange = fixing something. Red = error (check the log box).
#
# HOW TO RUN (important - do NOT double-click the file):
#   1. Right-click Start -> "Windows PowerShell (Admin)" or "Terminal (Admin)"
#   2. cd to the folder where this file is saved, e.g.: cd "Downloads\wifi setup"
#   3. If blocked, run once:  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   4. Then run:  .\NexLink-GUI.ps1
#   5. A small window will pop up and stay open. Leave it running during your test.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Invoke-WebRequest reports download progress via Write-Progress. In a normal
# console this is invisible, but in a ps2exe -noConsole build, that progress
# event renders as an actual modal dialog that blocks the entire WinForms
# message loop - freezing the whole app. Suppress it entirely.
$ProgressPreference = 'SilentlyContinue'

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

function Get-WifiAdapter {
    try {
        return Get-NetAdapter | Where-Object { $_.Status -ne 'Disabled' -and $_.InterfaceDescription -match 'Wi-Fi|Wireless' } | Select-Object -First 1
    }
    catch {
        return $null
    }
}

function Get-CurrentSSID {
    try {
        $result = netsh wlan show interfaces 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        $line = $result | Select-String '^\s*SSID\s*:\s*(.+)$'
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

# (Removed manual self-elevation — the compiled EXE will use an
# application manifest for elevation via the ps2exe `-requireAdmin` flag.)


Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---- Settings ----
$NexLinkVersion = "1.1.0"
$PingTarget = "8.8.8.8"
$TestPageUrl = "http://www.msftconnecttest.com/connecttest.txt"
$ExpectedOnlineText = "Microsoft Connect Test"
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
$CredFile = Join-Path $ScriptDir "lmu_portal.cred"
$LogFile = Join-Path $ScriptDir "lmu_autoconnect.log"

$script:wifiFailCount = 0
$script:portalFailCount = 0
$script:LastKnownSSID = $null
$script:secondsToNextCheck = $CheckIntervalMs / 1000
$script:PortalRetryAfter = [DateTime]::MinValue
$script:PortalCooldownShown = $false
$script:LastReconnectAt = [DateTime]::MinValue
$script:PortalSession = $null
$script:LastLogTrimAt = Get-Date

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
            return $true
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Unable to save credentials: $($_.Exception.Message)", "NexLink") | Out-Null
            return $false
        }
    }
    return $false
}

function Get-PortalCredential {
    if (-not (Test-Path $CredFile)) {
        if (-not (Save-PortalCredential)) {
            [System.Windows.Forms.MessageBox]::Show("No credentials entered. Exiting.", "NexLink") | Out-Null
            exit
        }
    }

    try {
        $data = Get-Content $CredFile -Raw | ConvertFrom-Json
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Credential file is unreadable or corrupt. Delete $CredFile and run again.", "NexLink") | Out-Null
        exit
    }

    if (-not $data.Username -or -not $data.Password) {
        [System.Windows.Forms.MessageBox]::Show("Credential file is missing required values.", "NexLink") | Out-Null
        exit
    }

    try {
        $securePass = ConvertTo-SecureString $data.Password
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Saved password could not be decrypted. Delete $CredFile and create it again.", "NexLink") | Out-Null
        exit
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
    # Refresh the cached SSID whenever we can actually see one, so a later
    # reconnect attempt (which often happens AFTER the adapter has already
    # dropped and Get-CurrentSSID returns nothing) still has a target.
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

function Get-CurrentWifiState {
    try {
        $result = netsh wlan show interfaces 2>$null
        if ($LASTEXITCODE -ne 0) { return [PSCustomObject]@{ SSID = $null; Signal = 0 } }

        $ssid = $null
        $signal = 0
        $ssidLine = $result | Select-String '^\s*SSID\s*:\s*(.+)$'
        if ($ssidLine) { $ssid = ($ssidLine.Matches[0].Groups[1].Value).Trim() }

        $signalLine = $result | Select-String '^\s*Signal\s*:\s*(\d+)\s*%'
        if ($signalLine) { $signal = [int]$signalLine.Matches[0].Groups[1].Value }

        return [PSCustomObject]@{ SSID = $ssid; Signal = $signal }
    }
    catch {
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
    param([psobject]$CurrentWifiState = $null)

    if (-not $CurrentWifiState) { $CurrentWifiState = Get-CurrentWifiState }
    $visibleNetworks = Get-VisibleWifiNetworks | Where-Object { Test-TrustedNetwork -Ssid $_.SSID }
    $visibleNetworks = @($visibleNetworks)
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
        [psobject]$CurrentWifiState
    )
    if (-not $TargetSsid) { return $false }
    if (-not (Test-TrustedNetwork -Ssid $TargetSsid)) { return $false }
    if (-not $CurrentWifiState -or -not $CurrentWifiState.SSID) { return $true }
    if ($TargetSsid -eq $CurrentWifiState.SSID) { return $false }
    if ($script:LastReconnectAt -and ((Get-Date) - $script:LastReconnectAt).TotalSeconds -lt $ReconnectCooldownSec) { return $false }

    $currentSignal = [int]$CurrentWifiState.Signal
    $targetSignal = 0
    $targetNetwork = Get-VisibleWifiNetworks | Where-Object { $_.SSID -eq $TargetSsid } | Select-Object -First 1
    if ($targetNetwork -and $null -ne $targetNetwork.Signal) { $targetSignal = [int]$targetNetwork.Signal }

    if ($targetSignal -ge ($currentSignal + 5)) { return $true }
    if ($targetSignal -ge 70 -and $currentSignal -lt 70) { return $true }
    return $false
}

function Restart-WifiConnection {
    $currentWifiState = Get-CurrentWifiState
    $targetSsid = Get-BestFreeNetwork -CurrentWifiState $currentWifiState
    if (-not $targetSsid) { $targetSsid = $script:LastKnownSSID }
    if (-not $targetSsid) { $targetSsid = $currentWifiState.SSID }
    if ($targetSsid -and -not (Test-WifiSwitchNeeded -TargetSsid $targetSsid -CurrentWifiState $currentWifiState)) { return $currentWifiState.SSID }

    netsh wlan disconnect 2>$null | Out-Null
    Start-Sleep -Seconds 2
    if ($targetSsid) {
        if (Connect-ToWifiNetwork -Ssid $targetSsid) {
            Clear-DnsCache
            $script:LastKnownSSID = $targetSsid
            $script:LastReconnectAt = Get-Date
            $script:PortalSession = $null
        }
        else {
            $adapter = Get-WifiAdapter
            if ($adapter) {
                Disable-NetAdapter -Name $adapter.Name -Confirm:$false
                Start-Sleep -Seconds 2
                Enable-NetAdapter -Name $adapter.Name -Confirm:$false
            }
        }
    }
    else {
        $adapter = Get-WifiAdapter
        if ($adapter) {
            Disable-NetAdapter -Name $adapter.Name -Confirm:$false
            Start-Sleep -Seconds 2
            Enable-NetAdapter -Name $adapter.Name -Confirm:$false
        }
    }
    Start-Sleep -Seconds 3
    return $targetSsid
}

function Test-PortalSession {
    try {
        if ($script:PortalSession) {
            $resp = Invoke-WebRequest -Uri $TestPageUrl -UseBasicParsing -TimeoutSec 6 -ErrorAction Stop -WebSession $script:PortalSession -Headers @{ 'Cache-Control' = 'no-cache'; Pragma = 'no-cache' }
        }
        else {
            $resp = Invoke-WebRequest -Uri $TestPageUrl -UseBasicParsing -TimeoutSec 6 -ErrorAction Stop -SessionVariable 'newSession' -Headers @{ 'Cache-Control' = 'no-cache'; Pragma = 'no-cache' }
            $script:PortalSession = $newSession
        }
        $content = $resp.Content.Trim()
        if ($content -eq $ExpectedOnlineText) { return 'Active' }
        # Any other content on this URL means something (the router) intercepted
        # the request and served its own page instead of the real one - that's the portal.
        return 'LoggedOut'
    }
    catch {
        # Could not even connect - either genuinely offline or the router is
        # blackholing traffic rather than redirecting it. Treat as unknown so
        # we don't hammer a login POST when we can't reach it anyway.
        return 'Unknown'
    }
}

function Invoke-PortalLogin {
    $cred = Get-PortalCredential
    $body = @{ dst = ""; popup = "true"; username = $cred.Username; password = $cred.Password }
    $loginUrls = @($LoginUrl, ($LoginUrl -replace '^https://', 'http://'))
    foreach ($url in $loginUrls) {
        try {
            if (-not $script:PortalSession) {
                $resp = Invoke-WebRequest -Uri $url -Method Post -Body $body -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop -SessionVariable 'newSession' -Headers @{ 'Cache-Control' = 'no-cache'; Pragma = 'no-cache' }
                $script:PortalSession = $newSession
            }
            else {
                $resp = Invoke-WebRequest -Uri $url -Method Post -Body $body -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop -WebSession $script:PortalSession -Headers @{ 'Cache-Control' = 'no-cache'; Pragma = 'no-cache' }
            }
            $content = $resp.Content
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
            if ($url -eq $loginUrls[-1]) { throw $_ }
        }
    }
}

function Invoke-PortalLogout {
    if (-not $script:PortalSession) { return $false }
    $logoutUrls = @($LogoutUrl, ($LogoutUrl -replace '^https://', 'http://'))
    foreach ($url in $logoutUrls) {
        try {
            Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop -WebSession $script:PortalSession -Headers @{ 'Cache-Control' = 'no-cache'; Pragma = 'no-cache' } | Out-Null
            $script:PortalSession = $null
            return $true
        }
        catch {
            if ($url -eq $logoutUrls[-1]) { return $false }
        }
    }
}

# ---------- GUI ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "NexLink v$NexLinkVersion — Campus Auto-Connect"
$form.Size = New-Object System.Drawing.Size(420, 360)
$form.StartPosition = "CenterScreen"
$form.TopMost = $false
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Starting..."
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$statusLabel.TextAlign = "MiddleCenter"
$statusLabel.Dock = "Top"
$statusLabel.Height = 70
$statusLabel.BackColor = [System.Drawing.Color]::Gray
$statusLabel.ForeColor = [System.Drawing.Color]::White

$countdownLabel = New-Object System.Windows.Forms.Label
$countdownLabel.Text = "Next check in --s"
$countdownLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$countdownLabel.TextAlign = "MiddleCenter"
$countdownLabel.Dock = "Top"
$countdownLabel.Height = 20
$countdownLabel.ForeColor = [System.Drawing.Color]::DimGray

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.Dock = "Fill"
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)

$disconnectButton = New-Object System.Windows.Forms.Button
$disconnectButton.Text = "Disconnect"
$disconnectButton.Dock = "Top"
$disconnectButton.Height = 32
$disconnectButton.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$disconnectButton.FlatStyle = "Flat"

$form.Controls.Add($logBox)
$form.Controls.Add($disconnectButton)
$form.Controls.Add($countdownLabel)
$form.Controls.Add($statusLabel)

function Set-Status($text, $color) {
    $statusLabel.Text = $text
    $statusLabel.BackColor = $color
    $trayIcon.Text = "NexLink: $text"
}

function Add-Log($text) {
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $line = "[$timestamp] $text"
    $logBox.AppendText("$line`r`n")
    try {
        $logDir = Split-Path -Parent $LogFile
        if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    }
    catch {}
}

function Limit-LogFile {
    # Keep the log file from growing forever - trim to the last $MaxLogLines
    # lines whenever it exceeds double that, so this only runs occasionally.
    try {
        if (-not (Test-Path $LogFile)) { return }
        $lines = Get-Content -Path $LogFile -ErrorAction SilentlyContinue
        if ($lines -and $lines.Count -gt ($MaxLogLines * 2)) {
            $trimmed = $lines[-$MaxLogLines..-1]
            Set-Content -Path $LogFile -Value $trimmed -Encoding UTF8
        }
    }
    catch {}
}

$script:ManuallyDisconnected = $false

function Disconnect-Manually {
    $timer.Stop()
    $countdownTimer.Stop()
    Set-Status "Logging out..." ([System.Drawing.Color]::Orange)
    $loggedOut = Invoke-PortalLogout
    if ($loggedOut) {
        Add-Log "Portal session logged out."
    }
    else {
        Add-Log "Portal logout could not be confirmed (already logged out, or no active session)."
    }
    netsh wlan disconnect 2>$null | Out-Null
    $script:ManuallyDisconnected = $true
    $disconnectButton.Text = "Reconnect"
    Set-Status "Disconnected (manual)" ([System.Drawing.Color]::Gray)
    $countdownLabel.Text = "Auto-reconnect paused"
    Add-Log "Manually disconnected. Auto-reconnect is paused until you click Reconnect."
}

function Reconnect-Manually {
    $script:ManuallyDisconnected = $false
    $disconnectButton.Text = "Disconnect"
    Add-Log "Manual reconnect requested."
    Set-Status "Reconnecting Wi-Fi..." ([System.Drawing.Color]::Orange)
    Restart-WifiConnection | Out-Null
    $script:wifiFailCount = 0
    $script:portalFailCount = 0
    $script:secondsToNextCheck = $CheckIntervalMs / 1000
    $timer.Interval = $CheckIntervalMs
    $timer.Start()
    $countdownTimer.Start()
}

$disconnectButton.Add_Click({
        if ($script:ManuallyDisconnected) {
            Reconnect-Manually
        }
        else {
            Disconnect-Manually
        }
    })

# ---------- System tray ----------
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon = [System.Drawing.SystemIcons]::Application
$trayIcon.Text = "NexLink v$NexLinkVersion Monitor"
$trayIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuShow = $trayMenu.Items.Add("Show Window")
$menuDisconnect = $trayMenu.Items.Add("Disconnect")
$trayMenu.Items.Add("-") | Out-Null
$menuExit = $trayMenu.Items.Add("Exit")
$trayIcon.ContextMenuStrip = $trayMenu

$script:allowExit = $false

$menuShow.Add_Click({ $form.Show(); $form.WindowState = "Normal"; $form.Activate() })
$trayIcon.Add_DoubleClick({ $form.Show(); $form.WindowState = "Normal"; $form.Activate() })

$trayMenu.Add_Opening({
        $menuDisconnect.Text = if ($script:ManuallyDisconnected) { "Reconnect" } else { "Disconnect" }
    })

$menuDisconnect.Add_Click({
        if ($script:ManuallyDisconnected) {
            Reconnect-Manually
        }
        else {
            Disconnect-Manually
        }
    })

$form.Add_Resize({
        if ($form.WindowState -eq "Minimized") {
            $form.Hide()
            $trayIcon.ShowBalloonTip(1500, "NexLink", "Still running in the background.", [System.Windows.Forms.ToolTipIcon]::Info)
        }
    })

$form.Add_FormClosing({
        param($senderObj, $eArgs)
        if (-not $script:allowExit) {
            $eArgs.Cancel = $true
            $form.WindowState = "Minimized"
            $form.Hide()
            $trayIcon.ShowBalloonTip(1500, "NexLink", "Minimized to tray. Right-click the tray icon to exit.", [System.Windows.Forms.ToolTipIcon]::Info)
        }
        else {
            $trayIcon.Visible = $false
        }
    })

$menuExit.Add_Click({
        $script:allowExit = $true
        $timer.Stop()
        $countdownTimer.Stop()
        $trayIcon.Visible = $false
        try { $script:InstanceMutex.ReleaseMutex() } catch {}
        $form.Close()
    })

# ---------- Countdown timer (visual heartbeat) ----------
$countdownTimer = New-Object System.Windows.Forms.Timer
$countdownTimer.Interval = 1000
$countdownTimer.Add_Tick({
        $script:secondsToNextCheck--
        if ($script:secondsToNextCheck -lt 0) { $script:secondsToNextCheck = 0 }
        $countdownLabel.Text = "Next check in $($script:secondsToNextCheck)s"
    })

# ---------- Timer-driven check loop (keeps GUI responsive) ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $CheckIntervalMs

$timer.Add_Tick({
        if ($script:ManuallyDisconnected) { return }
        $script:secondsToNextCheck = $CheckIntervalMs / 1000
        if (((Get-Date) - $script:LastLogTrimAt).TotalHours -ge 1) {
            Limit-LogFile
            $script:LastLogTrimAt = Get-Date
        }
        try {
            $currentWifiState = Get-CurrentWifiState
            $targetSsid = Get-BestFreeNetwork -CurrentWifiState $currentWifiState
            if (Test-WifiSwitchNeeded -TargetSsid $targetSsid -CurrentWifiState $currentWifiState) {
                Add-Log "Better Wi-Fi available ('$targetSsid'). Switching now."
                Set-Status "Switching Wi-Fi..." ([System.Drawing.Color]::Orange)
                Restart-WifiConnection | Out-Null
                $script:wifiFailCount = 0
                $script:portalFailCount = 0
                $currentWifiState = Get-CurrentWifiState
            }

            $pingOk = Test-Connection -ComputerName $PingTarget -Count 1 -Quiet -ErrorAction SilentlyContinue

            if ($pingOk) {
                $script:wifiFailCount = 0
                Update-KnownSSID | Out-Null
            }
            else {
                $script:wifiFailCount++
                Add-Log "Ping failed ($script:wifiFailCount/$WifiFailsBeforeFix)"
                Set-Status "Checking connection..." ([System.Drawing.Color]::Orange)
            }

            $portalStatus = Test-PortalSession
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
                    Set-Status "Logging into portal..." ([System.Drawing.Color]::Orange)
                    Add-Log "Portal session inactive - logging back in"
                    try {
                        $result = Invoke-PortalLogin
                        Clear-DnsCache
                        Add-Log "Portal login submitted via '$($result.Url)' (AlreadyLoggedIn=$($result.AlreadyLoggedIn))"
                        $script:portalFailCount = 0
                        $script:wifiFailCount = 0
                        $script:PortalRetryAfter = [DateTime]::MinValue
                    }
                    catch {
                        $script:portalFailCount++
                        $cooldownSeconds = [Math]::Min($PortalLoginRetryCooldownSec, 10 + ($script:portalFailCount * 5))
                        $script:PortalRetryAfter = $now.AddSeconds($cooldownSeconds)
                        Add-Log "Portal login FAILED ($script:portalFailCount). Retrying in $cooldownSeconds seconds: $($_.Exception.Message)"
                        Set-Status "Portal login error" ([System.Drawing.Color]::Red)
                    }
                }
            }
            elseif ($portalStatus -eq 'Active') {
                $script:wifiFailCount = 0
                $script:portalFailCount = 0
                $script:PortalRetryAfter = [DateTime]::MinValue
                $script:PortalCooldownShown = $false
            }
            else {
                $script:PortalRetryAfter = [DateTime]::MinValue
                $script:PortalCooldownShown = $false
            }

            if ($script:wifiFailCount -ge $WifiFailsBeforeFix -or $script:portalFailCount -ge $WifiFailsBeforeFix) {
                Set-Status "Reconnecting Wi-Fi..." ([System.Drawing.Color]::OrangeRed)
                $ssid = Restart-WifiConnection
                Add-Log "Wi-Fi reconnect attempted (SSID: $ssid)"
                $script:wifiFailCount = 0
                $script:portalFailCount = 0
            }
            elseif ($portalStatus -eq 'Active') {
                Set-Status "Connected & Logged In" ([System.Drawing.Color]::SeaGreen)
            }

            if ($script:portalFailCount -ge 2) {
                $timer.Interval = [Math]::Min($CheckIntervalMs * $script:portalFailCount, 30000)
            }
            else {
                $timer.Interval = $CheckIntervalMs
            }
            $script:secondsToNextCheck = $timer.Interval / 1000
        }
        catch {
            Add-Log "ERROR: $($_.Exception.Message)"
            Set-Status "Error - see log" ([System.Drawing.Color]::Red)
        }
    })

$form.Add_Shown({
        Limit-LogFile
        Add-Log "Monitor started. Checking every $($CheckIntervalMs / 1000)s."
        Get-PortalCredential | Out-Null
        Update-KnownSSID | Out-Null
        $currentWifiState = Get-CurrentWifiState
        $bestSsid = Get-BestFreeNetwork -CurrentWifiState $currentWifiState
        $currentSsid = $currentWifiState.SSID
        if ($bestSsid -and $currentSsid -and $currentSsid -ne $bestSsid) {
            Add-Log "Starting on '$currentSsid'; switching to preferred network '$bestSsid'"
            Restart-WifiConnection | Out-Null
        }
        $timer.Start()
        $countdownTimer.Start()
    })

[void]$form.ShowDialog()
