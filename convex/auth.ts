import { internalMutation, internalQuery } from "./_generated/server";
import { v } from "convex/values";

function normalizeEmail(email: string) {
  return email.trim().toLowerCase();
}

export const createEmailCode = internalMutation({
  args: {
    email: v.string(),
    codeHash: v.string(),
    expiresAt: v.number(),
  },
  handler: async (ctx, args) => {
    return await ctx.db.insert("emailAuthCodes", {
      email: normalizeEmail(args.email),
      codeHash: args.codeHash,
      expiresAt: args.expiresAt,
      attempts: 0,
      createdAt: Date.now(),
    });
  },
});

export const consumeEmailCode = internalMutation({
  args: {
    email: v.string(),
    codeHash: v.string(),
  },
  handler: async (ctx, args) => {
    const email = normalizeEmail(args.email);
    const now = Date.now();
    const code = await ctx.db
      .query("emailAuthCodes")
      .withIndex("by_email_code_hash", (q) =>
        q.eq("email", email).eq("codeHash", args.codeHash),
      )
      .order("desc")
      .first();

    if (!code || code.consumedAt !== undefined || code.expiresAt <= now) {
      return false;
    }

    await ctx.db.patch(code._id, {
      attempts: code.attempts + 1,
      consumedAt: now,
    });
    return true;
  },
});

export const createSession = internalMutation({
  args: {
    email: v.string(),
    tokenHash: v.string(),
    expiresAt: v.number(),
  },
  handler: async (ctx, args) => {
    const email = normalizeEmail(args.email);
    const now = Date.now();
    const existingSession = await ctx.db
      .query("authSessions")
      .withIndex("by_email", (q) => q.eq("email", email))
      .first();

    await ctx.db.insert("authSessions", {
      email,
      tokenHash: args.tokenHash,
      expiresAt: args.expiresAt,
      createdAt: now,
      lastSeenAt: now,
    });

    return { isFirstSession: !existingSession };
  },
});

export const sessionForTokenHash = internalQuery({
  args: {
    tokenHash: v.string(),
  },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("authSessions")
      .withIndex("by_token_hash", (q) => q.eq("tokenHash", args.tokenHash))
      .unique();
  },
});

export const touchSession = internalMutation({
  args: {
    tokenHash: v.string(),
  },
  handler: async (ctx, args) => {
    const session = await ctx.db
      .query("authSessions")
      .withIndex("by_token_hash", (q) => q.eq("tokenHash", args.tokenHash))
      .unique();
    if (!session) {
      return;
    }
    await ctx.db.patch(session._id, { lastSeenAt: Date.now() });
  },
});
