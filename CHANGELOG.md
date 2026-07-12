# NexLink — Complete Changelog from v1.3.10

Every change made to every file, from the v1.3.10 release commit onwards.
Organised by version/commit, then by file, then by individual line-level change.
Use the commit hash to revert any specific change: `git revert <hash>`

---

## Current version: v1.3.15 (HEAD `f5c362a`)

---

## Git commit history (newest → oldest)

| Hash | Description |
|------|-------------|
| `f5c362a` | docs: add reconnecting screenshots, wire in correct fixing-your-connection screenshot |
| `c5fc658` | v1.3.15 release |
| `16a2e48` | docs: wire in real reconnecting screenshot |
| `f608aea` | Final audit fixes: correctness, cleanup, pipeline improvements |
| `c49bbf8` | Cleanup and hardening: post-rotation housekeeping |
| `7bffd14` | v1.3.14 release |
| `f030772` | Hardening pass: 24-item audit fixes |
| `316ee9b` | docs: Add SmartScreen warning screenshots and restructure guide |
| `08859b9` | landing page changes (addendum fixes) |
| `14dd5ff` | Add NexLink landing page (17-phase build) |
| `04264af` | Sync repo with deployed device-token security fix |
| `2a659c3` | Repo cleanup: remove dead WinForms-era files |
| `257be5b` | v1.3.13 release |
| `b72685f` | v1.3.12 release |
| `74a3d69` | v1.3.11 release |
| `ce3ea56` | v1.3.10 release ← baseline |
| `451dedd` | Snapshot for debugging Restart-WifiConnection |

---

## v1.3.10 → v1.3.11 → v1.3.12 → v1.3.13 (version bumps only)

Commits `ce3ea56`, `74a3d69`, `b72685f`, `257be5b`

- `NexLink-WPF.ps1` — `$NexLinkVersion` bumped through `1.3.10` → `1.3.11` → `1.3.12` → `1.3.13`
- `NexLink-installer.iss` — `AppVersion` bumped through `1.3.10.0` → `1.3.11.0` → `1.3.12.0` → `1.3.13.0`
- `latest.json` (nexlink-updates repo) — version, installer_url, sha256 updated each release

---

## Snapshot commit (`451dedd`) — between v1.3.9 and v1.3.13

- `NexLink-WPF.ps1` — debugging snapshot of `Restart-WifiConnection` logic
- `DEPLOYMENT_GUIDE.md` — **CRITICAL**: this commit contained `ECDSA_D` private key value in plain text (`[REDACTED-ROTATED-KEY]`). Key was subsequently rotated. This commit is permanently in public git history.

---

## Repo cleanup (`2a659c3`)

### Files deleted:
- `WifiAutoReconnect.ps1` — deprecated console prototype, superseded by NexLink-WPF.ps1
- `LMU-AutoConnect.ps1` — deprecated console predecessor
- `LMU-AutoConnect-installer.iss` — old product installer script
- `LMU-AutoConnect.exe` — old compiled binary
- `Run-LMU-AutoConnect.bat` — dead file, target script didn't exist
- `ParseScripts.ps1` — only parsed old LMU scripts, not NexLink-WPF.ps1
- `generate_icon.py` — one-time icon generation script, output already exists
- `install_ps2exe_from_github.ps1` — one-time setup script with wrong paths
- `recompile_nexlink.ps1` — deprecated, hardcoded to version 1.2.0.0
- `recompile_with_icon.ps1` — deprecated, referenced missing LMU-AutoConnect-GUI.ps1

---

## Landing page — initial build (`14dd5ff`)

### Files created:
- `docs/index.html` — full 17-section landing page
- `docs/style.css` — all styles, design tokens matching app
- `docs/script.js` — live GitHub API fetch, scroll-reveal, FAQ accordion, security flow animation
- `docs/favicon.ico` — copied from wifi_icon.ico
- `docs/og-image.png` — copied from wifi_256.png (placeholder)
- `docs/screenshots/` — directory created

### Key features built:
- Hero with mini app mockup, pulsing orb, download button
- Async font loading (preload + noscript)
- `<main>` landmark, all `<img>` with width/height and loading=lazy
- Security flow diagram with CSS stagger animation
- FAQ accordion (vanilla JS)
- SmartScreen warning section with step-by-step guide
- Roadmap, release notes (live from GitHub API), before/after comparison
- Open Graph meta tags for WhatsApp/Telegram previews
- `prefers-reduced-motion` support throughout

