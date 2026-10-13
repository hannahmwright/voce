import { internalMutation, internalQuery, type MutationCtx } from "./_generated/server";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { v } from "convex/values";

const MAX_CODE_ATTEMPTS = 5;
// Failed verifications per email per hour, independent of how many codes are
// issued. This is the brute-force bound: requesting new codes does not reset it.
const MAX_VERIFY_FAILURES_PER_HOUR = 10;
const VERIFY_FAILURE_WINDOW_MS = 60 * 60 * 1000;
// lastSeenAt is informational; refreshing it at most hourly avoids a database
// write on every authenticated request.
export const SESSION_TOUCH_INTERVAL_MS = 60 * 60 * 1000;
const CLEANUP_BATCH_SIZE = 200;
// Expired codes and stale rate-limit windows are kept for a day for debugging.
const AUTH_CODE_RETENTION_AFTER_EXPIRY_MS = 24 * 60 * 60 * 1000;
const RATE_LIMIT_RETENTION_MS = 24 * 60 * 60 * 1000;
// Long enough to cover any app retry of a usage report.
const USAGE_REPORT_RETENTION_MS = 45 * 24 * 60 * 60 * 1000;
const MAX_CODES_TO_INVALIDATE = 25;
// A user who taps "resend" may type the code from any of the recent emails.
const MAX_ACTIVE_CODES = 3;

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

async function emailAccountExists(ctx: MutationCtx, email: string) {
  const account = await ctx.db
    .query("emailAccounts")
    .withIndex("by_email", (q) => q.eq("email", email))
    .first();
  return account !== null;
}

// Emails verified before emailAccounts existed have no row; any earlier
// session, entitlement, Stripe record or usage means they are not new.
async function hasPriorActivity(ctx: MutationCtx, email: string) {
  const checks = [
    () => ctx.db.query("authSessions").withIndex("by_email", (q) => q.eq("email", email)).first(),
    () =>
      ctx.db
        .query("manualEntitlements")
        .withIndex("by_email_feature", (q) => q.eq("email", email))
        .first(),
    () => ctx.db.query("stripeCustomers").withIndex("by_email", (q) => q.eq("email", email)).first(),
    () =>
      ctx.db.query("stripeSubscriptions").withIndex("by_email", (q) => q.eq("email", email)).first(),
    () =>
      ctx.db
        .query("monthlyUsage")
        .withIndex("by_email_feature_period", (q) => q.eq("email", email))
        .first(),
  ];
  for (const check of checks) {
    if ((await check()) !== null) {
      return true;
    }
  }
  return false;
}

async function ensureEmailAccount(ctx: MutationCtx, email: string, firstSeenAt: number) {
  if (await emailAccountExists(ctx, email)) {
    return;
  }
  await ctx.db.insert("emailAccounts", { email, firstSeenAt });
}

type EmailAuthCode = {
  _id: Id<"emailAuthCodes">;
  codeHash: string;
  expiresAt: number;
  attempts: number;
  consumedAt?: number;
  invalidatedAt?: number;
};

function isUsableCode(code: EmailAuthCode, now: number) {
  return code.consumedAt === undefined && code.invalidatedAt === undefined && code.expiresAt > now;
}

async function usableCodesNewestFirst(ctx: MutationCtx, email: string, now: number) {
  const recentCodes = await ctx.db
    .query("emailAuthCodes")
    .withIndex("by_email", (q) => q.eq("email", email))
    .order("desc")
    .take(MAX_CODES_TO_INVALIDATE);
  return recentCodes.filter((code) => isUsableCode(code, now));
}

function verifyFailureKey(email: string) {
  return `auth-verify-failures:email:${email}`;
}

async function rateLimitRow(ctx: MutationCtx, key: string) {
  return await ctx.db
    .query("rateLimits")
    .withIndex("by_key", (q) => q.eq("key", key))
    .unique();
}

