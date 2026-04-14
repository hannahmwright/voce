import { mutation, query, type MutationCtx, type QueryCtx } from "./_generated/server";
import { v } from "convex/values";

const DEFAULT_FEATURE = "voce_app_access";
const FREE_MONTHLY_SECONDS = 30 * 60;
type ReadCtx = QueryCtx | MutationCtx;

function normalizeEmail(email: string) {
  return email.trim().toLowerCase();
}

function activeStripeStatus(status: string) {
  return status === "active" || status === "trialing";
}

function monthPeriod(now: number) {
  const start = new Date(now);
  start.setUTCDate(1);
  start.setUTCHours(0, 0, 0, 0);

  const end = new Date(start);
  end.setUTCMonth(end.getUTCMonth() + 1);

  const periodKey = `${start.getUTCFullYear()}-${String(start.getUTCMonth() + 1).padStart(2, "0")}`;
  return {
    periodKey,
    startsAt: start.getTime(),
    endsAt: end.getTime(),
  };
}

async function activeManualEntitlement(ctx: ReadCtx, email: string, feature: string, now: number) {
  const manual = await ctx.db
    .query("manualEntitlements")
    .withIndex("by_email_feature", (q) => q.eq("email", email).eq("feature", feature))
    .unique();

  if (manual && (manual.expiresAt === undefined || manual.expiresAt > now)) {
    return manual;
  }
  return null;
}

async function activeStripeSubscription(ctx: ReadCtx, email: string, feature: string, now: number) {
  if (feature !== DEFAULT_FEATURE) {
    return null;
  }

  const subscriptions = await ctx.db
    .query("stripeSubscriptions")
    .withIndex("by_email", (q) => q.eq("email", email))
    .collect();

  return (
    subscriptions.find((subscription) => {
      if (!activeStripeStatus(subscription.status)) {
        return false;
      }
      if (subscription.currentPeriodEnd === undefined) {
        return true;
      }
      return subscription.currentPeriodEnd > now;
    }) ?? null
  );
}

async function usageForPeriod(ctx: ReadCtx, email: string, feature: string, periodKey: string) {
  return await ctx.db
    .query("monthlyUsage")
    .withIndex("by_email_feature_period", (q) =>
      q.eq("email", email).eq("feature", feature).eq("periodKey", periodKey),
    )
    .unique();
}

async function entitlementFor(ctx: ReadCtx, email: string, feature: string) {
  const now = Date.now();
  const manual = await activeManualEntitlement(ctx, email, feature, now);

  if (manual) {
    return {
      entitled: true,
      source: "manual",
      feature,
      email,
      expiresAt: manual.expiresAt ?? null,
      freeLimitSeconds: FREE_MONTHLY_SECONDS,
      freeUsedSeconds: null,
      freeRemainingSeconds: null,
      periodStartsAt: null,
      periodEndsAt: null,
    };
  }

  const active = await activeStripeSubscription(ctx, email, feature, now);

  if (active) {
    return {
      entitled: true,
      source: "stripe",
      feature,
      email,
      expiresAt: active.currentPeriodEnd ?? null,
      freeLimitSeconds: FREE_MONTHLY_SECONDS,
      freeUsedSeconds: null,
      freeRemainingSeconds: null,
      periodStartsAt: null,
      periodEndsAt: null,
    };
  }

  if (feature !== DEFAULT_FEATURE) {
    return {
      entitled: false,
      source: null,
      feature,
      email,
      expiresAt: null,
      freeLimitSeconds: null,
      freeUsedSeconds: null,
      freeRemainingSeconds: null,
      periodStartsAt: null,
      periodEndsAt: null,
    };
  }

  const period = monthPeriod(now);
  const usage = await usageForPeriod(ctx, email, feature, period.periodKey);
  const usedSeconds = usage?.usedSeconds ?? 0;
  const remainingSeconds = Math.max(0, FREE_MONTHLY_SECONDS - usedSeconds);

  return {
    entitled: remainingSeconds > 0,
    source: "free",
    feature,
    email,
    expiresAt: period.endsAt,
    freeLimitSeconds: FREE_MONTHLY_SECONDS,
    freeUsedSeconds: usedSeconds,
    freeRemainingSeconds: remainingSeconds,
    periodStartsAt: period.startsAt,
    periodEndsAt: period.endsAt,
  };
}

export const check = query({
  args: {
    email: v.string(),
    feature: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const email = normalizeEmail(args.email);
    const feature = args.feature ?? DEFAULT_FEATURE;
    return await entitlementFor(ctx, email, feature);
  },
});

export const recordUsage = mutation({
  args: {
    email: v.string(),
    feature: v.optional(v.string()),
    seconds: v.number(),
  },
  handler: async (ctx, args) => {
    const email = normalizeEmail(args.email);
    const feature = args.feature ?? DEFAULT_FEATURE;
    const seconds = Math.max(0, Math.ceil(args.seconds));
    const now = Date.now();

    if (seconds === 0) {
      return await entitlementFor(ctx, email, feature);
    }

    const manual = await activeManualEntitlement(ctx, email, feature, now);
    const active = await activeStripeSubscription(ctx, email, feature, now);
    if (manual || active || feature !== DEFAULT_FEATURE) {
      return await entitlementFor(ctx, email, feature);
    }

    const period = monthPeriod(now);
    const existing = await usageForPeriod(ctx, email, feature, period.periodKey);

    if (existing) {
      await ctx.db.patch(existing._id, {
        usedSeconds: existing.usedSeconds + seconds,
        updatedAt: now,
      });
    } else {
      await ctx.db.insert("monthlyUsage", {
        email,
        feature,
        periodKey: period.periodKey,
        usedSeconds: seconds,
        createdAt: now,
        updatedAt: now,
      });
    }

    return await entitlementFor(ctx, email, feature);
  },
});

export const grantManual = mutation({
  args: {
    email: v.string(),
    feature: v.optional(v.string()),
    expiresAt: v.optional(v.number()),
    note: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const email = normalizeEmail(args.email);
    const feature = args.feature ?? DEFAULT_FEATURE;
    const now = Date.now();

    const existing = await ctx.db
      .query("manualEntitlements")
      .withIndex("by_email_feature", (q) => q.eq("email", email).eq("feature", feature))
      .unique();

    const patch = {
      expiresAt: args.expiresAt,
      note: args.note,
      updatedAt: now,
    };

    if (existing) {
      await ctx.db.patch(existing._id, patch);
      return existing._id;
    }

    return await ctx.db.insert("manualEntitlements", {
      email,
      feature,
      expiresAt: args.expiresAt,
      note: args.note,
      createdAt: now,
      updatedAt: now,
    });
  },
});

export const revokeManual = mutation({
  args: {
    email: v.string(),
    feature: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const email = normalizeEmail(args.email);
    const feature = args.feature ?? DEFAULT_FEATURE;
    const existing = await ctx.db
      .query("manualEntitlements")
      .withIndex("by_email_feature", (q) => q.eq("email", email).eq("feature", feature))
      .unique();

    if (existing) {
      await ctx.db.delete(existing._id);
      return true;
    }
    return false;
  },
});
