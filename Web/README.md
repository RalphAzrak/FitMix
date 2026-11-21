# FitMix link host

These are static files for the HTTPS host behind the sign-up **Verify email** Universal Link
(`SupabaseConfig.universalLinkHost`). Deploy `public/` to that host's root. Any static host works.

| Path | Purpose |
| --- | --- |
| `/.well-known/apple-app-site-association` | Tells iOS that `/auth/confirm?token_hash=…` opens FitMix. |
| `/auth/confirm/` | What a browser shows: open the email on the iPhone. It never sends or uses the token. |

## Hosting requirements
- HTTPS with a valid certificate, on the exact host in `applinks:` (no wildcard redirect).
- `/.well-known/apple-app-site-association` is served **without redirects**, with
  `Content-Type: application/json`, and with no file extension.
- `/auth/confirm` serves `auth/confirm/index.html` (a redirect to `/auth/confirm/` is fine) and
  keeps the query string.
- Recommended headers on `/auth/*`: `Referrer-Policy: no-referrer`, `Cache-Control: no-store`, and
  no analytics or third-party scripts, so the token in the URL never leaves the page.
- Don't log query strings for `/auth/confirm` in the host's access logs, or turn those logs off.

## Values to fill in
- In `apple-app-site-association`, replace `REPLACE_WITH_BUNDLE_ID` with the app's real bundle ID.
  `3DCANY67BR` is the team ID from the Xcode project.
- In the app, set the host in `SupabaseConfig.universalLinkHost` and in `Config/FitMix.entitlements`.

To check the deployed file, open `https://<host>/.well-known/apple-app-site-association` and make
sure it returns this JSON. Apple's CDN copy, which iOS actually reads, is at
`https://app-site-association.cdn-apple.com/a/v1/<host>` and can lag by up to a day.
