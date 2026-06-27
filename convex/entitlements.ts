import { mutation, query, type MutationCtx, type QueryCtx } from "./_generated/server";
import { v } from "convex/values";

export const APP_ACCESS_FEATURE = "voce_app_access";
export const CLOUD_DICTATION_FEATURE = "voce_cloud_dictation";
export const TOTAL_DICTATION_FEATURE = "voce_dictation_total";
export const LOCAL_DICTATION_FEATURE = "voce_dictation_local";
export const BYOK_DICTATION_FEATURE = "voce_dictation_byok";
const DEFAULT_FEATURE = APP_ACCESS_FEATURE;
const FREE_MONTHLY_SECONDS = 30 * 60;
const CLOUD_MONTHLY_SECONDS = configuredPositiveInt("VOCE_CLOUD_MONTHLY_SECONDS") ?? 300 * 60;
const REALTIME_TRANSCRIPTION_COST_PER_MINUTE =
  configuredPositiveFloat("VOCE_REALTIME_TRANSCRIPTION_COST_PER_MINUTE") ?? 0.017;
type ReadCtx = QueryCtx | MutationCtx;
type Feature = typeof APP_ACCESS_FEATURE | typeof CLOUD_DICTATION_FEATURE;
type AuditOnlyFeature =
  | typeof TOTAL_DICTATION_FEATURE
  | typeof LOCAL_DICTATION_FEATURE
  | typeof BYOK_DICTATION_FEATURE;
type PlanTier = "free" | "base" | "pro";
type EntitlementSource = "free" | "manual" | "stripe";
type UsageBucket = "totalSeconds" | "hostedSeconds" | "localSeconds" | "byokSeconds";

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
  cloudLimitSeconds: number | null;
  cloudUsedSeconds: number | null;
  cloudRemainingSeconds: number | null;
  cloudPeriodStartsAt: number | null;
  cloudPeriodEndsAt: number | null;
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

function configuredPositiveInt(name: string) {
  const rawValue = (process.env[name] ?? "").trim();
  if (!rawValue) {
    return null;
  }
  const value = Number.parseInt(rawValue, 10);
  return Number.isFinite(value) && value > 0 ? value : null;
}

function configuredPositiveFloat(name: string) {
  const rawValue = (process.env[name] ?? "").trim();
  if (!rawValue) {
    return null;
  }
  const value = Number.parseFloat(rawValue);
  return Number.isFinite(value) && value > 0 ? value : null;
}

