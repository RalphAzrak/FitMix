# Email confirmation links

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