---

## Landing page addendum fixes (`08859b9`)

### `docs/index.html`:
- Added personal note section ("Hi, I'm Josiah...") between Why and Trust sections
- Added "How the connection monitor works" flowchart card inside Trust section
- First FAQ question changed to "Does NexLink store my password?" (was "Is this safe?")
- Security flow diagram nodes each given `data-flow-index` attribute for CSS stagger
- Hero: added `<p class="hero-context">Made for Landmark University students.</p>` above headline
- Download button text changed from "Download for Windows" to "Download NexLink"
- Added "Windows 10 & 11" sub-line under download button
- Added compact 4-step install flow (Download → Open → Enter credentials once → Done)
- `og:url` corrected to `https://highnine699-del.github.io/nexlink-lmu/`
- All emoji in security flow (🔑 🔒 💾 ⚙️ 🌐) replaced with inline SVGs
- SmartScreen badge emoji (⚠) replaced with inline SVG warning triangle
- `<ol class="install-steps">` with invalid `<span>` children replaced with `<div role="list">`

### `docs/style.css`:
- Added `.hero-context` style (small uppercase label above headline)
- Added `.install-steps`, `.install-step`, `.install-arrow`, `.install-num` styles
- Added `.personal-section`, `.personal-note` styles
- Added `.monitor-card`, `.monitor-card-label`, `.monitor-flow`, `.monitor-node` styles
- Added `.smartscreen-step-group` for two-column step layout
- Added `.flow-icon` as flex container (replacing emoji font-size approach)
- Security flow animation: `[data-flow-index]` starts at opacity:0 translateY(8px), `#security.flow-visible` reveals each with 120ms stagger
- `prefers-reduced-motion` extended to cover security flow nodes

### `docs/script.js`:
- Added `initSecurityFlowAnimation()` — IntersectionObserver adds `.flow-visible` to `#security`
- `FALLBACK_VER` changed from `'v1.3.13'` to `'latest'`
- `initSecurityFlowAnimation()` called in `DOMContentLoaded`

---

## SmartScreen screenshots (`316ee9b`)

### `docs/index.html`:
- SmartScreen section restructured: single placeholder replaced with two `<figure>` elements
- Step 1 and Step 2 each get their own screenshot below the step label
- `Screenshot SmartScreen warning .png` wired to Step 1 figure
- `Screenshot SmartScreen warning 2.png` wired to Step 2 figure
- SmartScreen steps changed from flex row to two `smartscreen-step-group` columns

### `docs/screenshots/` — files added:
- `Screenshot SmartScreen warning .png` (Step 1: initial dialog with More info link)
- `Screenshot SmartScreen warning 2.png` (Step 2: Run anyway button visible)

---

## Device-token security fix sync (`04264af`)

### `NexLink-WPF.ps1` — changes applied (were already live but not committed):
- `Invoke-LicenseActivation` — now expects `deviceToken` in server response; rejects if absent
- `Save-ProLicense` — now stores `DeviceToken` field alongside `LicenseKey` and `MachineHash`
- `Verify-DeviceToken` — new function: verifies ECDSA signature over `reference:machineHash`
- Startup license check — now calls `Verify-DeviceToken` instead of bare `MachineHash` equality check
- `$script:ProPublicKey` — comment updated to note MANUAL ACTION REQUIRED

### `cloudflare_worker.js` — changes applied (were already live but not committed):
- `verifyLicenseSignature` function added — verifies ECDSA sig against public key
- `/activate` endpoint: now calls `verifyLicenseSignature` before trusting `machineHash`
- `signDeviceToken` function added — signs `reference:machineHash` with private key
- `/activate` now returns `{ deviceToken }` in response body
- Comment block explains why verification not regeneration is the correct check

---

## Hardening pass — 24-item audit fixes (`f030772`)

### `NexLink-WPF.ps1`:

**Critical crash fix (was the silent-exit bug):**
- `Reconnect-Manually` — `$timer.Interval = $CheckIntervalMs` (int, threw ArgumentException) changed to `$timer.Interval = [TimeSpan]::FromMilliseconds($CheckIntervalMs)`. Every manual reconnect attempt previously crashed the app silently.

