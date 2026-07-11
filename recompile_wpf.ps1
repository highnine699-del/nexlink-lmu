Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

$p = Get-Process -Name 'NexLink' -ErrorAction SilentlyContinue
if ($p) { $p | Stop-Process -Force; Start-Sleep -Seconds 1; Write-Host 'PROCESS_STOPPED' } else { Write-Host 'NO_PROCESS' }

# Read the version dynamically from the source file so the compiled exe
# always matches what's in NexLink-WPF.ps1 — never hardcoded here.
$versionLine = Select-String -Path '.\NexLink-WPF.ps1' -Pattern '\$NexLinkVersion = "([\d\.]+)"' | Select-Object -First 1
if (-not $versionLine) {
    Write-Host 'ERROR: Could not find $NexLinkVersion in NexLink-WPF.ps1' -ForegroundColor Red
    exit 1
}
$appVersion = $versionLine.Matches[0].Groups[1].Value + '.0'
Write-Host "Compiling version $appVersion from NexLink-WPF.ps1..." -ForegroundColor Cyan

Import-Module (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Modules\ps2exe\ps2exe.psd1') -Force -Verbose
Invoke-ps2exe -inputFile '.\NexLink-WPF.ps1' -outputFile '.\NexLink.exe' -noConsole -requireAdmin -icon '.\wifi_icon.ico' -title 'NexLink' -version $appVersion
if (Test-Path '.\NexLink.exe') { Get-Item .\NexLink.exe | Select-Object Name, Length, LastWriteTime | Format-List }
