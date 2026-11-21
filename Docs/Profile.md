# Profile

Opened from the account button at the top right of My Avatar (next to the cart). Signed out, the
same button opens Sign In. Studio's account button opens it too (both go through `AccountFlowView`).

| Section | Where | Backed by |
| --- | --- | --- |
| Account card, Account Details | `Views/Profile/ProfileView.swift`, `AccountDetailsView.swift` | Supabase Auth: `full_name` metadata, email change with confirmation link (`AuthSession.updateDisplayName`, `changeEmail`, `refreshUser`) |
| My Try-On Photo | `ProfileView.swift` (`TryOnPhotoCard`) | `AvatarStore.bodyPhoto`, the same photo Outfit Review and Studio use. Replace goes through the on-device full-body check (`PhotoReplacementSheet`); remove is `AvatarStore.removeBodyPhoto()`. `MyApp` keeps `StudioStore.tryOnSource` in sync, so a removed photo is dropped from Studio. |
| Sizing Preferences | `SizingPreferencesView.swift`, `Models/ProfileModels.swift` | `ProfileStore` (per account, on device) |
| Shipping Addresses | `AddressViews.swift` | `ProfileStore`. CA, US, and GB have their own labels, region lists, and postal-code rules; other countries use generic fields. |
| Payment Methods | `ProfileInfoViews.swift` | Nothing yet: no payment provider is integrated, so the screen says so. |
| Order History | `ProfileInfoViews.swift` | Nothing yet: FitMix receives no order data. No sample orders are shown. |
| Privacy & Data | `ProfileInfoViews.swift` | Describes the storage above. Account deletion isn't available yet. |

## Storage

`ProfileStore` saves sizes and addresses to
`Application Support/Accounts/<supabase-user-id>/profile.json` with complete file protection. That's
the same approach `AvatarStore` uses. Only the signed-in account's file is loaded, signing out clears it
from memory, and an unreadable file is never overwritten. The data doesn't sync across devices.
Moving it to Supabase would need `profile_preferences` and `shipping_addresses` tables with
owner-only row-level security. No such tables exist today, so this change has no migrations.

The try-on photo belongs to the device, not the account (unchanged from before). It stays on this
iPhone after sign-out.

## Shopping sizes

`SizingPreferences.preferredSize(among:for:)` preselects a saved size in Shop This Look only when
the product lists it in the same system (`M`, `32×30`, `EU 42`, `US M 10`). A bare `42` is never
matched. Today only debug fixtures and sample scans carry product sizes, because live matching isn't built.

## Supabase setup

Add `fitmix://email-change` to Authentication → URL Configuration → Redirect URLs (next to
`fitmix://reset-password`). Without it, confirmation links fall back to the Site URL. The change
still completes there, and **I've confirmed it** on Account Details picks it up.

## Debug launch options (debug builds)

- `FM_DEBUG_ACCOUNT_ID=<uuid>` (+ optional `FM_DEBUG_ACCOUNT_NAME`, `FM_DEBUG_ACCOUNT_EMAIL`): a
  local stand-in signed-in account, without Supabase. Server requests (name, email) fail with the
  normal error UI.
- `FM_DEBUG_SCREEN=profile` opens Profile, and `FM_DEBUG_SCREEN=cart` opens the cart.
- `FM_DEBUG_PROFILE_ROUTE=account | sizing | addresses | payments | orders | privacy` and
  `FM_DEBUG_PROFILE_SCROLL=bottom`.