**Startup / process lifecycle:**
- `$script:allowExit` flag wired into `window.Add_Closed` handler — prevents double `InvokeShutdown()` when `Invoke-GracefulExit` calls `$window.Close()` then the Closed event also fires
- Startup license check block (`Get-ProLicense` + `Verify-ProLicense`) wrapped in outer `try/catch` — prevents silent exit before window appears if cred file is corrupt
- `Invoke-PortalLogin` — explicit `throw "Portal login failed: all URLs exhausted..."` added at end of function — prevents silent `$null` return that caused misleading generic `ERROR:` log entry

**Reliability fixes:**
- `Restart-WifiConnection` — now returns `$script:LastKnownSSID` (actually connected SSID) instead of original `$targetSsid` which could differ after multi-network scan
- `Get-CurrentSSID` — regex tightened: `'^\s*SSID\s*:\s*(.+)$'` → `'^\s{1,4}SSID\s*:\s*(.+)$'` — prevents false match on `BSSID` line in netsh output
- `Limit-LogFile` — in-memory array trim now uses `$script:LogLock` (`Monitor::Enter/Exit`) — fixes race condition with `Add-Log` called from background threads
- `PowerModeChanged` handler — entire body wrapped in `try/catch` with `Write-Host` fallback — prevents silent failure if function lookup fails across the `Register-ObjectEvent` runspace boundary
- `$script:dragStartPoint` null guard added to `MouseMove` handler: `if (-not $script:dragStartPoint) { return }` — prevents crash if `MouseMove` fires before `MouseLeftButtonDown` sets the point

**Resource management:**
- `Apply-Theme` XamlReader — `$reader.Dispose()` moved into `finally` block — prevents resource leak if `XamlReader::Load` throws on a bad theme colour value

**Thread safety:**
- `Add-Log` — `[System.Threading.Monitor]::Enter/Exit($script:LogLock)` wraps the `$script:logLines += $line` array append — prevents concurrent modification from background event handlers

**Event handlers:**
- `NetworkAddressChanged` handler — try/catch with `Write-Host` fallback confirmed correct (already present)

### `cloudflare_worker.js`:
- `verifyPaystackTransaction` — added `if (!response.ok) { return { success: false } }` before `.json()` call — prevents silent failure / misleading error when Paystack returns non-200 (rate limit, timeout, etc.)

### `recompile_wpf.ps1`:
- `Set-Location` changed from hardcoded `'c:\Users\AY ADVANCE TECH\Documents\VIBE_CODER\wifi setup'` to `$PSScriptRoot` — works on any machine
- Version number removed from hardcoded `'1.3.6.0'` — now read dynamically from `NexLink-WPF.ps1` using `Select-String` regex so compiled exe always matches source

### `release.ps1`:
- `$ProjectDir` changed from hardcoded absolute path to `$PSScriptRoot`
- `$UpdatesRepoDir` changed from hardcoded absolute path to `Join-Path (Split-Path $PSScriptRoot -Parent) "nexlink-updates"`
- Inno Setup path changed from hardcoded `C:\Users\AY ADVANCE TECH\AppData\Local\Programs\Inno Setup 6\ISCC.exe` to a search through three standard locations: `$env:ProgramFiles`, `${env:ProgramFiles(x86)}`, `$env:LOCALAPPDATA`

### `test_syntax.ps1`:
- `ParseFile` path changed from `'.\NexLink-WPF.ps1'` (relative — breaks if invoked from wrong directory) to `Join-Path $PSScriptRoot 'NexLink-WPF.ps1'`

### `Run-NexLink.bat`:
- Added `net session >nul 2>&1` elevation check
- If not elevated: auto-relaunches via `Start-Process -Verb RunAs` instead of running unelevated and silently failing at `Disable-NetAdapter`/`Enable-NetAdapter`

### `.gitignore`:
- `DEPLOYMENT_GUIDE.md` added (contains private key values — must never commit)
- 30 vestigial debug-script patterns removed: `get_info*.py`, `check_files.py`, `run_ps_*.py`, `verify_timestamps.py`, `manual_recompile.ps1` etc.

