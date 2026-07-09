# ============================================================
# DEPRECATED - superseded by NexLink-WPF.ps1
# This file is kept for reference only and is not part of the
# current build or release pipeline. Do not edit for new features.
# ============================================================

# WifiAutoReconnect.ps1
# Watches your internet connection and auto-reconnects Wi-Fi when it silently dies.
# Run this in PowerShell BEFORE your test starts, and leave the window open (minimized is fine).
#
# HOW TO RUN:
#   1. Right-click Start -> "Windows PowerShell (Admin)" or "Terminal (Admin)"
#   2. cd to the folder where this file is saved, e.g.: cd Downloads
#   3. If it blocks the script, run this once:  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   4. Then run:  .\WifiAutoReconnect.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WifiAdapter {
    try {
        return Get-NetAdapter | Where-Object { $_.Status -ne 'Disabled' -and $_.InterfaceDescription -match 'Wi-Fi|Wireless' } | Select-Object -First 1
    } catch {
        return $null
    }
}

function Get-CurrentSSID {
    try {
        $result = netsh wlan show interfaces 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        $line = $result | Select-String '^\s*SSID\s*:\s*(.+)$'
        if ($line) { return ($line.Matches[0].Groups[1].Value).Trim() }
    } catch {}
    return $null
}

# Auto-elevate to Administrator if not already running as one
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}


# ---- Settings you can tweak ----
$PingTarget      = "8.8.8.8"   # Google DNS, reliable uptime target
$PingTimeoutSec  = 3
$FailsBeforeFix  = 3           # how many failed pings in a row before it acts
$CheckIntervalSec = 5          # seconds between checks

Write-Host "=== Wi-Fi Auto-Reconnect Monitor ===" -ForegroundColor Cyan
Write-Host "Pinging $PingTarget every $CheckIntervalSec seconds. Will auto-fix after $FailsBeforeFix failed checks in a row." -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop.`n"

$failCount = 0

function Reconnect-Wifi {
    $ssid = Get-CurrentSSID
    Write-Host "$(Get-Date -Format 'HH:mm:ss') -- Connection appears dead. Reconnecting..." -ForegroundColor Yellow

    # Same effect as clicking the Wi-Fi icon and hitting Disconnect/Connect
    netsh wlan disconnect 2>$null | Out-Null
    Start-Sleep -Seconds 2

    if ($ssid) {
        netsh wlan connect name="$ssid" 2>$null | Out-Null
        Write-Host "$(Get-Date -Format 'HH:mm:ss') -- Reconnect attempted to '$ssid'." -ForegroundColor Green
    } else {
        # Fallback: fully reset the Wi-Fi adapter (needs Admin)
        Write-Host "$(Get-Date -Format 'HH:mm:ss') -- No SSID found, resetting adapter instead (requires Admin)." -ForegroundColor Yellow
        $adapter = Get-WifiAdapter
        if ($adapter) {
            Disable-NetAdapter -Name $adapter.Name -Confirm:$false
            Start-Sleep -Seconds 2
            Enable-NetAdapter -Name $adapter.Name -Confirm:$false
        }
    }

    Start-Sleep -Seconds 5  # give it time to re-associate before we check again
}

while ($true) {
    $ok = Test-Connection -ComputerName $PingTarget -Count 1 -Quiet -TimeoutSeconds $PingTimeoutSec -ErrorAction SilentlyContinue

    if ($ok) {
        if ($failCount -gt 0) {
            Write-Host "$(Get-Date -Format 'HH:mm:ss') -- Connection OK again." -ForegroundColor Green
        }
        $failCount = 0
    } else {
        $failCount++
        Write-Host "$(Get-Date -Format 'HH:mm:ss') -- Ping failed ($failCount/$FailsBeforeFix)." -ForegroundColor DarkYellow

        if ($failCount -ge $FailsBeforeFix) {
            Reconnect-Wifi
            $failCount = 0
        }
    }

    Start-Sleep -Seconds $CheckIntervalSec
}
