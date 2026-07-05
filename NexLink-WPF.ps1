# Copyright (c) 2026 Odetayo Josiah Inioluwa. All rights reserved.
# Licensed under the terms in LICENSE.md — see repository
#
# NexLink-WPF.ps1
# WPF-based UI overhaul with all backend logic preserved from NexLink-GUI.ps1
#
# HOW TO RUN (important - do NOT double-click the file):
#   1. Right-click Start -> "Windows PowerShell (Admin)" or "Terminal (Admin)"
#   2. cd to the folder where this file is saved, e.g.: cd "Downloads\wifi setup"
#   3. If blocked, run once:  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   4. Then run:  .\NexLink-WPF.ps1

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

# ---------- Backend Functions (UNCHANGED from NexLink-GUI.ps1) ----------
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

# ---------- Settings ----------
$NexLinkVersion = "1.2.0"
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
$script:LastLoggedStatus = ""
$script:LastHealthyLogAt = [DateTime]::MinValue

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
            [System.Windows.Forms.MessageBox]::Show("No credentials entered. Exiting.", "NexLink") | Out-Null
            exit
        }
    }

    try {
        $data = Get-Content $CredFile -Raw | ConvertFrom-Json
    }
    catch {
        Add-Log "Credential file is unreadable or corrupt: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Credential file is unreadable or corrupt. Delete $CredFile and run again.", "NexLink") | Out-Null
        exit
    }

    if (-not $data.Username -or -not $data.Password) {
        Add-Log "Credential file is missing username or password field."
        [System.Windows.Forms.MessageBox]::Show("Credential file is missing required values.", "NexLink") | Out-Null
        exit
    }

    try {
        $securePass = ConvertTo-SecureString $data.Password
    }
    catch {
        Add-Log "Saved password could not be decrypted (DPAPI mismatch - different user/machine?): $($_.Exception.Message)"
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
    Add-Log "Restart-WifiConnection: current='$($currentWifiState.SSID)' ($($currentWifiState.Signal)%), target='$targetSsid'"
    if ($targetSsid -and -not (Test-WifiSwitchNeeded -TargetSsid $targetSsid -CurrentWifiState $currentWifiState)) {
        Add-Log "Restart-WifiConnection: switch not needed/allowed right now (cooldown or same network), skipping."
        return $currentWifiState.SSID
    }

    Add-Log "Disconnecting current Wi-Fi connection..."
    netsh wlan disconnect 2>$null | Out-Null
    Start-Sleep -Seconds 2
    if ($targetSsid) {
        Add-Log "Attempting to connect to '$targetSsid'..."
        if (Connect-ToWifiNetwork -Ssid $targetSsid) {
            Add-Log "Connected to '$targetSsid' successfully. Flushing DNS and resetting portal session."
            Clear-DnsCache
            $script:LastKnownSSID = $targetSsid
            $script:LastReconnectAt = Get-Date
            $script:PortalSession = $null
        }
        else {
            Add-Log "netsh connect to '$targetSsid' failed. Falling back to power-cycling the adapter."
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
        $preview = $content.Substring(0, [Math]::Min(120, $content.Length)) -replace '[\r\n]+', ' '
        Add-Log "Portal check returned unexpected content (first 120 chars): $preview"
        return 'LoggedOut'
    }
    catch {
        Add-Log "Portal connectivity check failed to connect: $($_.Exception.Message)"
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

# ---------- WPF UI Setup ----------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
    <Border Background="#0B0D13" CornerRadius="12" BorderBrush="#1F2937" BorderThickness="1">
        <Grid>
            <!-- Custom Title Bar -->
            <Grid Height="40" VerticalAlignment="Top" Background="#14171F">
                <TextBlock Text="NexLink" FontFamily="Segoe UI" FontSize="14" FontWeight="SemiBold" 
                           Foreground="#F5F5F7" VerticalAlignment="Center" Margin="16,0,0,0"/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,0,8,0">
                    <Button Name="MinimizeBtn" Content="─" Width="30" Height="30" 
                            Background="Transparent" Foreground="#9CA3AF" 
                            BorderThickness="0" FontFamily="Segoe UI" FontSize="16"
                            Cursor="Hand"/>
                    <Button Name="CloseBtn" Content="✕" Width="30" Height="30" 
                            Background="Transparent" Foreground="#9CA3AF" 
                            BorderThickness="0" FontFamily="Segoe UI" FontSize="14"
                            Cursor="Hand"/>
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
            
            <!-- Footer -->
            <Grid Height="30" VerticalAlignment="Bottom" Margin="16,0,16,8">
                <TextBlock Name="VersionText" Text="v1.2.0" 
                           FontFamily="Segoe UI" FontSize="10" 
                           Foreground="#6B7280" VerticalAlignment="Center" HorizontalAlignment="Left"/>
                <Button Name="SettingsBtn" Content="⚙" Width="24" Height="24" 
                        Background="Transparent" Foreground="#6B7280" 
                        BorderThickness="0" FontFamily="Segoe UI" FontSize="14"
                        Cursor="Hand" HorizontalAlignment="Right" VerticalAlignment="Center"/>
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
        $currentPoint = $_.GetPosition($this)
        $deltaX = $currentPoint.X - $script:dragStartPoint.X
        $deltaY = $currentPoint.Y - $script:dragStartPoint.Y
        $this.Left += $deltaX
        $this.Top += $deltaY
    }
})

