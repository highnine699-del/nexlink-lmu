$ref1 = [ref]$null
$ref2 = [ref]$null
$targetFile = Join-Path $PSScriptRoot 'NexLink-WPF.ps1'
try {
    [System.Management.Automation.Language.Parser]::ParseFile($targetFile, $ref1, $ref2)
    Write-Host 'NEXLINK_PARSE_OK'
}
catch {
    Write-Host 'NEXLINK_PARSE_ERROR'
    Write-Host $_.Exception.Message
    exit 1
}
