$ref1 = [ref]$null
$ref2 = [ref]$null
try {
    [System.Management.Automation.Language.Parser]::ParseFile('.\NexLink-WPF.ps1', $ref1, $ref2)
    Write-Host 'NEXLINK_PARSE_OK'
}
catch {
    Write-Host 'NEXLINK_PARSE_ERROR'
    Write-Host $_.Exception.Message
    exit 1
}
