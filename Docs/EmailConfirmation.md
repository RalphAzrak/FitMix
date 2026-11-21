# Email confirmation links

## Demo setup: link plus in-app code

The demo uses the existing `fitmix://confirm-email` callback for the **Verify email** button. The
code is a fallback for when a mail app won't hand the link back to FitMix. The "Check your email"
card on Sign In has a **Confirmation Code** field and a **Verify** button. FitMix calls
`verifyOTP(email:token:type: .email)` and continues into onboarding, signed in, only when Supabase
returns a session for a user whose email is confirmed. The code needs no PKCE verifier, and the
user never leaves the app.

The code only exists in the email if the "Confirm signup" template includes `{{ .Token }}`.
Proposed template (keeps the existing link):

```html
<h2>Confirm your FitMix account</h2>
<p>On the iPhone where you signed up, tap the button:</p>
<p><a href="{{ .ConfirmationURL }}">Verify email</a></p>
<p>If FitMix doesn't open, enter this code in FitMix instead: <strong>{{ .Token }}</strong></p>
```

The link and the code use the same one-time token. Once either one is used, the other stops
working, but the account is already confirmed, so the user can just sign in.

Requirements: Redirect URLs must contain lowercase `fitmix://confirm-email`. The Associated
Domains entitlement isn't wired into the target for the demo; `Config/FitMix.entitlements` is kept
for the Universal Link setup below.

## App-first Verify email (Universal Link, not live)

Once the template below is live, the sign-up email links to
`https://<link host>/auth/confirm?token_hash={{ .TokenHash }}&type=email`.

- **iPhone with FitMix installed:** iOS opens FitMix directly, on a cold or warm launch, through
  `onOpenURL`. FitMix calls `verifyOTP(tokenHash:type:)`, which sends `POST /verify`. It shows
  **Email verified** and continues only when Supabase returns a session for a user whose email is
  confirmed. Every other result shows the neutral screens below. This doesn't need the PKCE
  verifier, so it works even if sign-up happened on another device.
- **Any browser (desktop, or an iPhone without FitMix):** `Web/public/auth/confirm/` explains how
  to open the email on the iPhone. The page makes no network requests and removes the token from
  the address bar. Loading it, whether by a person or a mail scanner such as Outlook Safe Links,
  never uses up the token. Only the app's `POST /verify` does.
- Password reset (`fitmix://reset-password`) and email change (`fitmix://email-change`) are
  unchanged. Links from older emails to `fitmix://confirm-email?code=…` still work.

The values to supply (host, bundle ID, signing) are listed in `Web/README.md`. The Supabase
template change is:

```html
<h2>Confirm your FitMix account</h2>
<p>Open this email on the iPhone where FitMix is installed, then tap the button.</p>
<p><a href="https://LINK_HOST/auth/confirm?token_hash={{ .TokenHash }}&type=email">Verify email</a></p>
```

## Earlier flow (`fitmix://confirm-email`)

FitMix keeps Supabase email confirmation on. Sign-up asks Supabase to send the confirmation link
to `fitmix://confirm-email` (`SupabaseConfig.signupRedirect` in `AuthSession.swift`). The app
opens that link through the same Account screen it uses for password-reset links.

## How a link is handled

The Supabase Swift SDK uses the PKCE flow. Signing up saves a one-time code verifier in the
Keychain on that device. Opening the email link does two things:

1. Supabase's `/auth/v1/verify` page checks the email token and marks the account confirmed.
   This happens in whatever browser opened the link.
2. Supabase redirects to `fitmix://confirm-email?code=…`, and FitMix exchanges the code for a
   session using the saved verifier.

| What arrives in the app | What the user sees |
| --- | --- |
| `code`, and the exchange works (same device and install that signed up) | **Email verified**, then **Continue to FitMix** signs the user in. If there's no avatar yet, avatar setup starts. |
| `code`, but the exchange fails (another device or install, code already used, offline, or a made-up link) | **Let's finish on Sign In**, with neutral wording, **Go to Sign In** and **Resend confirmation email**. FitMix never claims the email is verified here. |
| `error` / `error_code` (for example `otp_expired`: expired, already used, or invalid) | **This link didn't work**, with **Go to Sign In** and **Resend confirmation email**. |

FitMix shows **Email verified** only after a successful code exchange with Supabase. Anyone can
open a `fitmix://confirm-email?code=…` URL, so the presence of a code proves nothing. If the
account really is confirmed, signing in works. If it isn't, Sign In says so and offers a resend.

The Sign In and Create Account "Check your email" card also has **Didn't get it? Resend email**.
Link URLs and codes are never logged or shown.

## Supabase dashboard (Authentication → URL Configuration)

- **Site URL:** `fitmix://confirm-email`. Supabase falls back to this when a requested redirect
  isn't allow-listed. It was `http://localhost:3000`, which caused the broken link. When a hosted
  HTTPS page exists, use that page instead.
- **Redirect URLs:** keep `fitmix://reset-password` and add these two:
  - `fitmix://confirm-email`
  - `fitmix://email-change`

Under **Authentication → Emails → Confirm signup**, the link must use `{{ .ConfirmationURL }}`,
which is the default (for example `<a href="{{ .ConfirmationURL }}">Confirm your email</a>`).
Don't build the link from `{{ .SiteURL }}`.

## Testing

Each new link replaces the previous one. Always use the newest email. Default links expire
after 24 hours, and Supabase's built-in email sender allows only a few emails per hour.

**Simulator:** sign up in FitMix on the simulator. Open the email in the simulator's Safari
(webmail) and tap the link, or copy the link on the Mac and run
`xcrun simctl openurl booted '<link>'`. Choose **Open** when asked "Open in FitMix?".

**iPhone:** install FitMix from Xcode, sign up on the iPhone, and open the email in Mail on that
iPhone.

**Debug builds:** `FM_DEBUG_OPEN_URL=<fitmix:// URL>` passes a link to the handler at launch,
without the system prompt.

## Opening the link on a computer

If the token is valid, Supabase confirms the account, then Safari tries to open `fitmix://…` and
shows an error such as "Safari can't open the page". The user can then sign in on their iPhone. A browser-friendly version needs a hosted HTTPS page, for example
`https://<domain>/auth/confirm`, set as the redirect and Site URL. That page would say "Email
verified, open FitMix on your iPhone to sign in." It also needs Universal Links (an
`apple-app-site-association` file on the domain plus the Associated Domains entitlement), so the
same HTTPS link opens FitMix when tapped on an iPhone.

## Troubleshooting with the debug log

Debug builds log each step under subsystem `app.fitmix`, category `AuthFlow`. In Xcode's console,
filter on `[AuthFlow]`. Release builds contain none of this. The log shows only scheme and host,
HTTP status, and Supabase's error code. It never shows the full URL, code, verifier, tokens,
email or password.

| Xcode `[AuthFlow]` line | Supabase Auth log entry |
| --- | --- |
| `client project=https://<ref>.supabase.co …` | Confirms which project the app talks to |
| `signup started redirect_to=fitmix://confirm-email`, then `signup result=…` | `POST /signup` |
| `resend started …`, then `resend result=…` | `POST /resend` |
| *(no app line: this happens in the browser)* | `GET /verify` |
| `callback received origin=fitmix://confirm-email …` | Proves `/verify` redirected to the app |
| `confirm exchange result=…` | `POST /token` (`grant_type=pkce`) |

If `/verify` succeeds but no `callback received` line appears, and the browser opens the Site URL
with `?code=…`, Supabase rejected the redirect. Allow-list entries are case-sensitive: the entry
must be exactly `fitmix://confirm-email`.
