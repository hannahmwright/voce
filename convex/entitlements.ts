import { mutation, query, type MutationCtx, type QueryCtx } from "./_generated/server";
import { v } from "convex/values";

export const APP_ACCESS_FEATURE = "voce_app_access";
export const CLOUD_DICTATION_FEATURE = "voce_cloud_dictation";
const DEFAULT_FEATURE = APP_ACCESS_FEATURE;
const FREE_MONTHLY_SECONDS = 30 * 60;
type ReadCtx = QueryCtx | MutationCtx;
type Feature = typeof APP_ACCESS_FEATURE | typeof CLOUD_DICTATION_FEATURE;
type PlanTier = "free" | "base" | "pro";
type EntitlementSource = "free" | "manual" | "stripe";

type AccessGrantBundle = {
  source: EntitlementSource;
  planTier: PlanTier;
  grantedFeatures: Feature[];
  expiresAt: number | null;
  freeLimitSeconds: number | null;
  freeUsedSeconds: number | null;
  freeRemainingSeconds: number | null;
  periodStartsAt: number | null;
  periodEndsAt: number | null;
};

const STRIPE_BASE_PRODUCT_IDS = configuredSetFromEnv("STRIPE_BASE_PRODUCT_IDS", "STRIPE_BASE_PRODUCT_ID");
const STRIPE_PRO_PRODUCT_IDS = configuredSetFromEnv("STRIPE_PRO_PRODUCT_IDS", "STRIPE_PRO_PRODUCT_ID");
const STRIPE_BASE_PRICE_IDS = configuredSetFromEnv("STRIPE_BASE_PRICE_IDS", "STRIPE_BASE_PRICE_ID");
const STRIPE_PRO_PRICE_IDS = configuredSetFromEnv("STRIPE_PRO_PRICE_IDS", "STRIPE_PRO_PRICE_ID");

function normalizeEmail(email: string) {
  return email.trim().toLowerCase();
}

function configuredSetFromEnv(...names: string[]) {
  const values = names.flatMap((name) =>
    (process.env[name] ?? "")
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean),
  );
  return new Set(values);
}

function grantedFeaturesForPlanTier(planTier: PlanTier): Feature[] {
  switch (planTier) {
    case "free":
    case "base":
      return [APP_ACCESS_FEATURE];
    case "pro":
      return [APP_ACCESS_FEATURE, CLOUD_DICTATION_FEATURE];
  }
}

function planRank(planTier: PlanTier) {
  switch (planTier) {
    case "free":
      return 0;
    case "base":
      return 1;
    case "pro":
      return 2;
  }
}

function sourceRank(source: EntitlementSource) {
  switch (source) {
    case "free":
      return 0;
    case "stripe":
      return 1;
    case "manual":
      return 2;
  }
}

function betterBundle(
  current: AccessGrantBundle | null,
  candidate: AccessGrantBundle | null,
) {
  if (!candidate) {
    return current;
  }
  if (!current) {
    return candidate;
  }

  const planDifference = planRank(candidate.planTier) - planRank(current.planTier);
  if (planDifference !== 0) {
    return planDifference > 0 ? candidate : current;
  }

  const sourceDifference = sourceRank(candidate.source) - sourceRank(current.source);
  if (sourceDifference !== 0) {
    return sourceDifference > 0 ? candidate : current;
  }

  return (candidate.expiresAt ?? 0) > (current.expiresAt ?? 0) ? candidate : current;
}

