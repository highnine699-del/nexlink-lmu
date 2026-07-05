$ref1 = [ref]$null
$ref2 = [ref]$null
try {
    [System.Management.Automation.Language.Parser]::ParseFile('LMU-AutoConnect-GUI.ps1', $ref1, $ref2)
    Write-Host 'GUI_PARSE_OK'
}
catch {
    Write-Host 'GUI_PARSE_ERROR'
    Write-Host $_.Exception.Message
    exit 1
}
try {
    [System.Management.Automation.Language.Parser]::ParseFile('LMU-AutoConnect.ps1', $ref1, $ref2)
    Write-Host 'CONSOLE_PARSE_OK'
}
catch {
    Write-Host 'CONSOLE_PARSE_ERROR'
    Write-Host $_.Exception.Message
    exit 1
}