### `DEPLOYMENT_GUIDE.md`:
- `ECDSA_D` private key value (`zxsMY80s...`) redacted — replaced with instruction to copy from file
- Version references updated from `1.3.6` to `1.3.13`

### `docs/index.html`:
- Font `<link rel="stylesheet">` replaced with `<link rel="preload" as="style" onload="this.onload=null;this.rel='stylesheet'">` + `<noscript>` fallback — eliminates 310ms render-blocking (Lighthouse improvement)
- All six `<img>` tags given explicit `width` and `height` attributes — eliminates CLS 0.007
- Below-fold images given `loading="lazy"` — defers download until near viewport
- `og:url` corrected from `/nexlink-updates/` to `/nexlink-lmu/`
- `<main>` landmark added wrapping all page content before `<footer>`

### `docs/style.css`:
- `.footer-version` — `opacity: 0.5` removed, `color: #B0B7C3` — fixes WCAG AA contrast failure
- `.footer-copy` — `opacity: 0.4` removed, `color: #B0B7C3` — fixes WCAG AA contrast failure
- `.release-date` — `opacity: 0.6` removed, `color: #B0B7C3` — fixes WCAG AA contrast failure
- `.flow-node small` — `opacity: 0.7` removed, `color: #B0B7C3` — fixes WCAG AA contrast failure
- Base `a` rule changed to `text-decoration: underline` — links no longer rely on colour alone to be distinguishable (WCAG 1.4.1)
- Navigation/button links (`.footer-links a`, `.monitor-source-link`, `.btn-primary`) explicitly opt out of underline

### `docs/script.js`:
- `FALLBACK_VER` changed from `'v1.3.13'` to `'latest'` — honest fallback when GitHub API unavailable

---

## v1.3.14 release (`7bffd14`)

- `NexLink-WPF.ps1` — `$NexLinkVersion` bumped to `1.3.14`
- `NexLink-installer.iss` — `AppVersion` bumped to `1.3.14.0`
- `latest.json` — version, installer_url, sha256 updated

---

## ECDSA key rotation + post-rotation housekeeping (`c49bbf8`)

### Security event:
- Old private key `[REDACTED-ROTATED-KEY]` discovered in git commit `451dedd` (public repo)
- New P-256 keypair generated using PowerShell CNG
- New secrets pushed to Cloudflare Worker via `wrangler secret put`
- New public key embedded in app

### `NexLink-WPF.ps1`:
- `$script:ProPublicKey.x` changed from `yg0VaTuX8pv8kJlfoFIOXFDdgW2vhipwb8sQjb1QlNw=` to `wysF6y9aP0lNP193gRQA8udaNffqT4UKjecDw0SyLbk=`
- `$script:ProPublicKey.y` changed from `uYyJ9dNVOTu3HiTerRBEojxnGSend6kgMJgeb4W6rG8=` to `zpMEBAovSc0ANwby8/vR6nOID6p58omnqFqmDqFUzVM=`

### `ecdsa_public_key.json`:
- `x` updated to `wysF6y9aP0lNP193gRQA8udaNffqT4UKjecDw0SyLbk=`
- `y` updated to `zpMEBAovSc0ANwby8/vR6nOID6p58omnqFqmDqFUzVM=`

### Files deleted from disk:
- `ecdsa_private_key.json` — deleted after key rotation (key now only in Cloudflare secrets)
- `NexLink-WPF.ps1.original_backup` — junk experiment backup
- `nexlink-infinity-link-theme.patch` — abandoned theme experiment patch file
- `NEXLINK_INFINITY_LINK_MASTER_PROMPT.md` — abandoned theme design document
- `nexlink-preview.html` — abandoned theme HTML preview

### `cloudflare_worker.js`:
- `<h1>🎉 Payment Successful!</h1>` — emoji replaced with inline SVG checkmark (`<polyline points="20 6 9 17 4 12"/>`)
- `⚠️ Important:` — emoji replaced with inline SVG warning triangle
- `Click the ⚙ icon (Advanced)` — replaced with plain text "Click the Settings icon (Advanced)"

### `.gitignore`:
- `lighthouse.pdf` added

### `README.txt`:
- Version bumped from `v1.3.6` to `v1.3.14`

