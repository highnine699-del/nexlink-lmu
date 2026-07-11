# NexLink Pro Deployment Guide

**Version**: 1.3.13
**Date**: July 2026

## Status: Deployed

The Pro licensing system is live. This guide documents how to redeploy or
reconfigure it from scratch (e.g. after key rotation or a new Cloudflare account).

---

## Step 1: Set Up Paystack Account

**Estimated Time**: 2-3 days (KYC review time)

1. Create account at https://paystack.co
2. Complete KYC verification (business documents, identity verification)
3. Create a Payment Page for NexLink Pro
4. Set callback URL to your Cloudflare Worker: `https://your-worker-url.workers.dev/callback`
5. Note your Payment Page URL for Step 4

**Required for Next Step**: Payment Page URL

---

## Step 2: Deploy Cloudflare Worker

**Estimated Time**: 15 minutes

### 2.1 Create Worker

1. Go to Cloudflare Dashboard → Workers & Pages
2. Create new Worker → name it `nexlink-pro-license`
3. Copy contents of `cloudflare_worker.js` into the Worker editor
4. Deploy

### 2.2 Set Environment Secrets

In Cloudflare Worker Settings → Variables & Secrets → Environment Variables:

| Secret Name | Value |
|-------------|-------|
| `PAYSTACK_SECRET_KEY` | Your Paystack secret key (from Paystack Dashboard) |
| `ECDSA_D` | The `d` value from `ecdsa_private_key.json` — **never write this value here, copy it directly from the file** |
| `ECDSA_X` | The `x` value from `ecdsa_private_key.json` or `ecdsa_public_key.json` |
| `ECDSA_Y` | The `y` value from `ecdsa_private_key.json` or `ecdsa_public_key.json` |

⚠️ **Never record the `ECDSA_D` (private key) value in this document or any file that could be committed to git. Copy it directly from `ecdsa_private_key.json` into the Cloudflare secret field.**

### 2.3 Configure Paystack Callback

1. In Paystack Dashboard → Payment Pages → Edit your page
2. Set Callback URL to: `https://nexlink-pro-license.YOUR-ACCOUNT.workers.dev/callback`
3. Save

**Required for Next Step**: Worker URL

---

## Step 3: Update NexLink-WPF.ps1 Payment URL

**Estimated Time**: 1 minute

1. Open `NexLink-WPF.ps1`
2. Find line 1358 (UpgradeBtn click handler)
3. Replace placeholder URL with your actual Paystack Payment Page URL:

```powershell
$paymentUrl = "https://paystack.com/pay/YOUR_ACTUAL_PAYMENT_PAGE_ID"
```

---

## Step 4: Recompile NexLink.exe

**Estimated Time**: 5 minutes

Run the recompilation script:

```powershell
.\recompile_wpf.ps1
```

This will:
- Stop any running NexLink processes
- Read the current version from `NexLink-WPF.ps1` automatically
- Compile `NexLink-WPF.ps1` to `NexLink.exe`
- Verify the output file exists

---

## Step 5: Build Installer

**Estimated Time**: 2 minutes

1. Open `NexLink-installer.iss` in Inno Setup Compiler
2. Click "Compile"
3. Output: `NexLink-Installer.exe` in the same directory

---

## Step 6: End-to-End Test

**Estimated Time**: 10 minutes

### Test Mode (Recommended)

1. In Paystack Dashboard, enable Test Mode
2. Use Paystack test card to make a test payment
3. After payment, you'll be redirected to the Worker
4. Copy the license key displayed
5. Paste into NexLink (Enter Pro License button)
6. Check logs for "License verified for reference: [transaction_id]"
7. Confirm Pro features unlock (theme picker, etc.)

### Production Test

1. Disable Test Mode in Paystack
2. Make a real small payment (you can refund yourself)
3. Follow same verification steps as above

---

## Step 7: Release

**Estimated Time**: 5 minutes

Run the release script:

```powershell
.\release.ps1
```

This will:
- Stop running NexLink processes gracefully
- Build the installer
- Create release artifacts

---

## Troubleshooting

### License Key Format Error

If you see "License verification error" in logs:

1. Check that the Worker is using the new JWK format
2. Verify environment secrets are set correctly
3. Check that `ecdsa_private_key.json` components match the secrets

### Paystack Callback Not Working

1. Verify callback URL in Paystack matches Worker URL
2. Check Worker logs in Cloudflare Dashboard
3. Ensure `PAYSTACK_SECRET_KEY` is correct

### ECDSA Import Error

If Worker fails to import key:

- Ensure you're using the base64 values from `ecdsa_private_key.json`
- Check that all three secrets (ECDSA_D, ECDSA_X, ECDSA_Y) are set
- Verify no extra whitespace in secret values

---

## Security Checklist

- [ ] `ecdsa_private_key.json` is in `.gitignore`
- [ ] Private key components are only in Cloudflare secrets, not in code
- [ ] Paystack secret key is only in Cloudflare secrets
- [ ] Worker error messages are generic (no information disclosure)
- [ ] Input validation is enabled in Worker
- [ ] .gitignore excludes all sensitive files

---

## Version Information

- **NexLink Version**: 1.3.13
- **Installer Version**: 1.3.13.0
- **License Format**: base64(reference).base64(signature)
- **Signature Algorithm**: ECDSA P-256 with SHA-256
- **Key Import**: JWK format (Cloudflare), CNG blob (PowerShell)

---

## Files Modified

1. `NexLink-WPF.ps1` - ECDSA verification, public key embedded, graceful exit
2. `cloudflare_worker.js` - JWK key import, base64.blob format
3. `NexLink-installer.iss` - Version 1.3.3.0
4. `.gitignore` - ecdsa_private_key.json added

---

## Files Created

1. `ecdsa_private_key.json` - Private key (local only, never commit)
2. `ecdsa_public_key.json` - Public key (safe to commit)
3. `DEPLOYMENT_GUIDE.md` - This file