function isAuditOnlyFeature(feature: string): feature is AuditOnlyFeature {
  return (
    feature === TOTAL_DICTATION_FEATURE ||
    feature === LOCAL_DICTATION_FEATURE ||
    feature === BYOK_DICTATION_FEATURE
  );
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
    cloudLimitSeconds: null,
    cloudUsedSeconds: null,
    cloudRemainingSeconds: null,
    cloudPeriodStartsAt: null,
    cloudPeriodEndsAt: null,
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
    cloudLimitSeconds: null,
    cloudUsedSeconds: null,
    cloudRemainingSeconds: null,
    cloudPeriodStartsAt: null,
    cloudPeriodEndsAt: null,
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

async function addUsageSeconds(
  ctx: MutationCtx,
  email: string,
  feature: string,
  seconds: number,
  now: number,
) {
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
}

async function entitlementFor(ctx: ReadCtx, email: string, feature: string) {
  const now = Date.now();
  const requestedFeature = feature as Feature;
  const manualBundle = await activeManualBundle(ctx, email, now);
  const stripeBundle = await activeStripeBundle(ctx, email, now);
  const cloudPeriod = monthPeriod(now);
  const cloudUsage = await usageForPeriod(
    ctx,
    email,
    CLOUD_DICTATION_FEATURE,
    cloudPeriod.periodKey,
  );
  const cloudUsedSeconds = cloudUsage?.usedSeconds ?? 0;
  const cloudRemainingSeconds = Math.max(0, CLOUD_MONTHLY_SECONDS - cloudUsedSeconds);

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
      cloudLimitSeconds: null,
      cloudUsedSeconds: null,
      cloudRemainingSeconds: null,
      cloudPeriodStartsAt: null,
      cloudPeriodEndsAt: null,
    };
  }

  const bestBundle = [manualBundle, stripeBundle, freeBundle].reduce<AccessGrantBundle | null>(
    (current, candidate) => betterBundle(current, candidate),
    null,
  );

  const granted = bestBundle?.grantedFeatures.includes(requestedFeature) ?? false;
  const freeIsActive = bestBundle?.source === "free" && (bestBundle.freeRemainingSeconds ?? 0) > 0;
  const cloudIsActive =
    requestedFeature !== CLOUD_DICTATION_FEATURE ||
    (bestBundle?.planTier === "pro" && cloudRemainingSeconds > 0);
  const entitled = granted && (bestBundle?.source !== "free" || freeIsActive) && cloudIsActive;
  const hasProCloudAccess = bestBundle?.grantedFeatures.includes(CLOUD_DICTATION_FEATURE) ?? false;

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
    cloudLimitSeconds: hasProCloudAccess ? CLOUD_MONTHLY_SECONDS : null,
    cloudUsedSeconds: hasProCloudAccess ? cloudUsedSeconds : null,
    cloudRemainingSeconds: hasProCloudAccess ? cloudRemainingSeconds : null,
    cloudPeriodStartsAt: hasProCloudAccess ? cloudPeriod.startsAt : null,
    cloudPeriodEndsAt: hasProCloudAccess ? cloudPeriod.endsAt : null,
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
    const entitlementFeature = isAuditOnlyFeature(feature) ? DEFAULT_FEATURE : feature;

    if (seconds === 0) {
      return await entitlementFor(ctx, email, entitlementFeature);
    }

    if (isAuditOnlyFeature(feature)) {
      const entitlement = await entitlementFor(ctx, email, DEFAULT_FEATURE);
      if (!entitlement.entitled) {
        return entitlement;
      }
      await addUsageSeconds(ctx, email, feature, seconds, now);
      if (feature !== TOTAL_DICTATION_FEATURE) {
        await addUsageSeconds(ctx, email, TOTAL_DICTATION_FEATURE, seconds, now);
      }
      return await entitlementFor(ctx, email, DEFAULT_FEATURE);
    }

    const entitlement = await entitlementFor(ctx, email, feature);
    if (
      feature !== CLOUD_DICTATION_FEATURE &&
      (entitlement.source === "manual" || entitlement.source === "stripe" || feature !== DEFAULT_FEATURE)
    ) {
      return await entitlementFor(ctx, email, feature);
    }
    if (feature === CLOUD_DICTATION_FEATURE && !entitlement.grantedFeatures.includes(CLOUD_DICTATION_FEATURE)) {
      return entitlement;
    }

    await addUsageSeconds(ctx, email, feature, seconds, now);
    if (feature === CLOUD_DICTATION_FEATURE) {
      await addUsageSeconds(ctx, email, TOTAL_DICTATION_FEATURE, seconds, now);
    }

    return await entitlementFor(ctx, email, feature);
  },
});

function recentPeriodKeys(count: number, now: number) {
  const monthCount = Math.max(1, Math.min(36, Math.floor(count)));
  const cursor = new Date(now);
  cursor.setUTCDate(1);
  cursor.setUTCHours(0, 0, 0, 0);

  const periods: string[] = [];
  for (let index = 0; index < monthCount; index += 1) {
    periods.push(
      `${cursor.getUTCFullYear()}-${String(cursor.getUTCMonth() + 1).padStart(2, "0")}`,
    );
    cursor.setUTCMonth(cursor.getUTCMonth() - 1);
  }
  return periods.reverse();
}

function emptyUsagePeriod(periodKey: string) {
  return {
    periodKey,
    totalSeconds: 0,
    hostedSeconds: 0,
    localSeconds: 0,
    byokSeconds: 0,
    estimatedCostUSD: 0,
  };
}

function estimatedHostedCostUSD(hostedSeconds: number, costPerHostedMinuteUSD: number) {
  return Math.round((hostedSeconds / 60) * costPerHostedMinuteUSD * 10_000) / 10_000;
}