### `DEPLOYMENT_GUIDE.md`:
- Version header bumped to `1.3.14`
- Version Information section updated to `1.3.14` / `1.3.14.0`

### `release.ps1`:
- Dead `$verifyLog = Join-Path $ProjectDir "lmu_autoconnect.log"` variable removed
- Timestamp verification logic restored correctly without it

### `docs/index.html`:
- Static fallback versions updated: `heroVersion`, `ctaVersion`, `footerVersion` all changed from `v1.3.13` to `v1.3.14`

### `docs/style.css`:
- `.faq-answer a { text-decoration: none }` rule removed — FAQ inline links now visibly underlined as body text

---

## Final audit fixes (`f608aea`)

### `NexLink-WPF.ps1`:
- `Get-CurrentWifiState` — SSID regex tightened: `'^\s*SSID\s*:\s*(.+)$'` → `'^\s{1,4}SSID\s*:\s*(.+)$'` — same fix applied to `Get-CurrentSSID` in hardening pass but missed here
- `Invoke-PortalLogout` — explicit `return $false` added as final line after `foreach` loop — safety net for edge case where function could return `$null` implicitly
- `Start-NexLinkUpdate` helper script — `Remove-Item \`$MyInvocation.MyCommand.Path -ErrorAction SilentlyContinue` added at end of here-string — helper script now self-deletes from `%TEMP%` after running
- `$script:secondsToNextCheck` dead variable removed from all 4 locations:
  - Line ~133: initial declaration `$script:secondsToNextCheck = $CheckIntervalMs / 1000`
  - `Reconnect-Manually`: `$script:secondsToNextCheck = $CheckIntervalMs / 1000`
  - Timer tick header: `$script:secondsToNextCheck = $CheckIntervalMs / 1000`
  - Timer tick footer: `$script:secondsToNextCheck = $timer.Interval.TotalMilliseconds / 1000`

### `cloudflare_worker.js`:
- `/callback` catch block — `console.error('[NexLink Worker] /callback error:', error)` added before `return new Response(...)` — errors now visible in Cloudflare Worker logs
- `/activate` catch block — `console.error('[NexLink Worker] /activate error:', error)` added — same reason

### `release.ps1`:
- New step `[2b/8]` added after ISS version bump: reads `docs/index.html`, replaces all `>v[\d\.]+</span>` with new version, writes back — keeps static fallback versions current automatically on every release
- `git add NexLink-WPF.ps1 NexLink-installer.iss` extended to include `docs/index.html`

### `DEPLOYMENT_GUIDE.md`:
- All three references to `ecdsa_private_key.json` in Troubleshooting section replaced with Cloudflare Dashboard instructions
- "Files Created" section — `ecdsa_private_key.json` entry replaced with a note about deletion after rotation
- "Files Modified" section — version and description updated to current state
- Security checklist — all six `[ ]` items changed to `[x]`

### `README.txt`:
- Last two lines replaced: "keep this installer folder... see DEPLOYMENT_GUIDE.md in the installation directory" → "visit https://github.com/highnine699-del/nexlink-updates for documentation"

### `docs/style.css`:
- `.install-steps { list-style: none; }` — `list-style: none` removed (element is a `<div>`, not `<ul>`, rule was vestigial)

### `.gitignore`:
- `wifi_16.png`, `wifi_32.png`, `wifi_48.png`, `wifi_256.png` added — unused PNG source files that served no active purpose in the build pipeline

---

## v1.3.15 release (`c5fc658`)

- `NexLink-WPF.ps1` — `$NexLinkVersion` bumped to `1.3.15`
- `NexLink-installer.iss` — `AppVersion` bumped to `1.3.15.0`
- `docs/index.html` — `heroVersion`, `ctaVersion`, `footerVersion` fallbacks bumped to `v1.3.15` (auto-bumped by the new `release.ps1` step)
- `latest.json` (nexlink-updates repo) — version, installer_url, sha256 updated
- SHA256 of installer: `587D5F36721C9CBA7E65C3FCA9FFB010DE07BA296F7DAAB8BEF4B4857C5740E1`

---

## Landing page screenshot update (`16a2e48`, `f5c362a`)

