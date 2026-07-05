Set-StrictMode -Off
$ErrorActionPreference='Stop'
Set-Location -LiteralPath 'c:\Users\AY ADVANCE TECH\Documents\VIBE_CODER\wifi setup'
$p = Get-Process -Name 'LMU-AutoConnect' -ErrorAction SilentlyContinue
if ($p) { $p | Stop-Process -Force; Start-Sleep -Seconds 1; Write-Host 'PROCESS_STOPPED' } else { Write-Host 'NO_PROCESS' }
Import-Module (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Modules\ps2exe\ps2exe.psd1') -Force -Verbose
Invoke-ps2exe -inputFile '.\LMU-AutoConnect-GUI.ps1' -outputFile '.\LMU-AutoConnect.exe' -noConsole -requireAdmin -icon '.\wifi_icon.ico' -title 'LMU Auto-Connect' -version '1.0.0.0'
if (Test-Path '.\LMU-AutoConnect.exe') { Get-Item .\LMU-AutoConnect.exe | Select-Object Name,Length,LastWriteTime | Format-List }
