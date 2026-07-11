// Cloudflare Worker for NexLink Pro license generation
// Environment variables needed:
// - PAYSTACK_SECRET_KEY: Your Paystack secret key
// - ECDSA_D: Base64-encoded private key d parameter (from ecdsa_private_key.json)
// - ECDSA_X: Base64-encoded public key x parameter (from ecdsa_private_key.json)
// - ECDSA_Y: Base64-encoded public key y parameter (from ecdsa_private_key.json)

addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request))
})

async function handleRequest(request) {
  const url = new URL(request.url)

  // Handle Paystack callback
  if (url.pathname === '/callback') {
    const reference = url.searchParams.get('reference')

    if (!reference) {
      return new Response('Invalid request', { status: 400 })
    }

    // Input validation: reference should be alphanumeric with hyphens/underscores only
    if (!/^[a-zA-Z0-9_-]+$/.test(reference)) {
      return new Response('Invalid request', { status: 400 })
    }

    try {
      // Verify transaction with Paystack
      const verifyResponse = await verifyPaystackTransaction(reference)

      if (!verifyResponse.success) {
        return new Response('Unable to process request', { status: 400 })
      }

      // Generate and sign license key deterministically from reference
      const licenseKey = await generateAndSignLicenseKey(reference)

      // Return HTML page with the license key
      const html = `
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>NexLink Pro - License Key</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      margin: 0;
      padding: 20px;
    }
    .container {
      background: white;
      border-radius: 12px;
      padding: 40px;
      max-width: 500px;
      box-shadow: 0 10px 40px rgba(0,0,0,0.2);
    }
    h1 {
      color: #333;
      margin-top: 0;
    }
    .success {
      color: #10b981;
      font-size: 18px;
      margin-bottom: 20px;
    }
    .key-box {
      background: #f3f4f6;
      border: 2px solid #e5e7eb;
      border-radius: 8px;
      padding: 15px;
      margin: 20px 0;
      word-break: break-all;
      font-family: monospace;
      font-size: 14px;
      color: #374151;
    }
    .copy-btn {
      background: #7c3aed;
      color: white;
      border: none;
      padding: 12px 24px;
      border-radius: 6px;
      cursor: pointer;
      font-size: 16px;
      margin-top: 10px;
    }
    .copy-btn:hover {
      background: #6d28d9;
    }
    .instructions {
      margin-top: 30px;
      padding-top: 20px;
      border-top: 1px solid #e5e7eb;
      font-size: 14px;
      color: #6b7280;
    }
    .instructions h3 {
      margin-top: 0;
      color: #374151;
    }
    .bookmark-hint {
      background: #fef3c7;
      border: 1px solid #f59e0b;
      border-radius: 6px;
      padding: 12px;
      margin-top: 20px;
      font-size: 13px;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>🎉 Payment Successful!</h1>
    <div class="success">Your NexLink Pro license is ready</div>
    
    <p><strong>Your License Key:</strong></p>
    <div class="key-box" id="licenseKey">${licenseKey}</div>
    <button class="copy-btn" onclick="copyKey()">Copy to Clipboard</button>
    
    <div class="bookmark-hint">
      <strong>⚠️ Important:</strong> Bookmark or screenshot this page. If you lose your key, you can regenerate it by revisiting this exact URL.
    </div>
    
    <div class="instructions">
      <h3>How to activate:</h3>
      <ol>
        <li>Open NexLink</li>
        <li>Click the ⚙ icon (Advanced)</li>
        <li>Click "Enter Pro License"</li>
        <li>Paste your license key</li>
        <li>Click "Validate License"</li>
      </ol>
    </div>
  </div>
  
  <script>
    function copyKey() {
      const keyElement = document.getElementById('licenseKey')
      navigator.clipboard.writeText(keyElement.textContent).then(() => {
        const btn = document.querySelector('.copy-btn')
        btn.textContent = 'Copied!'
        setTimeout(() => btn.textContent = 'Copy to Clipboard', 2000)
      })
    }
  </script>
</body>
</html>
      `

      return new Response(html, {
        headers: { 'Content-Type': 'text/html;charset=UTF-8' }
      })
    } catch (error) {
      return new Response('Unable to process request', { status: 500 })
    }
  }

  // Handle license activation (device binding)
  if (url.pathname === '/activate' && request.method === 'POST') {
    try {
      const body = await request.json()
      const { licenseKey, machineHash } = body

      if (!licenseKey || !machineHash) {
        return new Response('Invalid request', { status: 400 })
      }

      const parts = licenseKey.split('.')
      if (parts.length !== 2) {
        return new Response('Invalid request', { status: 400 })
      }

      let reference
      try {
        reference = atob(parts[0])
      } catch (e) {
        return new Response('Invalid request', { status: 400 })
      }

      if (!/^[a-zA-Z0-9_-]+$/.test(reference)) {
        return new Response('Invalid request', { status: 400 })
      }

      // Prove the caller actually possesses a validly-signed key before
      // trusting their machineHash claim - verify the signature against the
      // public key directly. (We do NOT regenerate a fresh signature to
      // compare strings - ECDSA signing is not deterministic, so a freshly
      // generated signature for the same reference will almost never match
      // byte-for-byte even though both are equally valid. Verification,
      // not regeneration, is the correct check here.)
      const isValidSignature = await verifyLicenseSignature(reference, parts[1])
      if (!isValidSignature) {
        return new Response('Invalid license signature', { status: 403 })
      }

      const existingHash = await LICENSE_ACTIVATIONS.get(reference)
      if (existingHash && existingHash !== machineHash) {
        return new Response('License already activated on another device', { status: 409 })
      }
      if (!existingHash) {
        await LICENSE_ACTIVATIONS.put(reference, machineHash)
      }

      // Issue a signed device token binding this exact reference+machineHash
      // pair. This is the piece that actually closes the forgery gap: a
      // bare machineHash stored locally could be trivially recomputed and
      // faked by anyone (no secret involved in Get-MachineFingerprint). A
      // signature over reference+machineHash together can only be produced
      // by someone holding the server's private key - i.e. only this
      // Worker, only after it has genuinely checked the KV binding above.
      const deviceToken = await signDeviceToken(reference, machineHash)

      return new Response(JSON.stringify({ deviceToken }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' }
      })
    }
    catch (error) {
      return new Response('Unable to process request', { status: 500 })
    }
  }

  // Health check endpoint
  return new Response('NexLink Pro License Worker is running', { status: 200 })
}