function usageBucketForFeature(feature: string): UsageBucket | null {
  switch (feature) {
    case TOTAL_DICTATION_FEATURE:
      return "totalSeconds";
    case CLOUD_DICTATION_FEATURE:
      return "hostedSeconds";
    case LOCAL_DICTATION_FEATURE:
      return "localSeconds";
    case BYOK_DICTATION_FEATURE:
      return "byokSeconds";
    default:
      return null;
  }
}

export const usageAudit = query({
  args: {
    months: v.optional(v.number()),
    costPerHostedMinuteUSD: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    const periodKeys = recentPeriodKeys(args.months ?? 6, now);
    const costPerHostedMinuteUSD =
      args.costPerHostedMinuteUSD !== undefined && Number.isFinite(args.costPerHostedMinuteUSD)
        ? Math.max(0, args.costPerHostedMinuteUSD)
        : REALTIME_TRANSCRIPTION_COST_PER_MINUTE;
    const trackedFeatures = [
      TOTAL_DICTATION_FEATURE,
      CLOUD_DICTATION_FEATURE,
      LOCAL_DICTATION_FEATURE,
      BYOK_DICTATION_FEATURE,
    ];
    const userSummaries = new Map<
      string,
      {
        email: string;
        totalSeconds: number;
        hostedSeconds: number;
        localSeconds: number;
        byokSeconds: number;
        estimatedCostUSD: number;
        byPeriod: Map<string, ReturnType<typeof emptyUsagePeriod>>;
      }
    >();

    function summaryForEmail(email: string) {
      let summary = userSummaries.get(email);
      if (!summary) {
        summary = {
          email,
          totalSeconds: 0,
          hostedSeconds: 0,
          localSeconds: 0,
          byokSeconds: 0,
          estimatedCostUSD: 0,
          byPeriod: new Map(periodKeys.map((periodKey) => [periodKey, emptyUsagePeriod(periodKey)])),
        };
        userSummaries.set(email, summary);
      }
      return summary;
    }

    for (const periodKey of periodKeys) {
      for (const feature of trackedFeatures) {
        const bucket = usageBucketForFeature(feature);
        if (!bucket) {
          continue;
        }
        const rows = await ctx.db
          .query("monthlyUsage")
          .withIndex("by_feature_period", (q) => q.eq("feature", feature).eq("periodKey", periodKey))
          .collect();
        for (const row of rows) {
          const summary = summaryForEmail(row.email);
          const period = summary.byPeriod.get(periodKey) ?? emptyUsagePeriod(periodKey);
          summary[bucket] += row.usedSeconds;
          period[bucket] += row.usedSeconds;
          summary.byPeriod.set(periodKey, period);
        }
      }
    }

    const totals = {
      totalSeconds: 0,
      hostedSeconds: 0,
      localSeconds: 0,
      byokSeconds: 0,
      estimatedCostUSD: 0,
    };

    const users = Array.from(userSummaries.values())
      .map((summary) => {
        const byPeriod = periodKeys.map((periodKey) => {
          const period = summary.byPeriod.get(periodKey) ?? emptyUsagePeriod(periodKey);
          return {
            ...period,
            estimatedCostUSD: estimatedHostedCostUSD(
              period.hostedSeconds,
              costPerHostedMinuteUSD,
            ),
          };
        });
        const estimatedCostUSD = estimatedHostedCostUSD(
          summary.hostedSeconds,
          costPerHostedMinuteUSD,
        );

        totals.totalSeconds += summary.totalSeconds;
        totals.hostedSeconds += summary.hostedSeconds;
        totals.localSeconds += summary.localSeconds;
        totals.byokSeconds += summary.byokSeconds;
        totals.estimatedCostUSD += estimatedCostUSD;

        return {
          email: summary.email,
          totalSeconds: summary.totalSeconds,
          hostedSeconds: summary.hostedSeconds,
          localSeconds: summary.localSeconds,
          byokSeconds: summary.byokSeconds,
          totalMinutes: Math.round((summary.totalSeconds / 60) * 100) / 100,
          hostedMinutes: Math.round((summary.hostedSeconds / 60) * 100) / 100,
          localMinutes: Math.round((summary.localSeconds / 60) * 100) / 100,
          byokMinutes: Math.round((summary.byokSeconds / 60) * 100) / 100,
          estimatedCostUSD,
          byPeriod,
        };
      })
      .sort((a, b) => b.totalSeconds - a.totalSeconds || a.email.localeCompare(b.email));

    totals.estimatedCostUSD = Math.round(totals.estimatedCostUSD * 10_000) / 10_000;

    return {
      generatedAt: now,
      periodKeys,
      costPerHostedMinuteUSD,
      features: {
        total: TOTAL_DICTATION_FEATURE,
        hosted: CLOUD_DICTATION_FEATURE,
        local: LOCAL_DICTATION_FEATURE,
        byok: BYOK_DICTATION_FEATURE,
      },
      totals: {
        ...totals,
        totalMinutes: Math.round((totals.totalSeconds / 60) * 100) / 100,
        hostedMinutes: Math.round((totals.hostedSeconds / 60) * 100) / 100,
        localMinutes: Math.round((totals.localSeconds / 60) * 100) / 100,
        byokMinutes: Math.round((totals.byokSeconds / 60) * 100) / 100,
      },
      users,
    };
  },
});