### `docs/index.html`:
- Screenshot slot 2 — changed from `Screenshot startup.png` (wrong — showed "Starting..." state) to `Screenshot reconnecting .png`
- Then updated again to `Screenshot fixing your connection .png` (correct — shows "Fixing your connection..." state)
- Placeholder HTML comment and stale alt text removed
- Alt text updated to: "NexLink showing Fixing your connection... state while re-establishing portal login"

### `docs/screenshots/` — files added:
- `Screenshot reconnecting .png` — reconnecting state screenshot
- `Screenshot fixing your connection .png` — correctly named "Fixing your connection..." screenshot (wired in as the active image)

---

## Final debug confirmation (`f5c362a`)

All checks passed:
- `NEXLINK_PARSE_OK` — no syntax errors in NexLink-WPF.ps1
- `$NexLinkVersion` = `1.3.15` ✓
- `$script:ProPublicKey` = new rotated key (`wysF6y9...` / `zpMEBAov...`) ✓
- `$script:secondsToNextCheck` — zero occurrences (fully removed) ✓
- `Get-CurrentWifiState` SSID regex = `'^\s{1,4}SSID\s*:\s*(.+)$'` ✓
- `Invoke-PortalLogout` ends with `return $false` ✓
- `$MyInvocation.MyCommand.Path` self-delete in helper script ✓
- `$script:allowExit` — set at init, set true in `Invoke-GracefulExit`, guarded in `window.Add_Closed` ✓
- `$script:LogLock` — used in both `Add-Log` and `Limit-LogFile` ✓
- `$script:dragStartPoint` null guard present ✓
- `cloudflare_worker.js` — both catch blocks have `console.error()` ✓
- `cloudflare_worker.js` — `response.ok` check before `.json()` ✓
- `docs/index.html` — `Screenshot fixing your connection .png` wired in ✓
- `docs/index.html` — version fallbacks at `v1.3.15` ✓
- Git working tree — clean, up to date with origin ✓

---

## In-app error reporting + timer resilience (`7dd0bb3`)

### `NexLink-WPF.ps1`:

**Timer tick catch block fixed (app can no longer become a zombie):**
- Old catch: only logged error and set status. If an exception escaped the tick loop, the timer kept running but fail counters were wrong and the interval could be stuck at 1ms (from `Invoke-ImmediateConnectivityCheck`), causing a CPU spin.
- New catch:
  - Log message changed from `"ERROR: ..."` to `"ERROR in monitor tick: ..."` for clarity
  - `$script:wifiFailCount = 0` — reset so next tick starts clean
  - `$script:portalFailCount = 0` — reset
  - `$script:portalUnknownCount = 0` — reset
  - `$timer.Interval = [TimeSpan]::FromMilliseconds($CheckIntervalMs)` — restores to 5s in case it was stuck at 1ms

**`Invoke-SendErrorReport` function added** (placed after `Clear-DnsCache`):
- Reads last 500 lines from `$LogFile` on disk
- Also reads last 100 lines from `$script:logLines` in-memory array under `$script:LogLock`
- Merges and deduplicates, caps at 500 lines
- Shows WinForms dialog styled to match app dark theme:
  - Label: "Describe what went wrong (optional):"
  - Multi-line text box
  - Info label: "The last 24hrs of connection logs will be included. No passwords are sent."
  - "Send Report" button (sky blue `#0EA5E9`)
  - "Cancel" button
- On confirm: collects OS caption, adapter name/description, anonymous machine hash prefix (8 chars), app version, ISO timestamp
- Builds JSON payload and POSTs to `https://nexlink-license.highnine699.workers.dev/report`
- `$sendReportBtn.IsEnabled = $false` and content changed to "Sending..." during request
- On success: logs "Error report sent successfully." and shows confirmation MessageBox
- On failure: logs error and shows error MessageBox with exception message
- `finally` block always restores button state

**Advanced panel XAML changes:**
- `OpenLogBtn` `Margin` changed from none to `Margin="0,0,8,0"` to make room
- New button added: `Name="SendReportBtn"` `Content="Send Error Report"` `Width="140"` `Height="32"` `Background="#0EA5E9"` (sky blue) `Foreground="#F5F5F7"`

**`FindName` wiring added:**
- `$sendReportBtn = $advWindow.FindName("SendReportBtn")`