async function verifyPaystackTransaction(reference) {
  const secretKey = PAYSTACK_SECRET_KEY
  const response = await fetch(`https://api.paystack.co/transaction/verify/${reference}`, {
    headers: {
      'Authorization': `Bearer ${secretKey}`
    }
  })

  const data = await response.json()
  if (!response.ok) {
    return { success: false }
  }
  const success = data.status && data.data && data.data.status === 'success'
  return { success }
}

async function verifyLicenseSignature(reference, signatureBase64) {
  const jwk = {
    kty: 'EC',
    crv: 'P-256',
    x: ECDSA_X,
    y: ECDSA_Y
  }

  const publicKey = await crypto.subtle.importKey(
    'jwk',
    jwk,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['verify']
  )

  const encoder = new TextEncoder()
  const messageBytes = encoder.encode(reference)
  const signatureBytes = Uint8Array.from(atob(signatureBase64), c => c.charCodeAt(0))

  return await crypto.subtle.verify(
    { name: 'ECDSA', hash: 'SHA-256' },
    publicKey,
    signatureBytes,
    messageBytes
  )
}

async function signDeviceToken(reference, machineHash) {
  const jwk = {
    kty: 'EC',
    crv: 'P-256',
    d: ECDSA_D,
    x: ECDSA_X,
    y: ECDSA_Y
  }

  const privateKey = await crypto.subtle.importKey(
    'jwk',
    jwk,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign']
  )

  const encoder = new TextEncoder()
  const message = `${reference}:${machineHash}`
  const messageBytes = encoder.encode(message)

  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    privateKey,
    messageBytes
  )

  return btoa(String.fromCharCode(...new Uint8Array(signature)))
}

async function generateAndSignLicenseKey(reference) {
  // Import the private key from JWK format
  // Environment variables: ECDSA_D, ECDSA_X, ECDSA_Y (base64 encoded)
  const jwk = {
    kty: 'EC',
    crv: 'P-256',
    d: ECDSA_D,
    x: ECDSA_X,
    y: ECDSA_Y
  }

  const privateKey = await crypto.subtle.importKey(
    'jwk',
    jwk,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign']
  )

  // Sign the reference bytes
  const encoder = new TextEncoder()
  const data = encoder.encode(reference)

  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    privateKey,
    data
  )

  // Convert to base64 and format as base64(reference).base64(signature)
  const referenceBase64 = btoa(String.fromCharCode(...new Uint8Array(data)))
  const signatureBase64 = btoa(String.fromCharCode(...new Uint8Array(signature)))

  return `${referenceBase64}.${signatureBase64}`
}