async function upsertManualEntitlement(
  ctx: MutationCtx,
  args: {
    email: string;
    feature: Feature;
    expiresAt?: number;
    note?: string;
  },
) {
  const now = Date.now();
  const existing = await ctx.db
    .query("manualEntitlements")
    .withIndex("by_email_feature", (q) =>
      q.eq("email", args.email).eq("feature", args.feature),
    )
    .unique();

  if (existing) {
    await ctx.db.patch(existing._id, {
      expiresAt: args.expiresAt,
      note: args.note,
      updatedAt: now,
    });
    return existing._id;
  }

  return await ctx.db.insert("manualEntitlements", {
    email: args.email,
    feature: args.feature,
    expiresAt: args.expiresAt,
    note: args.note,
    createdAt: now,
    updatedAt: now,
  });
}

async function deleteManualEntitlement(
  ctx: MutationCtx,
  email: string,
  feature: Feature,
) {
  const existing = await ctx.db
    .query("manualEntitlements")
    .withIndex("by_email_feature", (q) => q.eq("email", email).eq("feature", feature))
    .unique();

  if (!existing) return false;
  await ctx.db.delete(existing._id);
  return true;
}

export const grantManual = mutation({
  args: {
    email: v.string(),
    feature: v.optional(v.string()),
    planTier: v.optional(v.union(v.literal("base"), v.literal("pro"))),
    expiresAt: v.optional(v.number()),
    note: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const email = normalizeEmail(args.email);

    if (args.planTier) {
      // Tier shorthand grants every feature implied by the tier in one call so an admin
      // who picks "pro" never accidentally leaves out cloud dictation.
      const features = grantedFeaturesForPlanTier(args.planTier);
      const ids: string[] = [];
      for (const feature of features) {
        const id = await upsertManualEntitlement(ctx, {
          email,
          feature,
          expiresAt: args.expiresAt,
          note: args.note,
        });
        ids.push(String(id));
      }
      return { planTier: args.planTier, features, ids };
    }

    const feature = (args.feature ?? DEFAULT_FEATURE) as Feature;
    return await upsertManualEntitlement(ctx, {
      email,
      feature,
      expiresAt: args.expiresAt,
      note: args.note,
    });
  },
});

export const revokeManual = mutation({
  args: {
    email: v.string(),
    feature: v.optional(v.string()),
    planTier: v.optional(v.union(v.literal("base"), v.literal("pro"), v.literal("all"))),
  },
  handler: async (ctx, args) => {
    const email = normalizeEmail(args.email);

    if (args.planTier) {
      // "base" revokes app access only; "pro" revokes cloud dictation only;
      // "all" revokes everything so the admin can fully reset a manual grant.
      const features: Feature[] =
        args.planTier === "all"
          ? [APP_ACCESS_FEATURE, CLOUD_DICTATION_FEATURE]
          : args.planTier === "pro"
            ? [CLOUD_DICTATION_FEATURE]
            : [APP_ACCESS_FEATURE];
      let removed = false;
      for (const feature of features) {
        const didDelete = await deleteManualEntitlement(ctx, email, feature);
        removed = removed || didDelete;
      }
      return removed;
    }

    const feature = (args.feature ?? DEFAULT_FEATURE) as Feature;
    return await deleteManualEntitlement(ctx, email, feature);
  },
});
