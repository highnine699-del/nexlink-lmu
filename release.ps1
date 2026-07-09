# release.ps1
# One-command release pipeline for NexLink.
# Usage: .\release.ps1                          (auto-computes next patch version, asks to confirm)
#        .\release.ps1 -Version 1.4.0           (skips the prompt, uses this version directly)
#        .\release.ps1 -Notes "Fixed the thing" (either form can add release notes)

param(
    [string]$Version,

    [string]$Notes = "Bug fixes and improvements"
)

$ErrorActionPreference = 'Stop'
# PowerShell 7.3+ treats any stderr line from a native command as a
# terminating error when $ErrorActionPreference is 'Stop'. gh CLI writes its
# normal success messages (e.g. "Logged in to github.com") to stderr, which
# would otherwise kill this script even on success. Harmless no-op on older
# PowerShell versions that don't have this setting.
$global:PSNativeCommandUseErrorActionPreference = $false
$ProjectDir = "c:\Users\AY ADVANCE TECH\Documents\VIBE_CODER\wifi setup"
$UpdatesRepoDir = "c:\Users\AY ADVANCE TECH\Documents\VIBE_CODER\nexlink-updates"

Set-Location $ProjectDir

# 0. Sanity checks before touching anything (moved up front because version
# resolution below now needs a working `gh` to ask GitHub what's actually
# been released).
if (-not (Test-Path $UpdatesRepoDir)) {
    Write-Host "ERROR: nexlink-updates repo not found at $UpdatesRepoDir" -ForegroundColor Red
    Write-Host "Clone it first: git clone https://github.com/highnine699-del/nexlink-updates.git" -ForegroundColor Yellow
    exit 1
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: GitHub CLI (gh) not found. Install with: winget install --id GitHub.cli" -ForegroundColor Red
    exit 1
}
$ghAuthCheck = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Not logged into GitHub CLI. Run: gh auth login" -ForegroundColor Red
    exit 1
}

# 1. Resolve version: use -Version if passed, otherwise ask GitHub what the
# latest published release actually is (source of truth - never goes stale,
# unlike parsing $NexLinkVersion out of a local file that could've been
# reverted, overwritten, or edited on a different machine), bump the patch
# digit, and confirm with the user.
if (-not $Version) {
    $latestTag = gh release view --repo "highnine699-del/nexlink-updates" --json tagName -q ".tagName" 2>$null
    if (-not $latestTag) {
        Write-Host "ERROR: Could not fetch the latest release from GitHub to auto-compute next version." -ForegroundColor Red
        Write-Host "Pass one explicitly: .\release.ps1 -Version 1.3.1" -ForegroundColor Yellow
        exit 1
    }
    $currentVersion = $latestTag.TrimStart("v")
    $parts = $currentVersion.Split('.')
    $major = [int]$parts[0]
    $minor = [int]$parts[1]
    $patch = [int]$parts[2]
    $suggestedVersion = "$major.$minor.$($patch + 1)"

    Write-Host "`nLatest published release: $currentVersion" -ForegroundColor Gray
    Write-Host "Next patch:                $suggestedVersion" -ForegroundColor Gray
    $inputVersion = Read-Host "Press Enter to accept, or type a version (e.g. 1.4.0 / 2.0.0)"

    if ([string]::IsNullOrWhiteSpace($inputVersion)) {
        $Version = $suggestedVersion
    }
    else {
        $Version = $inputVersion.Trim()
    }
}

Write-Host "`n=== NexLink Release Pipeline: v$Version ===" -ForegroundColor Cyan

# 2. Stop any running instance so the exe isn't locked.
# NexLink.exe runs elevated (-requireAdmin) so Stop-Process from this
# unelevated shell fails with Access Denied. Ask it to exit gracefully via
# the signal file it polls every tick (~5s), then fall back to Stop-Process
# only if it's still alive after waiting - which will still fail if this
# shell isn't elevated, but by then the graceful path should have worked.
$runningProc = Get-Process -Name "NexLink*" -ErrorAction SilentlyContinue
if ($runningProc) {
    Write-Host "Asking running NexLink instance to exit gracefully..." -ForegroundColor Gray
    $exitSignalFile = Join-Path $env:TEMP "NexLink.exitsignal"
    New-Item -Path $exitSignalFile -ItemType File -Force | Out-Null

    $waited = 0
    while ($waited -lt 10 -and (Get-Process -Name "NexLink*" -ErrorAction SilentlyContinue)) {
        Start-Sleep -Seconds 1
        $waited++
    }

    $stillRunning = Get-Process -Name "NexLink*" -ErrorAction SilentlyContinue
    if ($stillRunning) {
        Write-Host "Graceful exit didn't take effect after ${waited}s - falling back to Stop-Process." -ForegroundColor Yellow
        Write-Host "(If this fails with Access Denied, close NexLink manually via its tray icon and rerun.)" -ForegroundColor Yellow
        $stillRunning | Stop-Process -Force
    }
    else {
        Write-Host "  Closed gracefully after ${waited}s." -ForegroundColor Gray
    }
}
Start-Sleep -Seconds 1

