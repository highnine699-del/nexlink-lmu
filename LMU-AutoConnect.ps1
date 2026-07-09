# ============================================================
# DEPRECATED - superseded by NexLink-WPF.ps1
# This file is kept for reference only and is not part of the
# current build or release pipeline. Do not edit for new features.
# ============================================================

# LMU-AutoConnect.ps1
# Watches your internet connection AND your LMU hotspot portal session.
# If the portal session drops (common cause of "connected but not working"),
# it auto-reconnects Wi-Fi if needed, then auto-logs back into the portal.
#
# FIRST RUN:
#   It will ask for your LMU portal username + password ONCE, then save them
#   encrypted (Windows DPAPI - tied to your Windows user account only, unreadable
#   on any other PC or account) in a file next to this script.
#
# HOW TO RUN:
#   1. Right-click Start -> "Windows PowerShell (Admin)" or "Terminal (Admin)"
#   2. cd to the folder where this file is saved, e.g.: cd Downloads
#   3. If it blocks the script, run once:  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   4. Then run:  .\LMU-AutoConnect.ps1
#   5. Leave the window open (minimize it) during your test.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WifiAdapter {
    try {
        return Get-NetAdapter | Where-Object { $_.Status -ne 'Disabled' -and $_.InterfaceDescription -match 'Wi-Fi|Wireless' } | Select-Object -First 1
    }
    catch {
        return $null
    }
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