**Click handler added:**
```powershell
$sendReportBtn.Add_Click({
    Invoke-SendErrorReport
})
```

### `cloudflare_worker.js`:

**Header comment updated:**
- Added `// - RESEND_API_KEY: Resend API key for error report emails`

**New `/report` POST endpoint added** (before health check return):
- Validates `appVersion` present and `logLines` is a non-empty array
- Rate limiting: uses `LICENSE_ACTIVATIONS` KV with key `report_rl:<machineHashPrefix>`, TTL 3600s — rejects with 429 if last report was less than 60 minutes ago
- `machineHashPrefix` validated against regex `^[A-Za-z0-9+/=]{1,8}$` before use as KV key
- Sanitisation of all fields:
  - `logLines`: capped at 500 lines, each line capped at 300 chars
  - `comment`: capped at 500 chars, defaults to "(no comment)"
  - `appVersion`: capped at 20 chars
  - `os`, `adapter`: capped at 100 chars
  - `timestamp`: capped at 30 chars
  - `machineHashPrefix`: capped at 8 chars
- Builds HTML email with styled table (version, OS, adapter, device ID, timestamp), comment box, and monospace log pre block
- POSTs to `https://api.resend.com/emails` with:
  - `from`: `NexLink Reports <onboarding@resend.dev>`
  - `to`: `["highnine699@gmail.com"]`
  - `subject`: `NexLink Error Report — v{version} — {timestamp}`
  - Authorization: `Bearer ${RESEND_API_KEY}`
- Logs `console.error` if Resend API returns non-ok
- Returns `{ success: true }` on success
- Outer catch logs `console.error('[NexLink Worker] /report error:', error)`

**Cloudflare secrets updated:**
- `RESEND_API_KEY` added via `wrangler secret put RESEND_API_KEY --name nexlink-license`

**Worker deployed:**
- `wrangler deploy cloudflare_worker.js --name nexlink-license --compatibility-date 2026-07-11`
- Version ID: `9059ae33-3eaf-4708-b108-4a9304ddc267`

### `docs/index.html`:
- FAQ "What if I have a problem?" answer updated to mention the **Send Error Report** button in the Advanced panel
- Roadmap "Done" column: added "In-app error reporting" item

---

## release.ps1 SHA256 fix (`c631d74`)

### `release.ps1`:
- `Get-FileHash` cmdlet replaced with .NET `[System.Security.Cryptography.SHA256]` directly — `Get-FileHash` was unavailable when release.ps1 ran under PowerShell 7.6.3
- New implementation:
  ```powershell
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  $hashBytes = $sha256.ComputeHash([System.IO.File]::ReadAllBytes((Resolve-Path ".\NexLink-Installer.exe")))
  $sha256.Dispose()
  $hash = [System.BitConverter]::ToString($hashBytes) -replace '-', ''
  ```

---

## v1.3.16 release (`4faa4c6` — current HEAD)

- `NexLink-WPF.ps1` — `$NexLinkVersion` bumped to `1.3.16`
- `NexLink-installer.iss` — `AppVersion` bumped to `1.3.16.0`
- `docs/index.html` — fallback versions bumped to `v1.3.16`
- `latest.json` (nexlink-updates repo) — version, installer_url, sha256 updated
- SHA256 of installer: `C08C5635F33D79628B29833B6DAB79861532EA144DAC51801669EE6AF3AD420E`

---

## v1.3.17 release (2026-07-12)