# 3. Bump version in the script
Write-Host "`n[1/8] Bumping version in NexLink-WPF.ps1..." -ForegroundColor Green
$scriptContent = Get-Content ".\NexLink-WPF.ps1" -Raw
$scriptContent = $scriptContent -replace '\$NexLinkVersion = "[\d\.]+"', "`$NexLinkVersion = `"$Version`""
Set-Content ".\NexLink-WPF.ps1" -Value $scriptContent -NoNewline

# 4. Bump version in the installer script
Write-Host "[2/8] Bumping AppVersion in NexLink-installer.iss..." -ForegroundColor Green
$issContent = Get-Content ".\NexLink-installer.iss" -Raw
$issVersion = "$Version.0"
$issContent = $issContent -replace 'AppVersion=[\d\.]+', "AppVersion=$issVersion"
Set-Content ".\NexLink-installer.iss" -Value $issContent -NoNewline

# 5. Recompile the exe
Write-Host "[3/8] Recompiling NexLink.exe..." -ForegroundColor Green
Remove-Item ".\NexLink.exe" -ErrorAction SilentlyContinue
Import-Module (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Modules\ps2exe\ps2exe.psd1') -Force
Invoke-ps2exe -inputFile '.\NexLink-WPF.ps1' -outputFile '.\NexLink.exe' -noConsole -requireAdmin -icon '.\wifi_icon.ico' -title 'NexLink' -version $issVersion
if (-not (Test-Path ".\NexLink.exe")) {
    Write-Host "ERROR: NexLink.exe was not created. Aborting release." -ForegroundColor Red
    exit 1
}

# 6. Rebuild the installer
Write-Host "[4/8] Rebuilding installer..." -ForegroundColor Green
$innoPath = "C:\Users\AY ADVANCE TECH\AppData\Local\Programs\Inno Setup 6\ISCC.exe"
& $innoPath ".\NexLink-installer.iss"
if (-not (Test-Path ".\NexLink-Installer.exe")) {
    Write-Host "ERROR: NexLink-Installer.exe was not created. Aborting release." -ForegroundColor Red
    exit 1
}

# 7. Verify the version actually took (catches the exact bug we hit before -
# a stale exe silently not matching the source it was supposedly built from)
Write-Host "[5/8] Verifying build..." -ForegroundColor Green
$verifyLog = Join-Path $ProjectDir "lmu_autoconnect.log"
$exeInfo = Get-Item ".\NexLink.exe"
$secondsOld = ((Get-Date) - $exeInfo.LastWriteTime).TotalSeconds
if ($secondsOld -gt 60) {
    Write-Host "ERROR: NexLink.exe timestamp is more than 60 seconds old - build may not have completed correctly." -ForegroundColor Red
    exit 1
}
Write-Host "  NexLink.exe confirmed fresh (built $([math]::Round($secondsOld))s ago)." -ForegroundColor Gray

# 8. Compute hash
Write-Host "[6/8] Computing SHA256..." -ForegroundColor Green
$hash = (Get-FileHash -Path ".\NexLink-Installer.exe" -Algorithm SHA256).Hash
Write-Host "  Hash: $hash" -ForegroundColor Gray

# 9. Publish the GitHub release with the installer attached, via gh CLI
Write-Host "[7/8] Publishing GitHub release v$Version..." -ForegroundColor Green
$releaseAssetPath = ".\NexLink-Installer.exe"
gh release create "v$Version" $releaseAssetPath `
    --repo "highnine699-del/nexlink-updates" `
    --title "v$Version" `
    --notes $Notes
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: gh release create failed. Check output above." -ForegroundColor Red
    exit 1
}

# 10. Update latest.json in the local nexlink-updates clone and push
Write-Host "[8/8] Updating latest.json and pushing..." -ForegroundColor Green
$manifest = @{
    version       = $Version
    installer_url = "https://github.com/highnine699-del/nexlink-updates/releases/download/v$Version/NexLink-Installer.exe"
    sha256        = $hash.ToUpper()
    notes         = $Notes
} | ConvertTo-Json

Set-Content -Path (Join-Path $UpdatesRepoDir "latest.json") -Value $manifest -Encoding ascii -NoNewline

Push-Location $UpdatesRepoDir
git add latest.json
git commit -m "v$Version"
git push
Pop-Location

# 11. Commit the version bump to the main source repo too
git add NexLink-WPF.ps1 NexLink-installer.iss
git commit -m "v$Version release"
git push

Write-Host "`n=== Release v$Version complete ===" -ForegroundColor Cyan
Write-Host "Anyone running an older version will see the update banner within 24 hours, or on next launch." -ForegroundColor Gray
