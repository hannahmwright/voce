import { internalMutation, internalQuery } from "./_generated/server";
import { v } from "convex/values";

function normalizeEmail(email: string) {
  return email.trim().toLowerCase();
}

type StoredSubscription = {
  priceId?: string;
  productId?: string;
  currentPeriodEnd?: number;
  lastStripeEventAt?: number;
};

// Stripe does not guarantee delivery order, and retries can deliver an old
// event after a newer one. An event older than the newest one already applied
// must not overwrite status (for example resurrecting a canceled subscription).
function isStaleEvent(existing: StoredSubscription, eventCreatedAt: number | undefined) {
  return (
    eventCreatedAt !== undefined &&
    existing.lastStripeEventAt !== undefined &&
    eventCreatedAt < existing.lastStripeEventAt
  );
}

// A stale event may still carry plan details that a newer but sparser event
// (such as checkout.session.completed) did not include. Fill only fields that
// are still missing so plan mapping keeps working.
function staleEventBackfill(
  existing: StoredSubscription,
  args: { priceId?: string; productId?: string; currentPeriodEnd?: number },
) {
  const backfill: { priceId?: string; productId?: string; currentPeriodEnd?: number } = {};
  if (existing.priceId === undefined && args.priceId !== undefined) {
    backfill.priceId = args.priceId;
  }
  if (existing.productId === undefined && args.productId !== undefined) {
    backfill.productId = args.productId;
  }
  if (existing.currentPeriodEnd === undefined && args.currentPeriodEnd !== undefined) {
    backfill.currentPeriodEnd = args.currentPeriodEnd;
  }
  return Object.keys(backfill).length > 0 ? backfill : null;
}

function nextLastStripeEventAt(
  existing: StoredSubscription | null,
  eventCreatedAt: number | undefined,
) {
  if (eventCreatedAt === undefined) {
    return existing?.lastStripeEventAt;
  }
  return Math.max(existing?.lastStripeEventAt ?? 0, eventCreatedAt);
}

export const upsertCustomer = internalMutation({
  args: {
    stripeCustomerId: v.string(),
    email: v.string(),
  },
  handler: async (ctx, args) => {
    const email = normalizeEmail(args.email);
    const now = Date.now();
    const existing = await ctx.db
      .query("stripeCustomers")
      .withIndex("by_stripe_customer_id", (q) => q.eq("stripeCustomerId", args.stripeCustomerId))
      .unique();

    if (existing) {
      await ctx.db.patch(existing._id, {
        email,
        updatedAt: now,
      });
      return existing._id;
    }

    return await ctx.db.insert("stripeCustomers", {
      stripeCustomerId: args.stripeCustomerId,
      email,
      createdAt: now,
      updatedAt: now,
    });
  },
});

export const customerForEmail = internalQuery({
  args: {
    email: v.string(),
  },
  handler: async (ctx, args) => {
    const email = normalizeEmail(args.email);
    const customers = await ctx.db
      .query("stripeCustomers")
      .withIndex("by_email", (q) => q.eq("email", email))
      .collect();

    return customers.reduce<(typeof customers)[number] | null>((newest, customer) => {
      if (!newest || customer.updatedAt > newest.updatedAt) {
        return customer;
      }
      return newest;
    }, null);
  },
});

export const upsertSubscription = internalMutation({
  args: {
    stripeSubscriptionId: v.string(),
    stripeCustomerId: v.string(),
    email: v.string(),
    status: v.string(),
    priceId: v.optional(v.string()),
    productId: v.optional(v.string()),
    currentPeriodEnd: v.optional(v.number()),
    cancelAtPeriodEnd: v.optional(v.boolean()),
    eventCreatedAt: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const email = normalizeEmail(args.email);
    const now = Date.now();
    const existing = await ctx.db
      .query("stripeSubscriptions")
      .withIndex("by_stripe_subscription_id", (q) =>
        q.eq("stripeSubscriptionId", args.stripeSubscriptionId)
      )
      .unique();

    if (existing && isStaleEvent(existing, args.eventCreatedAt)) {
      const backfill = staleEventBackfill(existing, args);
      if (backfill) {
        await ctx.db.patch(existing._id, { ...backfill, updatedAt: now });
      }
      return existing._id;
    }

    const lastStripeEventAt = nextLastStripeEventAt(existing, args.eventCreatedAt);
    const fields = {
      stripeCustomerId: args.stripeCustomerId,
      email,
      status: args.status,
      priceId: args.priceId,
      productId: args.productId,
      currentPeriodEnd: args.currentPeriodEnd,
      cancelAtPeriodEnd: args.cancelAtPeriodEnd,
      ...(lastStripeEventAt !== undefined ? { lastStripeEventAt } : {}),
      updatedAt: now,
    };

    if (existing) {
      await ctx.db.patch(existing._id, fields);
      return existing._id;
    }

    return await ctx.db.insert("stripeSubscriptions", {
      stripeSubscriptionId: args.stripeSubscriptionId,
      createdAt: now,
      ...fields,
    });
  },
});

export const upsertSubscriptionFromWebhook = internalMutation({
  args: {
    stripeSubscriptionId: v.string(),
    stripeCustomerId: v.string(),
    email: v.optional(v.string()),
    status: v.string(),
    priceId: v.optional(v.string()),
    productId: v.optional(v.string()),
    currentPeriodEnd: v.optional(v.number()),
    cancelAtPeriodEnd: v.optional(v.boolean()),
    eventCreatedAt: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    const existing = await ctx.db
      .query("stripeSubscriptions")
      .withIndex("by_stripe_subscription_id", (q) =>
        q.eq("stripeSubscriptionId", args.stripeSubscriptionId)
      )
      .unique();

    if (!existing && !args.email) {
      return null;
    }

    if (existing && isStaleEvent(existing, args.eventCreatedAt)) {
      const backfill = staleEventBackfill(existing, args);
      if (backfill) {
        await ctx.db.patch(existing._id, { ...backfill, updatedAt: now });
      }
      return existing._id;
    }

    const fields: {
      stripeCustomerId: string;
      email?: string;
      status: string;
      priceId?: string;
      productId?: string;
      currentPeriodEnd?: number;
      cancelAtPeriodEnd?: boolean;
      lastStripeEventAt?: number;
      updatedAt: number;
    } = {
      stripeCustomerId: args.stripeCustomerId,
      ...(args.email ? { email: normalizeEmail(args.email) } : {}),
      status: args.status,
      updatedAt: now,
    };
    if (args.priceId !== undefined) {
      fields.priceId = args.priceId;
    }
    if (args.productId !== undefined) {
      fields.productId = args.productId;
    }
    if (args.currentPeriodEnd !== undefined) {
      fields.currentPeriodEnd = args.currentPeriodEnd;
    }
    if (args.cancelAtPeriodEnd !== undefined) {
      fields.cancelAtPeriodEnd = args.cancelAtPeriodEnd;
    }
    const lastStripeEventAt = nextLastStripeEventAt(existing, args.eventCreatedAt);
    if (lastStripeEventAt !== undefined) {
      fields.lastStripeEventAt = lastStripeEventAt;
    }

    if (existing) {
      await ctx.db.patch(existing._id, fields);
      return existing._id;
    }

    return await ctx.db.insert("stripeSubscriptions", {
      stripeSubscriptionId: args.stripeSubscriptionId,
      email: normalizeEmail(args.email!),
      createdAt: now,
      ...fields,
    });
  },
});
