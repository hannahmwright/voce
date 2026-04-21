# Voce Entitlements

Convex is the source of truth for Voce premium access.

- Stripe subscriptions sync into `stripeSubscriptions` through `/stripe/webhook`.
- Free users are granted manually in `manualEntitlements`.
- The Mac app checks `/entitlements/check` before starting dictation.
- Non-subscribed users get 30 free dictation minutes per calendar month. Usage is tracked with `/entitlements/record-usage`.

Manual grant examples:

```sh
npx convex run entitlements:grantManual '{"email":"friend@example.com","note":"Free access"}'
npx convex run entitlements:revokeManual '{"email":"friend@example.com"}'
```

Environment variables to set in Convex:

```sh
npx convex env set VOCE_AUTH_SECRET <long-random-secret>
npx convex env set RESEND_API_KEY re_...
npx convex env set VOCE_AUTH_EMAIL_FROM "Voce <access@your-domain.com>"
npx convex env set VOCE_SUPPORT_EMAIL_FROM "Voce Support <support@your-domain.com>"
npx convex env set VOCE_SUPPORT_EMAIL_TO "h.wright@vervetechgroup.com"
npx convex env set STRIPE_SECRET_KEY sk_test_...
npx convex env set STRIPE_WEBHOOK_SECRET whsec_...
npx convex env set STRIPE_PORTAL_CONFIGURATION_ID bpc_...
```

`VOCE_AUTH_SECRET` is required for hashing one-time email codes and app session tokens.
`RESEND_API_KEY` and `VOCE_AUTH_EMAIL_FROM` are required for sending access codes.
`VOCE_SUPPORT_EMAIL_FROM` and `VOCE_SUPPORT_EMAIL_TO` configure where in-app support requests are sent.
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
