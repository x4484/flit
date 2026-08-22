# Google OAuth setup

Flit uses Gmail's IMAP and SMTP endpoints through OAuth 2.0/XOAUTH2. Google requires the full `https://mail.google.com/` scope for this protocol path.

## Create a development client

1. Open [Google Cloud Console](https://console.cloud.google.com/).
2. Create or select a project for Flit.
3. Configure the OAuth consent screen as an external app in testing mode.
4. Add your Gmail address as a test user.
5. Add the `https://mail.google.com/` scope.
6. Create an OAuth client with application type **Desktop app**.
7. Download the client JSON.
8. Save it as:

   ```text
   ~/Library/Application Support/Flit/GoogleOAuth.json
   ```

For repository development, this ignored location also works:

```text
Support/GoogleOAuth.local.json
```

You can start from `Support/GoogleOAuth.example.json`, but using Google's downloaded Desktop client file directly is preferred.

## Security model

- The client configuration is never committed.
- OAuth uses a loopback callback, random state, and PKCE SHA-256.
- The browser handles Google credentials; Flit never sees the password.
- The refresh token is stored in macOS Keychain.
- Access tokens remain in memory and expire quickly.
- The local callback listener exists only during sign-in.

## Public distribution

The IMAP/SMTP scope is restricted. A public release that connects arbitrary Google accounts requires Google's OAuth verification and may require an independent security assessment. Development with explicitly listed test users does not require completing that release process first.

The public consent screen must use the final verified custom domain for Flit's homepage, [privacy policy](privacy.md), [terms](terms.md), and [support](support.md). The temporary website preview is `https://flit-pied.vercel.app/`; replace it with the purchased Vercel domain before submitting production verification.

The approved Desktop OAuth JSON must never be committed. Public release builds inject it from the protected `GOOGLE_OAUTH_JSON_BASE64` GitHub Actions secret. See the [public release checklist](release-checklist.md).
