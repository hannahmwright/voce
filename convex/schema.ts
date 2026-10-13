import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  emailAuthCodes: defineTable({
    email: v.string(),
    codeHash: v.string(),
    expiresAt: v.number(),
    attempts: v.number(),
    consumedAt: v.optional(v.number()),
    // Set when a newer code is issued for the same email.
    invalidatedAt: v.optional(v.number()),
    createdAt: v.number(),
  })
    .index("by_email", ["email"])
    .index("by_email_code_hash", ["email", "codeHash"])
    .index("by_expires_at", ["expiresAt"]),

  // One row per verified email, never deleted. Used to detect first signups
  // independently of session rows, which logout revokes and cleanup deletes.
  emailAccounts: defineTable({
    email: v.string(),
    firstSeenAt: v.number(),
  }).index("by_email", ["email"]),

  // Usage reports already applied, keyed by the app-generated reportId, so a
  // retried /entitlements/record-usage request is not counted twice.
  usageReports: defineTable({
    email: v.string(),
    feature: v.string(),
    reportId: v.string(),
    appliedAt: v.number(),
  })
    .index("by_email_feature_report", ["email", "feature", "reportId"])
    .index("by_applied_at", ["appliedAt"]),

  // Fixed-window request counters for unauthenticated endpoints.
  rateLimits: defineTable({
    key: v.string(),
    windowStartedAt: v.number(),
    count: v.number(),
  })
    .index("by_key", ["key"])
    .index("by_window_started_at", ["windowStartedAt"]),

  authSessions: defineTable({
    email: v.string(),
    tokenHash: v.string(),
    expiresAt: v.number(),
    createdAt: v.number(),
    lastSeenAt: v.number(),
    // Set by /auth/logout. Revoked sessions are rejected but kept until expiry.
    revokedAt: v.optional(v.number()),
  })
    .index("by_token_hash", ["tokenHash"])
    .index("by_email", ["email"])
    .index("by_expires_at", ["expiresAt"]),

  manualEntitlements: defineTable({
    email: v.string(),
    feature: v.string(),
    expiresAt: v.optional(v.number()),
    note: v.optional(v.string()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_email_feature", ["email", "feature"])
    .index("by_feature", ["feature"]),

  stripeCustomers: defineTable({
    stripeCustomerId: v.string(),
    email: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_stripe_customer_id", ["stripeCustomerId"])
    .index("by_email", ["email"]),

  stripeSubscriptions: defineTable({
    stripeSubscriptionId: v.string(),
    stripeCustomerId: v.string(),
    email: v.string(),
    status: v.string(),
    priceId: v.optional(v.string()),
    productId: v.optional(v.string()),
    currentPeriodEnd: v.optional(v.number()),
    cancelAtPeriodEnd: v.optional(v.boolean()),
    // Stripe `event.created` (ms) of the newest webhook event applied to this record.
    lastStripeEventAt: v.optional(v.number()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_stripe_subscription_id", ["stripeSubscriptionId"])
    .index("by_email", ["email"])
    .index("by_stripe_customer_id", ["stripeCustomerId"]),

  monthlyUsage: defineTable({
    email: v.string(),
    feature: v.string(),
    periodKey: v.string(),
    usedSeconds: v.number(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_email_feature_period", ["email", "feature", "periodKey"])
    .index("by_feature_period", ["feature", "periodKey"]),
});
