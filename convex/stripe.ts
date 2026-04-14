import { internalMutation, internalQuery } from "./_generated/server";
import { v } from "convex/values";

function normalizeEmail(email: string) {
  return email.trim().toLowerCase();
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

    const fields = {
      stripeCustomerId: args.stripeCustomerId,
      email,
      status: args.status,
      priceId: args.priceId,
      productId: args.productId,
      currentPeriodEnd: args.currentPeriodEnd,
      cancelAtPeriodEnd: args.cancelAtPeriodEnd,
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

    const fields: {
      stripeCustomerId: string;
      email?: string;
      status: string;
      priceId?: string;
      productId?: string;
      currentPeriodEnd?: number;
      cancelAtPeriodEnd?: boolean;
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