- `NexLink-WPF.ps1` — `\` bumped to `1.3.17`
- `NexLink-installer.iss` — `AppVersion` bumped to `1.3.17.0`
- `docs/index.html` — fallback versions bumped to `v1.3.17`
- `README.txt` — version bumped to `v1.3.17`
- SHA256 of installer: `137D2E43FA7C8C3ADAEA9BB80867188E8D9F8E46BC6FF6F0C5B3D2074226D963`
- Release notes: fix: Advanced panel buttons wrap to second row, README.txt version auto-bumped on release, CHANGELOG auto-updated on release
---

## v1.3.18 release (2026-07-12)

- `NexLink-WPF.ps1` — `\` bumped to `1.3.18`
- `NexLink-installer.iss` — `AppVersion` bumped to `1.3.18.0`
- `docs/index.html` — fallback versions bumped to `v1.3.18`
- `README.txt` — version bumped to `v1.3.18`
- SHA256 of installer: `A36365E909D9D2D479FF562A4F621EB202E32D5038C1615B191CFBE5D1C841BB`
- Release notes: Bug fixes and improvements
---

## v1.3.19 release (2026-07-12)

- `NexLink-WPF.ps1` — `\` bumped to `1.3.19`
- `NexLink-installer.iss` — `AppVersion` bumped to `1.3.19.0`
- `docs/index.html` — fallback versions bumped to `v1.3.19`
- `README.txt` — version bumped to `v1.3.19`
- SHA256 of installer: `578C840BE693EF31E0299491436AB6E003970D0C2A810E6D870A4EBE9EAB84E3`
- Release notes: Bug fixes and improvements
---

## v1.3.20 release (2026-07-12)

- `NexLink-WPF.ps1` — `\` bumped to `1.3.20`
- `NexLink-installer.iss` — `AppVersion` bumped to `1.3.20.0`
- `docs/index.html` — fallback versions bumped to `v1.3.20`
- `README.txt` — version bumped to `v1.3.20`
- SHA256 of installer: `6C06DC458FC105DDD39DF4014375F706D189EFF6CF7AEFE65A255ADA8326F542`
- Release notes: Bug fixes and improvements
---

## v1.3.21 release (2026-07-12)

- `NexLink-WPF.ps1` — `\` bumped to `1.3.21`
- `NexLink-installer.iss` — `AppVersion` bumped to `1.3.21.0`
- `docs/index.html` — fallback versions bumped to `v1.3.21`
- `README.txt` — version bumped to `v1.3.21`
- SHA256 of installer: `0F353F819A5E076762707CE9374ADCB04B69A50505DA33DB4DFC1CAAAC8CC795`
- Release notes: Bug fixes and improvements
---

## v1.3.22 release (2026-07-12)

- `NexLink-WPF.ps1` — `\` bumped to `1.3.22`
- `NexLink-installer.iss` — `AppVersion` bumped to `1.3.22.0`
- `docs/index.html` — fallback versions bumped to `v1.3.22`
- `README.txt` — version bumped to `v1.3.22`
- SHA256 of installer: `4C1DFAE9CA770D0616ACA55A2DF44670A43CE9199DB9234970AE544EC523232B`
- Release notes: Bug fixes and improvements
---

## v1.3.23 release (2026-07-12)

- `NexLink-WPF.ps1` — `\` bumped to `1.3.23`
- `NexLink-installer.iss` — `AppVersion` bumped to `1.3.23.0`
- `docs/index.html` — fallback versions bumped to `v1.3.23`
- `README.txt` — version bumped to `v1.3.23`
- SHA256 of installer: `3E24127211B7C71021A86E43C9E2F2217FA58B2DCCEE43EAA5B5419C08A00023`
- Release notes: Bug fixes and improvements
---

## v1.3.24 release (2026-07-12)

- `NexLink-WPF.ps1` — `\` bumped to `1.3.24`
- `NexLink-installer.iss` — `AppVersion` bumped to `1.3.24.0`
- `docs/index.html` — fallback versions bumped to `v1.3.24`
- `README.txt` — version bumped to `v1.3.24`
- SHA256 of installer: `D9ADE8E38F74289F3E7810754251EE17D3E036E22D675A0A37C8A366B3E809CB`
- Release notes: Bug fixes and improvements
---

## Pending manual actions (not in code)

1. **Create OG image** — `docs/og-image.png` is currently a 256×256 icon. Replace with 1200×630 image for proper WhatsApp/Telegram link preview cards.
2. **Create Apple touch icon** — `docs/apple-touch-icon.png` (180×180 PNG). Tell Kiro the filename and the `<link>` tag will be added.
3. **Git history** — commit `451dedd` contains the old (now-invalidated) ECDSA private key permanently. No active security risk since key is rotated, but can be removed via `git filter-repo` if desired (rewrites all hashes, forces everyone to re-clone).

---

*Last updated: July 2026. Covers commits `ce3ea56` (v1.3.10) through `4faa4c6` (v1.3.16 — current HEAD).*