function planTierForStripeSubscription(subscription: {
  productId?: string;
  priceId?: string;
}): PlanTier | null {
  if (
    (subscription.productId && STRIPE_PRO_PRODUCT_IDS.has(subscription.productId)) ||
    (subscription.priceId && STRIPE_PRO_PRICE_IDS.has(subscription.priceId))
  ) {
    return "pro";
  }

  if (
    (subscription.productId && STRIPE_BASE_PRODUCT_IDS.has(subscription.productId)) ||
    (subscription.priceId && STRIPE_BASE_PRICE_IDS.has(subscription.priceId))
  ) {
    return "base";
  }

  // Backward-compatible default for legacy subscriptions that predate explicit plan mapping.
  if (
    STRIPE_BASE_PRODUCT_IDS.size === 0 &&
    STRIPE_PRO_PRODUCT_IDS.size === 0 &&
    STRIPE_BASE_PRICE_IDS.size === 0 &&
    STRIPE_PRO_PRICE_IDS.size === 0
  ) {
    return "pro";
  }

  return null;
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

async function activeManualBundle(ctx: ReadCtx, email: string, now: number): Promise<AccessGrantBundle | null> {
  let grantedFeatures = new Set<Feature>();
  let expiresAt: number | null = null;

  for (const feature of [APP_ACCESS_FEATURE, CLOUD_DICTATION_FEATURE] satisfies Feature[]) {
    const manual = await activeManualEntitlement(ctx, email, feature, now);
    if (!manual) {
      continue;
    }
    grantedFeatures.add(feature);
    if (manual.expiresAt !== undefined) {
      expiresAt = expiresAt === null ? manual.expiresAt : Math.max(expiresAt, manual.expiresAt);
    }
  }

  if (grantedFeatures.size === 0) {
    return null;
  }

  const planTier: PlanTier = grantedFeatures.has(CLOUD_DICTATION_FEATURE) ? "pro" : "base";
  for (const feature of grantedFeaturesForPlanTier(planTier)) {
    grantedFeatures.add(feature);
  }

  return {
    source: "manual",
    planTier,
    grantedFeatures: Array.from(grantedFeatures),
    expiresAt,
    freeLimitSeconds: null,
    freeUsedSeconds: null,
    freeRemainingSeconds: null,
    periodStartsAt: null,
    periodEndsAt: null,
  };
}

async function activeStripeBundle(ctx: ReadCtx, email: string, now: number): Promise<AccessGrantBundle | null> {
  const subscriptions = await ctx.db
    .query("stripeSubscriptions")
    .withIndex("by_email", (q) => q.eq("email", email))
    .collect();

  let bestPlanTier: PlanTier | null = null;
  let expiresAt: number | null = null;

  for (const subscription of subscriptions) {
    if (!activeStripeStatus(subscription.status)) {
      continue;
    }
    if (subscription.currentPeriodEnd !== undefined && subscription.currentPeriodEnd <= now) {
      continue;
    }

    const planTier = planTierForStripeSubscription(subscription);
    if (!planTier) {
      continue;
    }

    if (!bestPlanTier || planRank(planTier) > planRank(bestPlanTier)) {
      bestPlanTier = planTier;
    }
    if (subscription.currentPeriodEnd !== undefined) {
      expiresAt =
        expiresAt === null
          ? subscription.currentPeriodEnd
          : Math.max(expiresAt, subscription.currentPeriodEnd);
    }
  }

  if (!bestPlanTier) {
    return null;
  }

  return {
    source: "stripe",
    planTier: bestPlanTier,
    grantedFeatures: grantedFeaturesForPlanTier(bestPlanTier),
    expiresAt,
    freeLimitSeconds: null,
    freeUsedSeconds: null,
    freeRemainingSeconds: null,
    periodStartsAt: null,
    periodEndsAt: null,
  };
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
  const requestedFeature = feature as Feature;
  const manualBundle = await activeManualBundle(ctx, email, now);
  const stripeBundle = await activeStripeBundle(ctx, email, now);

  let freeBundle: AccessGrantBundle | null = null;
  if (requestedFeature === DEFAULT_FEATURE) {
    const period = monthPeriod(now);
    const usage = await usageForPeriod(ctx, email, requestedFeature, period.periodKey);
    const usedSeconds = usage?.usedSeconds ?? 0;
    const remainingSeconds = Math.max(0, FREE_MONTHLY_SECONDS - usedSeconds);

    freeBundle = {
      source: "free",
      planTier: "free",
      grantedFeatures: grantedFeaturesForPlanTier("free"),
      expiresAt: period.endsAt,
      freeLimitSeconds: FREE_MONTHLY_SECONDS,
      freeUsedSeconds: usedSeconds,
      freeRemainingSeconds: remainingSeconds,
      periodStartsAt: period.startsAt,
      periodEndsAt: period.endsAt,
    };
  }

  const bestBundle = [manualBundle, stripeBundle, freeBundle].reduce<AccessGrantBundle | null>(
    (current, candidate) => betterBundle(current, candidate),
    null,
  );

  const granted = bestBundle?.grantedFeatures.includes(requestedFeature) ?? false;
  const freeIsActive = bestBundle?.source === "free" && (bestBundle.freeRemainingSeconds ?? 0) > 0;
  const entitled = granted && (bestBundle?.source !== "free" || freeIsActive);

  return {
    entitled,
    source: bestBundle?.source ?? null,
    feature: requestedFeature,
    email,
    planTier: bestBundle?.planTier ?? null,
    grantedFeatures: bestBundle?.grantedFeatures ?? [],
    expiresAt: bestBundle?.expiresAt ?? null,
    freeLimitSeconds: bestBundle?.freeLimitSeconds ?? null,
    freeUsedSeconds: bestBundle?.freeUsedSeconds ?? null,
    freeRemainingSeconds: bestBundle?.freeRemainingSeconds ?? null,
    periodStartsAt: bestBundle?.periodStartsAt ?? null,
    periodEndsAt: bestBundle?.periodEndsAt ?? null,
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

    const manual = await activeManualBundle(ctx, email, now);
    const active = await activeStripeBundle(ctx, email, now);
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
