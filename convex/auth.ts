import { internalMutation, internalQuery } from "./_generated/server";
import { v } from "convex/values";

const MAX_CODE_ATTEMPTS = 5;
const MAX_CODES_TO_INVALIDATE = 25;

function normalizeEmail(email: string) {
  return email.trim().toLowerCase();
}

function constantTimeEqual(a: string, b: string) {
  if (a.length !== b.length) {
    return false;
  }
  let difference = 0;
  for (let index = 0; index < a.length; index += 1) {
    difference |= a.charCodeAt(index) ^ b.charCodeAt(index);
  }
  return difference === 0;
}

export const createEmailCode = internalMutation({
  args: {
    email: v.string(),
    codeHash: v.string(),
    expiresAt: v.number(),
  },
  handler: async (ctx, args) => {
    const email = normalizeEmail(args.email);
    const now = Date.now();
    // Only the newest code for an email is valid. Older codes that have not
    // expired yet are invalidated so they cannot be guessed in parallel.
    const recentCodes = await ctx.db
      .query("emailAuthCodes")
      .withIndex("by_email", (q) => q.eq("email", email))
      .order("desc")
      .take(MAX_CODES_TO_INVALIDATE);
    for (const code of recentCodes) {
      if (
        code.consumedAt === undefined &&
        code.invalidatedAt === undefined &&
        code.expiresAt > now
      ) {
        await ctx.db.patch(code._id, { invalidatedAt: now });
      }
    }

    return await ctx.db.insert("emailAuthCodes", {
      email,
      codeHash: args.codeHash,
      expiresAt: args.expiresAt,
      attempts: 0,
      createdAt: now,
    });
  },
});

export const consumeEmailCode = internalMutation({
  args: {
    email: v.string(),
    codeHash: v.string(),
  },
  handler: async (ctx, args): Promise<{ ok: boolean; locked: boolean }> => {
    const email = normalizeEmail(args.email);
    const now = Date.now();
    // Verify only against the newest code issued for this email.
    const code = await ctx.db
      .query("emailAuthCodes")
      .withIndex("by_email", (q) => q.eq("email", email))
      .order("desc")
      .first();

    if (
      !code ||
      code.consumedAt !== undefined ||
      code.invalidatedAt !== undefined ||
      code.expiresAt <= now
    ) {
      return { ok: false, locked: false };
    }

    if (code.attempts >= MAX_CODE_ATTEMPTS) {
      return { ok: false, locked: true };
    }

    if (!constantTimeEqual(code.codeHash, args.codeHash)) {
      const attempts = code.attempts + 1;
      await ctx.db.patch(code._id, { attempts });
      return { ok: false, locked: attempts >= MAX_CODE_ATTEMPTS };
    }

    await ctx.db.patch(code._id, {
      attempts: code.attempts + 1,
      consumedAt: now,
    });
    return { ok: true, locked: false };
  },
});

/**
 * Fixed-window rate limiter. Returns whether this request is allowed and,
 * when it is not, how long until the window resets.
 */
export const hitRateLimit = internalMutation({
  args: {
    key: v.string(),
    limit: v.number(),
    windowMs: v.number(),
  },
  handler: async (ctx, args): Promise<{ allowed: boolean; retryAfterMs: number }> => {
    const now = Date.now();
    const existing = await ctx.db
      .query("rateLimits")
      .withIndex("by_key", (q) => q.eq("key", args.key))
      .unique();

    if (!existing) {
      await ctx.db.insert("rateLimits", { key: args.key, windowStartedAt: now, count: 1 });
      return { allowed: true, retryAfterMs: 0 };
    }

    if (now - existing.windowStartedAt >= args.windowMs) {
      await ctx.db.patch(existing._id, { windowStartedAt: now, count: 1 });
      return { allowed: true, retryAfterMs: 0 };
    }

    if (existing.count >= args.limit) {
      return {
        allowed: false,
        retryAfterMs: Math.max(0, existing.windowStartedAt + args.windowMs - now),
      };
    }

    await ctx.db.patch(existing._id, { count: existing.count + 1 });
    return { allowed: true, retryAfterMs: 0 };
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