function Get-CurrentSSID {
    return (Get-CurrentWifiState).SSID
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

function Get-BestFreeNetwork {
    param([psobject]$CurrentWifiState = $null)

    $visibleNetworks = Get-VisibleWifiNetworks | Where-Object { Test-TrustedNetwork -Ssid $_.SSID }
    $visibleNetworks = @($visibleNetworks)
    if (-not $visibleNetworks -or $visibleNetworks.Count -eq 0) { return $null }

    $currentSsid = if ($CurrentWifiState) { [string]$CurrentWifiState.SSID } else { $null }
    $currentSignal = if ($CurrentWifiState) { [int]$CurrentWifiState.Signal } else { 0 }

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

function Should-SwitchToNetwork {
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

# Auto-elevate to Administrator if not already running as one
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}


# ---- Settings ----
$PingTarget = "8.8.8.8"
$TestPageUrl = "http://neverssl.com"     # plain HTTP page Mikrotik will intercept if not logged in
$LoginUrl = "https://internet.lmu.edu.ng/login"
$CheckIntervalSec = 5
$WifiFailsBeforeFix = 2
$PortalLoginRetryCooldownSec = 30
$ReconnectCooldownSec = 10
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
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$CredFile = Join-Path $ScriptDir "lmu_portal.cred"
$script:LastKnownSSID = $null
$script:PortalRetryAfter = [DateTime]::MinValue
$script:PortalCooldownShown = $false
$script:LastReconnectAt = [DateTime]::MinValue

# ---------- Desktop popup notifications (so you get visual confirmation even minimized) ----------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$Global:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$Global:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Information
$Global:NotifyIcon.Visible = $true

function Show-Popup {
    param(
        [string]$Title,
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error", "None")]
        [string]$IconType = "Info"
    )
    try {
        $Global:NotifyIcon.BalloonTipTitle = $Title
        $Global:NotifyIcon.BalloonTipText = $Message
        $Global:NotifyIcon.BalloonTipIcon = $IconType
        $Global:NotifyIcon.ShowBalloonTip(4000)
    }
    catch {
        # If balloon tips fail for any reason, don't crash the monitor over it
    }
}

Write-Host "=== LMU Wi-Fi + Portal Auto-Connect Monitor ===" -ForegroundColor Cyan
Write-Host "Checking every $CheckIntervalSec seconds. Press Ctrl+C to stop.`n"
Show-Popup -Title "LMU Auto-Connect" -Message "Monitor started. Watching your connection now." -IconType Info

# ---------- Credential handling (DPAPI encrypted, tied to your Windows account) ----------
function Save-PortalCredential {
    $u = Read-Host "Enter your LMU portal username"
    $p = Read-Host "Enter your LMU portal password" -AsSecureString
    $encryptedPass = ConvertFrom-SecureString $p
    try {
        @{ Username = $u; Password = $encryptedPass } | ConvertTo-Json | Set-Content -Path $CredFile -Encoding UTF8
        Write-Host "Credentials saved (encrypted) to $CredFile" -ForegroundColor Green
    }
    catch {
        throw "Unable to save credentials: $($_.Exception.Message)"
    }
}

function Get-PortalCredential {
    if (-not (Test-Path $CredFile)) {
        Save-PortalCredential
    }

    try {
        $data = Get-Content $CredFile -Raw | ConvertFrom-Json
    }
    catch {
        throw "Credential file is unreadable or corrupt. Delete $CredFile and run again."
    }

    if (-not $data.Username -or -not $data.Password) {
        throw "Credential file is missing required values."
    }

    try {
        $securePass = ConvertTo-SecureString $data.Password
    }
    catch {
        throw "Saved password could not be decrypted. Delete $CredFile and create it again."
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

function Reconnect-Wifi {
    $currentWifiState = Get-CurrentWifiState
    $targetSsid = Get-BestFreeNetwork -CurrentWifiState $currentWifiState
    if (-not $targetSsid) { $targetSsid = $script:LastKnownSSID }
    if (-not $targetSsid) { $targetSsid = $currentWifiState.SSID }

    if ($targetSsid -and -not (Should-SwitchToNetwork -TargetSsid $targetSsid -CurrentWifiState $currentWifiState)) {
        return $currentWifiState.SSID
    }

    Write-Host "$(Get-Date -Format 'HH:mm:ss') -- Reconnecting to the strongest available free network..." -ForegroundColor Yellow
    netsh wlan disconnect 2>$null | Out-Null
    Start-Sleep -Seconds 2

    if ($targetSsid) {
        if (Connect-ToWifiNetwork -Ssid $targetSsid) {
            Clear-DnsCache
            $script:LastKnownSSID = $targetSsid
            $script:LastReconnectAt = Get-Date
            Write-Host "$(Get-Date -Format 'HH:mm:ss') -- Reconnected to '$targetSsid'." -ForegroundColor Green
            Show-Popup -Title "LMU Auto-Connect" -Message "Wi-Fi reconnected to '$targetSsid'." -IconType Info
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

# ---------- Portal helpers ----------
function Test-PortalSession {
    # Returns 'Active' when portal is active, 'LoggedOut' when portal login is needed,
    # and 'Unknown' when state cannot be determined.
    try {
        $resp = Invoke-WebRequest -Uri $TestPageUrl -UseBasicParsing -TimeoutSec 6 -ErrorAction Stop -Headers @{ 'Cache-Control' = 'no-cache'; Pragma = 'no-cache' }
        $content = $resp.Content
        if ($content -match "Landmark University Hotspot Login" -or $content -match 'action="https://internet\.lmu\.edu\.ng/login"') {
            return 'LoggedOut'
        }
        if ($content -match 'already logged in|already login|logout|session|uptime|status|connected' -or $resp.StatusCode -eq 200) {
            return 'Active'
        }
        return 'Unknown'
    }
    catch {
        return 'Unknown'
    }
}

function Invoke-PortalLogin {
    # NOTE: intentionally does not catch - let the main loop see failures so
    # it can count them and back off, instead of hammering a struggling server.
    $cred = Get-PortalCredential
    $body = @{
        dst      = ""
        popup    = "true"
        username = $cred.Username
        password = $cred.Password
    }

    $loginUrls = @($LoginUrl, ($LoginUrl -replace '^https://', 'http://'))
    foreach ($url in $loginUrls) {
        try {
            $resp = Invoke-WebRequest -Uri $url -Method Post -Body $body -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop -Headers @{ 'Cache-Control' = 'no-cache'; Pragma = 'no-cache' }
            $content = $resp.Content
            if ($content -match 'already logged in|already login|logged in') {
                Write-Host "$(Get-Date -Format 'HH:mm:ss') -- Portal login reached existing session state on '$url'." -ForegroundColor DarkGreen
                Show-Popup -Title "LMU Auto-Connect" -Message "Portal already logged in on '$url'." -IconType Info
                return @{ Success = $true; AlreadyLoggedIn = $true; Username = $cred.Username; Url = $url }
            }
            Write-Host "$(Get-Date -Format 'HH:mm:ss') -- Portal login submitted for '$($cred.Username)' via $url." -ForegroundColor Green
            Show-Popup -Title "LMU Auto-Connect" -Message "Portal session refreshed - you're back online." -IconType Info
            return @{ Success = $true; AlreadyLoggedIn = $false; Username = $cred.Username; Url = $url }
        }
        catch {
            if ($url -eq $loginUrls[-1]) {
                throw $_
            }
        }
    }
}

# ---------- Main loop ----------
try {
    $wifiFailCount = 0
    $portalFailCount = 0

    # Make sure creds exist before we start (prompts once if needed)
    Get-PortalCredential | Out-Null
    Update-KnownSSID | Out-Null   # capture the SSID once up front while we're still connected
    $bestSsid = Get-BestFreeNetwork
    if ($bestSsid -and (Get-CurrentSSID) -and (Get-CurrentSSID) -ne $bestSsid) {
        Write-Host "$(Get-Date -Format 'HH:mm:ss') -- Starting on '$(Get-CurrentSSID)'; switching to preferred free network '$bestSsid'." -ForegroundColor Yellow
        Reconnect-Wifi
    }

    while ($true) {
        $currentWifiState = Get-CurrentWifiState
        $targetSsid = Get-BestFreeNetwork -CurrentWifiState $currentWifiState
        if (Should-SwitchToNetwork -TargetSsid $targetSsid -CurrentWifiState $currentWifiState) {
            Write-Host "$(Get-Date -Format 'HH:mm:ss') -- Better network available ('$targetSsid'). Switching now." -ForegroundColor Yellow
            Reconnect-Wifi | Out-Null
            $wifiFailCount = 0
            $portalFailCount = 0
        }

        $pingOk = Test-Connection -ComputerName $PingTarget -Count 1 -Quiet -ErrorAction SilentlyContinue

        if ($pingOk) {
            $wifiFailCount = 0
            Update-KnownSSID | Out-Null
        }
        else {
            $wifiFailCount++
            Write-Host "$(Get-Date -Format 'HH:mm:ss') -- Ping failed ($wifiFailCount/$WifiFailsBeforeFix)." -ForegroundColor DarkYellow
        }

        $portalStatus = Test-PortalSession
        switch ($portalStatus) {
            'LoggedOut' {
                $now = Get-Date
                if ($script:PortalRetryAfter -gt $now) {
                    if (-not $script:PortalCooldownShown) {
                        $remaining = [Math]::Ceiling(($script:PortalRetryAfter - $now).TotalSeconds)
                        Write-Host "$(Get-Date -Format 'HH:mm:ss') -- Portal still appears logged out. Waiting $remaining sec before retrying." -ForegroundColor DarkYellow
                        $script:PortalCooldownShown = $true
                    }
                }
                else {
                    $script:PortalCooldownShown = $false
                    Write-Host "$(Get-Date -Format 'HH:mm:ss') -- Portal session not active. Logging back in..." -ForegroundColor Yellow
                    try {
                        Invoke-PortalLogin | Out-Null
                        $portalFailCount = 0
                        $wifiFailCount = 0
                        $script:PortalRetryAfter = [DateTime]::MinValue
                    }
                    catch {
                        $portalFailCount++
                        $cooldownSeconds = [Math]::Min($PortalLoginRetryCooldownSec, 10 + ($portalFailCount * 5))
                        $script:PortalRetryAfter = $now.AddSeconds($cooldownSeconds)
                        Write-Host "$(Get-Date -Format 'HH:mm:ss') -- Portal login request failed ($portalFailCount). Retrying in $cooldownSeconds seconds: $_" -ForegroundColor Red
                        if ($portalFailCount -eq 1) {
                            Show-Popup -Title "LMU Auto-Connect" -Message "Portal login failed - check the console window." -IconType Error
                        }
                    }
                }
            }
            'Active' {
                $wifiFailCount = 0
                $portalFailCount = 0
                $script:PortalRetryAfter = [DateTime]::MinValue
                $script:PortalCooldownShown = $false
            }
            default {
                $script:PortalRetryAfter = [DateTime]::MinValue
                $script:PortalCooldownShown = $false
            }
        }

        if ($wifiFailCount -ge $WifiFailsBeforeFix -or $portalFailCount -ge $WifiFailsBeforeFix) {
            Reconnect-Wifi | Out-Null
            $wifiFailCount = 0
            $portalFailCount = 0
        }

        # Back off after repeated portal login failures instead of hammering
        # a server that's already timing out.
        $sleepSec = $CheckIntervalSec
        if ($portalFailCount -ge 2) {
            $sleepSec = [Math]::Min($CheckIntervalSec * $portalFailCount, 30)
        }
        Start-Sleep -Seconds $sleepSec
    }
}
catch {
    Write-Host "`n=== SCRIPT STOPPED WITH AN ERROR ===" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor Red
    Show-Popup -Title "LMU Auto-Connect" -Message "Monitor stopped due to an error - check the console." -IconType Error
}
finally {
    if ($Global:NotifyIcon) { $Global:NotifyIcon.Visible = $false; $Global:NotifyIcon.Dispose() }
    Write-Host "`nPress Enter to close this window..."
    Read-Host | Out-Null
}
