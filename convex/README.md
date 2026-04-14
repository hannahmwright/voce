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
npx convex env set STRIPE_SECRET_KEY sk_test_...
npx convex env set STRIPE_WEBHOOK_SECRET whsec_...
npx convex env set STRIPE_PORTAL_CONFIGURATION_ID bpc_...
```

`VOCE_ENTITLEMENT_API_SECRET` is optional. Only set it if the Mac app is also configured to send the same bearer token.

Stripe should send subscription webhooks to:

```txt
https://<convex-deployment>.convex.site/stripe/webhook
```

The app entitlement check endpoint is:

```txt
https://<convex-deployment>.convex.site/entitlements/check
```

The app usage endpoint is:

```txt
https://<convex-deployment>.convex.site/entitlements/record-usage
```