async function verifyFailuresExhausted(ctx: MutationCtx, email: string, now: number) {
  const row = await rateLimitRow(ctx, verifyFailureKey(email));
  return (
    row !== null &&
    now - row.windowStartedAt < VERIFY_FAILURE_WINDOW_MS &&
    row.count >= MAX_VERIFY_FAILURES_PER_HOUR
  );
}

// Returns the failure count in the current window after recording this one.
async function recordVerifyFailure(ctx: MutationCtx, email: string, now: number) {
  const key = verifyFailureKey(email);
  const row = await rateLimitRow(ctx, key);
  if (!row) {
    await ctx.db.insert("rateLimits", { key, windowStartedAt: now, count: 1 });
    return 1;
  }
  if (now - row.windowStartedAt >= VERIFY_FAILURE_WINDOW_MS) {
    await ctx.db.patch(row._id, { windowStartedAt: now, count: 1 });
    return 1;
  }
  await ctx.db.patch(row._id, { count: row.count + 1 });
  return row.count + 1;
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
    // At most MAX_ACTIVE_CODES codes stay valid, including the new one.
    // Codes with any failed attempt are burned so the new code starts with a
    // full set of attempts (failures are shared across active codes). The
    // per-email hourly failure cap in consumeEmailCode bounds brute force.
    const usableCodes = await usableCodesNewestFirst(ctx, email, now);
    let keptCodes = 0;
    for (const code of usableCodes) {
      if (code.attempts > 0 || keptCodes >= MAX_ACTIVE_CODES - 1) {
        await ctx.db.patch(code._id, { invalidatedAt: now });
      } else {
        keptCodes += 1;
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

// "code": the active codes used up their attempts; requesting a new code helps.
// "hourly": the per-email hourly failure cap; only waiting helps.
type ConsumeEmailCodeResult = {
  ok: boolean;
  locked: boolean;
  lockReason: "code" | "hourly" | null;
};

export const consumeEmailCode = internalMutation({
  args: {
    email: v.string(),
    codeHash: v.string(),
  },
  handler: async (ctx, args): Promise<ConsumeEmailCodeResult> => {
    const email = normalizeEmail(args.email);
    const now = Date.now();
    if (await verifyFailuresExhausted(ctx, email, now)) {
      return { ok: false, locked: true, lockReason: "hourly" };
    }
    const candidates = (await usableCodesNewestFirst(ctx, email, now)).slice(0, MAX_ACTIVE_CODES);
    if (candidates.length === 0) {
      return { ok: false, locked: false, lockReason: null };
    }

    // Failed attempts are shared across the active codes so issuing extra
    // codes does not multiply the guesses an attacker gets.
    const failures = Math.max(...candidates.map((code) => code.attempts));
    if (failures >= MAX_CODE_ATTEMPTS) {
      return { ok: false, locked: true, lockReason: "code" };
    }

    // Compare against every candidate so timing does not reveal which matched.
    let match: EmailAuthCode | null = null;
    for (const code of candidates) {
      const isMatch = constantTimeEqual(code.codeHash, args.codeHash);
      if (isMatch && match === null) {
        match = code;
      }
    }

    if (!match) {
      const attempts = failures + 1;
      for (const code of candidates) {
        await ctx.db.patch(code._id, { attempts });
      }
      const hourlyFailures = await recordVerifyFailure(ctx, email, now);
      // The hourly cap wins: a new code does not help until the window passes.
      if (hourlyFailures >= MAX_VERIFY_FAILURES_PER_HOUR) {
        return { ok: false, locked: true, lockReason: "hourly" };
      }
      if (attempts >= MAX_CODE_ATTEMPTS) {
        return { ok: false, locked: true, lockReason: "code" };
      }
      return { ok: false, locked: false, lockReason: null };
    }

    await ctx.db.patch(match._id, {
      attempts: match.attempts + 1,
      consumedAt: now,
    });
    for (const code of candidates) {
      if (code._id !== match._id) {
        await ctx.db.patch(code._id, { invalidatedAt: now });
      }
    }
    return { ok: true, locked: false, lockReason: null };
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
    let isFirstSession = false;
    if (!(await emailAccountExists(ctx, email))) {
      isFirstSession = !(await hasPriorActivity(ctx, email));
      await ctx.db.insert("emailAccounts", { email, firstSeenAt: now });
    }

    await ctx.db.insert("authSessions", {
      email,
      tokenHash: args.tokenHash,
      expiresAt: args.expiresAt,
      createdAt: now,
      lastSeenAt: now,
    });

    return { isFirstSession };
  },
});

export const sessionForTokenHash = internalQuery({
  args: {
    tokenHash: v.string(),
  },
  handler: async (ctx, args) => {
    const session = await ctx.db
      .query("authSessions")
      .withIndex("by_token_hash", (q) => q.eq("tokenHash", args.tokenHash))
      .unique();
    return session && session.revokedAt === undefined ? session : null;
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
    const now = Date.now();
    if (now - session.lastSeenAt < SESSION_TOUCH_INTERVAL_MS) {
      return;
    }
    await ctx.db.patch(session._id, { lastSeenAt: now });
  },
});

export const revokeSession = internalMutation({
  args: {
    tokenHash: v.string(),
  },
  handler: async (ctx, args) => {
    const session = await ctx.db
      .query("authSessions")
      .withIndex("by_token_hash", (q) => q.eq("tokenHash", args.tokenHash))
      .unique();
    if (!session) {
      return false;
    }
    if (session.revokedAt === undefined) {
      await ctx.db.patch(session._id, { revokedAt: Date.now() });
    }
    return true;
  },
});

/**
 * Deletes expired sessions, old login codes, stale rate-limit windows and
 * usage report IDs older than 45 days in
 * bounded batches. Scheduled hourly from crons.ts; reschedules itself while a
 * backlog remains.
 */
export const cleanupExpiredAuthRecords = internalMutation({
  args: {},
  handler: async (
    ctx,
  ): Promise<{
    sessions: number;
    codes: number;
    rateLimits: number;
    usageReports: number;
    hasMore: boolean;
  }> => {
    const now = Date.now();

    const sessions = await ctx.db
      .query("authSessions")
      .withIndex("by_expires_at", (q) => q.lt("expiresAt", now))
      .take(CLEANUP_BATCH_SIZE);
    for (const session of sessions) {
      // Keep the durable signup signal before the last session row disappears.
      await ensureEmailAccount(ctx, session.email, session.createdAt);
      await ctx.db.delete(session._id);
    }

    const codes = await ctx.db
      .query("emailAuthCodes")
      .withIndex("by_expires_at", (q) =>
        q.lt("expiresAt", now - AUTH_CODE_RETENTION_AFTER_EXPIRY_MS),
      )
      .take(CLEANUP_BATCH_SIZE);
    for (const code of codes) {
      await ctx.db.delete(code._id);
    }

    const rateLimits = await ctx.db
      .query("rateLimits")
      .withIndex("by_window_started_at", (q) =>
        q.lt("windowStartedAt", now - RATE_LIMIT_RETENTION_MS),
      )
      .take(CLEANUP_BATCH_SIZE);
    for (const rateLimit of rateLimits) {
      await ctx.db.delete(rateLimit._id);
    }

    const usageReports = await ctx.db
      .query("usageReports")
      .withIndex("by_applied_at", (q) => q.lt("appliedAt", now - USAGE_REPORT_RETENTION_MS))
      .take(CLEANUP_BATCH_SIZE);
    for (const usageReport of usageReports) {
      await ctx.db.delete(usageReport._id);
    }

    const hasMore =
      sessions.length === CLEANUP_BATCH_SIZE ||
      codes.length === CLEANUP_BATCH_SIZE ||
      rateLimits.length === CLEANUP_BATCH_SIZE ||
      usageReports.length === CLEANUP_BATCH_SIZE;
    if (hasMore) {
      await ctx.scheduler.runAfter(0, internal.auth.cleanupExpiredAuthRecords, {});
    }

    return {
      sessions: sessions.length,
      codes: codes.length,
      rateLimits: rateLimits.length,
      usageReports: usageReports.length,
      hasMore,
    };
  },
});
