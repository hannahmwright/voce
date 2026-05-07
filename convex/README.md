# Voce Entitlements

Convex is the source of truth for Voce plan access.

- Stripe subscriptions sync into `stripeSubscriptions` through `/stripe/webhook`.
- Free users are granted manually in `manualEntitlements`.
- The Mac app checks `/entitlements/check` before starting dictation.
- Non-subscribed users get 30 free dictation minutes per calendar month. Usage is tracked with `/entitlements/record-usage`.

Feature flags:

- `voce_app_access`: Base access and the default feature checked by the Mac app.
- `voce_cloud_dictation`: Pro-only cloud dictation.

Manual grant examples:

Prefer the `planTier` shorthand so a Pro grant always includes both features:

```sh
# Grants Base in one call (voce_app_access).
npx convex run entitlements:grantManual '{"email":"friend@example.com","planTier":"base","note":"Base access"}'

# Grants Pro in one call (voce_app_access + voce_cloud_dictation).
npx convex run entitlements:grantManual '{"email":"friend@example.com","planTier":"pro","note":"Pro access"}'

# Revoke a whole tier or every manual grant for the email.
npx convex run entitlements:revokeManual '{"email":"friend@example.com","planTier":"pro"}'
npx convex run entitlements:revokeManual '{"email":"friend@example.com","planTier":"all"}'
```

The per-feature form still works for surgical edits:

```sh
npx convex run entitlements:grantManual '{"email":"friend@example.com","feature":"voce_app_access","note":"Base access"}'
npx convex run entitlements:grantManual '{"email":"friend@example.com","feature":"voce_cloud_dictation","note":"Pro access"}'
npx convex run entitlements:revokeManual '{"email":"friend@example.com","feature":"voce_app_access"}'
npx convex run entitlements:revokeManual '{"email":"friend@example.com","feature":"voce_cloud_dictation"}'
```

Granting `voce_app_access` alone gives Base access.
Granting `voce_cloud_dictation` promotes the user to Pro and implicitly includes Base access.
If only `voce_app_access` is granted, the entitlement check will return `planTier: "base"` even if Pro was the intent — use the `planTier` shorthand above to avoid that foot-gun.

Environment variables to set in Convex:

```sh
npx convex env set VOCE_AUTH_SECRET <long-random-secret>
npx convex env set RESEND_API_KEY re_...
npx convex env set VOCE_AUTH_EMAIL_FROM "Voce <access@your-domain.com>"
npx convex env set VOCE_SUPPORT_EMAIL_FROM "Voce Support <support@your-domain.com>"
npx convex env set VOCE_SUPPORT_EMAIL_TO "h.wright@vervetechgroup.com"
npx convex env set VOCE_SIGNUP_EMAIL_TO "h.wright@vervetechgroup.com"
npx convex env set STRIPE_SECRET_KEY sk_test_...
npx convex env set STRIPE_WEBHOOK_SECRET whsec_...
npx convex env set STRIPE_PORTAL_CONFIGURATION_ID bpc_...
npx convex env set STRIPE_BASE_PRODUCT_ID prod_...
npx convex env set STRIPE_PRO_PRODUCT_ID prod_...
npx convex env set STRIPE_BASE_MONTHLY_PRICE_ID price_...
npx convex env set STRIPE_BASE_ANNUAL_PRICE_ID price_...
npx convex env set STRIPE_PRO_MONTHLY_PRICE_ID price_...
npx convex env set STRIPE_PRO_ANNUAL_PRICE_ID price_...
npx convex env set STRIPE_CHECKOUT_SUCCESS_URL https://voceapp.io/account/success
npx convex env set STRIPE_CHECKOUT_CANCEL_URL https://voceapp.io/pricing
npx convex env set VOCE_OPENAI_API_KEY sk-...
npx convex env set VOCE_OPENAI_REALTIME_TRANSCRIPTION_MODEL gpt-realtime-whisper
npx convex env set VOCE_OPENAI_REFINEMENT_MODEL gpt-4o-mini
```

Recommended Stripe price mapping:

- `STRIPE_BASE_MONTHLY_PRICE_ID`: Base `$7/month`
- `STRIPE_BASE_ANNUAL_PRICE_ID`: Base `$70/year`
- `STRIPE_PRO_MONTHLY_PRICE_ID`: Pro `$10/month`
- `STRIPE_PRO_ANNUAL_PRICE_ID`: Pro `$108/year`

`VOCE_AUTH_SECRET` is required for hashing one-time email codes and app session tokens.
`RESEND_API_KEY` and `VOCE_AUTH_EMAIL_FROM` are required for sending access codes.
`VOCE_SUPPORT_EMAIL_FROM` and `VOCE_SUPPORT_EMAIL_TO` configure where in-app support requests are sent.
`VOCE_SIGNUP_EMAIL_TO` optionally overrides where new signup notifications are sent.
`VOCE_ENTITLEMENT_API_SECRET` is optional and should not be used as the primary app access control.
The Mac app requires a verified email session token for entitlement checks, usage recording, and subscription portal sessions.

Stripe should send subscription webhooks to:

```txt
https://<convex-deployment>.convex.site/stripe/webhook
```

The app entitlement check endpoint is:

```txt
https://<convex-deployment>.convex.site/entitlements/check
```

The app email verification endpoints are:

```txt
https://<convex-deployment>.convex.site/auth/start
https://<convex-deployment>.convex.site/auth/verify
```

The app usage endpoint is:

```txt
https://<convex-deployment>.convex.site/entitlements/record-usage
```

Cloud dictation proxy endpoints are:

```txt
https://<convex-deployment>.convex.site/cloud-dictation/preflight
https://<convex-deployment>.convex.site/cloud-dictation/transcribe
https://<convex-deployment>.convex.site/cloud-dictation/refine
```

These endpoints require:

- `x-voce-email`
- `x-voce-session-token`

The server verifies the saved Voce email session and enforces `voce_cloud_dictation` before proxying any audio or transcript content to OpenAI. Audio and transcript bodies are processed transiently and are not stored in Convex tables by default.

The app checkout endpoint is:

```txt
https://<convex-deployment>.convex.site/stripe/checkout
```
