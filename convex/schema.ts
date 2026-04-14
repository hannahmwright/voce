import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
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