# Close button
$closeBtn.Add_Click({
    $script:allowExit = $true
    $timer.Stop()
    $trayIcon.Visible = $false
    try { $script:InstanceMutex.ReleaseMutex() } catch {}
    $window.Close()
})

# Minimize button
$minimizeBtn.Add_Click({
    $window.WindowState = [System.Windows.WindowState]::Minimized
    $window.Hide()
    $trayIcon.ShowBalloonTip(1500, "NexLink", "Running quietly in background", [System.Windows.Forms.ToolTipIcon]::Info)
})

# ---------- Logging Functions ----------
$script:logLines = @()

function Add-Log($text) {
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $line = "[$timestamp] $text"
    $script:logLines += $line
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
        # Also trim in-memory array to prevent unbounded growth
        if ($script:logLines.Count -gt ($MaxLogLines * 2)) {
            $script:logLines = $script:logLines[-$MaxLogLines..-1]
        }
    }
    catch {}
}

# ---------- Status Update Function ----------
function Set-Status($text, $state) {
    $statusText.Text = $text
    $trayIcon.Text = "NexLink: $text"
    
    # Update orb color and animation based on state
    switch ($state) {
        "Connected" {
            $statusOrb.Fill = "#22D3AA"
            $statusOrb.Stroke = "#22D3AA"
            if ($pulseStoryboard) { try { $pulseStoryboard.Begin() } catch {} }
        }
        "Reconnecting" {
            $statusOrb.Fill = "#FBBF24"
            $statusOrb.Stroke = "#FBBF24"
            if ($pulseStoryboard) { try { $pulseStoryboard.Begin() } catch {} }
        }
        "Error" {
            $statusOrb.Fill = "#F43F5E"
            $statusOrb.Stroke = "#F43F5E"
            if ($pulseStoryboard) { try { $pulseStoryboard.Stop() } catch {} }
        }
        default {
            $statusOrb.Fill = "#6B7280"
            $statusOrb.Stroke = "#6B7280"
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
    $script:secondsToNextCheck = $CheckIntervalMs / 1000
    $timer.Interval = $CheckIntervalMs
    $timer.Start()
}

$actionButton.Add_Click({
    if ($script:ManuallyDisconnected) {
        Reconnect-Manually
    }
    else {
        Disconnect-Manually
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
$trayMenu.Items.Add("-") | Out-Null
$menuExit = $trayMenu.Items.Add("Exit")
$trayIcon.ContextMenuStrip = $trayMenu

$script:allowExit = $false

$menuShow.Add_Click({ 
    $window.Show(); 
    $window.WindowState = "Normal"; 
    $window.Activate() 
})
$trayIcon.Add_DoubleClick({ 
    $window.Show(); 
    $window.WindowState = "Normal"; 
    $window.Activate() 
})

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

$menuExit.Add_Click({
    $script:allowExit = $true
    $timer.Stop()
    $trayIcon.Visible = $false
    try { $script:InstanceMutex.ReleaseMutex() } catch {}
    $window.Close()
})

# ---------- Timer-driven check loop ----------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds($CheckIntervalMs)

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
            Set-Status "Switching Wi-Fi..." "Reconnecting"
            Restart-WifiConnection | Out-Null
            $script:wifiFailCount = 0
            $script:portalFailCount = 0
            $currentWifiState = Get-CurrentWifiState
        }

        $pingOk = Test-Connection -ComputerName $PingTarget -Count 1 -Quiet -ErrorAction SilentlyContinue

        if ($pingOk) {
            if ($script:wifiFailCount -gt 0) {
                Add-Log "Ping recovered after $script:wifiFailCount failure(s)."
            }
            $script:wifiFailCount = 0
            Update-KnownSSID | Out-Null
        }
        else {
            $script:wifiFailCount++
            Add-Log "Ping failed ($script:wifiFailCount/$WifiFailsBeforeFix) - target=$PingTarget"
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
                    $script:PortalRetryAfter = [DateTime]::MinValue
                }
                catch {
                    $script:portalFailCount++
                    $cooldownSeconds = [Math]::Min($PortalLoginRetryCooldownSec, 10 + ($script:portalFailCount * 5))
                    $script:PortalRetryAfter = $now.AddSeconds($cooldownSeconds)
                    Add-Log "Portal login FAILED ($script:portalFailCount). Retrying in $cooldownSeconds seconds: $($_.Exception.Message)"
                    Set-Status "Portal login error" "Error"
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
            Set-Status "Reconnecting..." "Reconnecting"
            $ssid = Restart-WifiConnection
            Add-Log "Wi-Fi reconnect attempted (SSID: $ssid)"
            $script:wifiFailCount = 0
            $script:portalFailCount = 0
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

        if ($script:portalFailCount -ge 2) {
            $timer.Interval = [TimeSpan]::FromMilliseconds([Math]::Min($CheckIntervalMs * $script:portalFailCount, 30000))
        }
        else {
            $timer.Interval = [TimeSpan]::FromMilliseconds($CheckIntervalMs)
        }
        $script:secondsToNextCheck = $timer.Interval.TotalMilliseconds / 1000
    }
    catch {
        Add-Log "ERROR: $($_.Exception.Message)"
        Set-Status "Error - see log" "Error"
    }
})

# ---------- Window Entrance Animation ----------
$window.Add_Loaded({
    # Fade-in animation
    $fadeIn = [System.Windows.Media.Animation.DoubleAnimation]::new(0, 1, [TimeSpan]::FromSeconds(0.25))
    $window.BeginAnimation([System.Windows.Window]::OpacityProperty, $fadeIn)

    Limit-LogFile
    $osInfo = try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { "unknown OS" }
    $adapterInfo = Get-WifiAdapter
    $adapterDesc = if ($adapterInfo) { "$($adapterInfo.Name) - $($adapterInfo.InterfaceDescription)" } else { "NOT FOUND" }
    Add-Log "===== Monitor started. Checking every $($CheckIntervalMs / 1000)s. ====="
    Add-Log "Version=$NexLinkVersion OS='$osInfo' Adapter='$adapterDesc'"
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
    $timer.Start()
})

# ---------- Advanced Panel ----------
$advancedXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="NexLink Advanced" 
        Width="500" Height="400"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen">
    <Border Background="#14171F" CornerRadius="8" BorderBrush="#1F2937" BorderThickness="1">
        <Grid>
            <!-- Title Bar -->
            <Grid Height="35" VerticalAlignment="Top" Background="#1F2937">
                <TextBlock Text="Advanced" FontFamily="Segoe UI" FontSize="12" FontWeight="SemiBold" 
                           Foreground="#F5F5F7" VerticalAlignment="Center" Margin="12,0,0,0"/>
                <Button Name="AdvCloseBtn" Content="✕" Width="30" Height="30" 
                        Background="Transparent" Foreground="#9CA3AF" 
                        BorderThickness="0" FontFamily="Segoe UI" FontSize="12"
                        Cursor="Hand" HorizontalAlignment="Right" Margin="0,0,8,0"/>
            </Grid>
            
            <!-- Log Viewer -->
            <TextBox Name="LogViewer" 
                     Background="#0B0D13" Foreground="#22D3AA" 
                     BorderBrush="#1F2937" BorderThickness="1"
                     FontFamily="Consolas" FontSize="10"
                     VerticalAlignment="Top" Margin="12,45,12,0" Height="220"
                     TextWrapping="Wrap" IsReadOnly="True" VerticalScrollBarVisibility="Auto"/>
            
            <!-- Buttons -->
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" 
                        VerticalAlignment="Bottom" Margin="0,0,0,12">
                <Button Name="ReenterCredBtn" Content="Re-enter Credentials" Width="140" Height="32"
                        Background="#374151" Foreground="#F5F5F7" BorderThickness="0"
                        FontFamily="Segoe UI" FontSize="11" Margin="0,0,8,0" Cursor="Hand"/>
                <Button Name="OpenLogBtn" Content="Open Log File" Width="120" Height="32"
                        Background="#374151" Foreground="#F5F5F7" BorderThickness="0"
                        FontFamily="Segoe UI" FontSize="11" Cursor="Hand"/>
            </StackPanel>
            
            <!-- Version -->
            <TextBlock Name="AdvVersionText" Text="v1.2.0" 
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
$openLogBtn = $advWindow.FindName("OpenLogBtn")

# Advanced window dragging
$advWindow.Add_MouseLeftButtonDown({
    $this.DragMove()
})

# Close advanced panel
$advCloseBtn.Add_Click({
    $advWindow.Hide()
})

# Re-enter credentials
$reenterCredBtn.Add_Click({
    Remove-Item $CredFile -ErrorAction SilentlyContinue
    Get-PortalCredential | Out-Null
    Add-Log "Credentials re-entered by user."
    [System.Windows.Forms.MessageBox]::Show("Credentials updated successfully.", "NexLink") | Out-Null
})

# Open log file
$openLogBtn.Add_Click({
    if (Test-Path $LogFile) {
        Start-Process notepad.exe $LogFile
    }
    else {
        [System.Windows.Forms.MessageBox]::Show("Log file not found.", "NexLink") | Out-Null
    }
})

# Update log viewer when advanced panel opens
$settingsBtn.Add_Click({
    $advLogViewer.Text = $script:logLines -join "`r`n"
    $advLogViewer.ScrollToEnd()
    $advWindow.Show() | Out-Null
})

# ---------- Show Window ----------
$window.ShowDialog() | Out-Null
