# Public release checklist

Flit's public build must be signed, notarized, and backed by an approved Google OAuth consent screen. Do not publish the unsigned validation artifacts produced by `FLIT_RELEASE_UNSIGNED=1`.

## 1. Apple Developer setup

- Enroll the release owner in the Apple Developer Program.
- Create a **Developer ID Application** certificate.
- Export the certificate and private key as a password-protected `.p12`.
- Create an App Store Connect API key permitted to submit notarization requests.
- Verify locally that `security find-identity -v -p codesigning` lists the Developer ID identity.

## 2. Public website and domain

- Preview deployment: `https://flit-pied.vercel.app/`
- Add the purchased custom domain to the Vercel `flit` project.
- Set `FLIT_SITE_URL=https://<domain>` and rebuild `site/` so canonical URLs use the domain.
- Verify the domain in Google Search Console.
- Confirm these stable HTTPS pages:
  - `/`
  - `/privacy/`
  - `/terms/`
  - `/support/`
  - `/installation/`

## 3. Google OAuth production approval

Configure the external OAuth consent screen with:

- App name: **Flit**
- Homepage: the verified custom-domain homepage
- Privacy policy: `<domain>/privacy/`
- Terms: `<domain>/terms/`
- Support: `<domain>/support/`
- Scope: `https://mail.google.com/`
- Desktop OAuth client type

Prepare:

- App icon from `assets/Flit-AppIcon-1024.png`
- A screen recording showing Add Gmail Account, Google consent, inbox synchronization, reading, archive/trash, search, and sending
- Written justification that IMAP/SMTP require the full mail scope
- Test credentials or test-user instructions requested by Google's review team
- An independent security assessment if Google requires one for the restricted scope

Do not place the production OAuth JSON in git. The approved Desktop client JSON is injected only during the release workflow.

## 4. GitHub release environment

Create a protected GitHub Actions environment named `release`. Add these secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded `.p12` containing the Developer ID Application identity |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_KEY_ID` | App Store Connect API key ID |
| `APPLE_ISSUER_ID` | App Store Connect issuer ID |
| `APPLE_PRIVATE_KEY_BASE64` | Base64-encoded App Store Connect `.p8` private key |
| `GOOGLE_OAUTH_JSON_BASE64` | Base64-encoded approved Desktop OAuth JSON |

Require reviewer approval on the `release` environment to prevent accidental publication.

## 5. Preflight

- Update `CFBundleShortVersionString` and increment `CFBundleVersion` in `Support/Info.plist`.
- Update release notes and known limitations.
- Run `swift test`.
- Run `swift build -c release`.
- Build an unsigned validation package locally only when needed:

  ```bash
  FLIT_RELEASE_TAG=v0.1.0 \
  FLIT_RELEASE_UNSIGNED=1 \
  FLIT_GOOGLE_OAUTH_CONFIG="$HOME/Library/Application Support/Flit/GoogleOAuth.json" \
  ./scripts/package-release.sh
  ```

- Test the universal app on Apple silicon and Intel hardware.
- Test a clean install with no existing Flit database or Keychain entries.
- Validate Gmail sign-in with an account that is not an OAuth test user after production approval.

## 6. Publish

Create and push the release tag only after every gate above passes:

```bash
git tag -s v0.1.0 -m "Flit 0.1.0"
git push origin v0.1.0
```

The `Release` workflow will:

1. Import the Developer ID certificate into a temporary keychain.
2. Build an Apple silicon and Intel universal binary.
3. Inject the approved OAuth configuration.
4. Enable Hardened Runtime and sign the app.
5. Submit and staple Apple notarization tickets.
6. Create ZIP and DMG artifacts plus SHA-256 checksums.
7. Publish the GitHub Release.

After publishing, install the DMG from GitHub on a clean Mac and complete one final Gmail sign-in, sync, read, archive, search, and reply test.
