Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath 'C:\Users\AY ADVANCE TECH\Downloads\wifi setup'
$dest = Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Modules\ps2exe'
New-Item -ItemType Directory -Path $dest -Force | Out-Null
$zip = Join-Path $env:TEMP 'ps2exe.zip'
$extract = Join-Path $env:TEMP 'ps2exe_extract'
if (Test-Path $zip) { Remove-Item $zip -Force }
if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
Write-Host 'DOWNLOADING'
Invoke-WebRequest -Uri 'https://github.com/MScholtes/PS2EXE/archive/refs/heads/master.zip' -OutFile $zip
Write-Host 'EXTRACTING'
Expand-Archive -Path $zip -DestinationPath $extract -Force
Write-Host 'LOCATING PSD1'
$psd1 = Get-ChildItem -Path $extract -Recurse -Filter 'ps2exe.psd1' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $psd1) {
    Write-Host 'PSD1_NOT_FOUND'
    Get-ChildItem -Path $extract -Recurse | Select-Object FullName | Out-File -FilePath (Join-Path $env:TEMP 'ps2exe_structure.txt')
    Write-Host 'WROTE_STRUCTURE'
    exit 2
}
$moduleRoot = Split-Path -Parent $psd1.FullName
Write-Host 'PSD1_FOUND:' $psd1.FullName
Write-Host 'COPYING'
Copy-Item -Path (Join-Path $moduleRoot '*') -Destination $dest -Recurse -Force
Write-Host 'UNBLOCKING'
Get-ChildItem -Path $dest -Recurse | Unblock-File -ErrorAction SilentlyContinue
Write-Host 'IMPORTING'
Import-Module "$dest\ps2exe.psd1" -Force -Verbose
Write-Host 'VERIFY_CMD'
Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue | Format-List | Out-String | Write-Host
if (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue) {
    Write-Host 'COMPILE_START'
    Invoke-ps2exe -inputFile '.\LMU-AutoConnect-GUI.ps1' -outputFile '.\LMU-AutoConnect.exe' -noConsole -requireAdmin -title 'LMU Auto-Connect' -version '1.0.0.0'
    if (Test-Path '.\LMU-AutoConnect.exe') { Write-Host 'EXE_CREATED' } else { Write-Host 'EXE_NOT_CREATED' }
}
else {
    Write-Host 'INVOKE_PSKU_NOT_FOUND'
}
