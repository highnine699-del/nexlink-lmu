@echo off
:: NexLink requires Administrator rights to control Wi-Fi adapters.
:: This batch file requests elevation automatically, then runs the script.
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%~dp0NexLink-WPF.ps1""' -Verb RunAs"
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0NexLink-WPF.ps1"
