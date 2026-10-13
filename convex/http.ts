import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";
import { internal } from "./_generated/api";
import Stripe from "stripe";
import { APP_ACCESS_FEATURE, CLOUD_DICTATION_FEATURE } from "./entitlements";
import { SESSION_TOUCH_INTERVAL_MS } from "./auth";
import {
  CloudDictationProviderError,
  createRealtimeTranscriptionSession,
  refineWithCloudProvider,
  runCloudDictationPreflight,
  transcribeWithCloudProvider,
} from "./cloudDictation";

const http = httpRouter();

const DEFAULT_FEATURE = APP_ACCESS_FEATURE;
const CHECKOUT_PLAN_VALUES = new Set(["base", "pro"]);
const CHECKOUT_BILLING_VALUES = new Set(["monthly", "annual"]);
const EMAIL_CODE_TTL_MS = 10 * 60 * 1000;
const RATE_LIMIT_WINDOW_MS = 60 * 60 * 1000;
// Per-email limits only: no client IP header is documented as set by the
// Convex edge, and forwarded-IP headers can be forged by clients.
const AUTH_START_LIMIT_PER_EMAIL = 10;
const SUPPORT_LIMIT_PER_EMAIL = 5;
// Request size limits. A 60-minute dictation is roughly 10k words (~60k
// characters), and OpenAI's transcription endpoint accepts files up to 25 MB.
const MAX_JSON_BODY_BYTES = 2 * 1024 * 1024;
const MAX_TRANSCRIBE_AUDIO_BYTES = 25 * 1024 * 1024;
const MAX_TRANSCRIBE_FORM_OVERHEAD_BYTES = 1024 * 1024;
const MAX_REFINE_TRANSCRIPT_CHARS = 100_000;
const MAX_HINTS = 500;
const MAX_HINT_CHARS = 200;
const MAX_DICTIONARY_ENTRIES = 1000;
const MAX_DICTIONARY_FIELD_CHARS = 500;
const MAX_SUPPORT_DIAGNOSTICS_CHARS = 200_000;
const SESSION_TTL_MS = 90 * 24 * 60 * 60 * 1000;
// Refuse to mint a realtime client secret when less hosted time than this is left.
const MIN_HOSTED_SECONDS_FOR_REALTIME_SESSION = 30;
// The app maps a 403 containing "monthly minutes" to its hosted-minutes-exhausted state.
const HOSTED_MINUTES_EXHAUSTED_MESSAGE =
  "Voce Cloud monthly minutes are used. Use your OpenAI key or local dictation until next month.";

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

async function rateLimited(
  ctx: any,
  checks: Array<{ key: string; limit: number }>,
  body: { error: string; code: string },
): Promise<Response | null> {
  for (const check of checks) {
    const result = await ctx.runMutation(internal.auth.hitRateLimit, {
      key: check.key,
      limit: check.limit,
      windowMs: RATE_LIMIT_WINDOW_MS,
    });
    if (!result.allowed) {
      const retryAfterSeconds = Math.max(1, Math.ceil(result.retryAfterMs / 1000));
      return new Response(
        JSON.stringify(body),
        {
          status: 429,
          headers: {
            "content-type": "application/json",
            "retry-after": String(retryAfterSeconds),
          },
        },
      );
    }
  }
  return null;
}

function declaredContentLength(request: Request) {
  const value = Number.parseInt(request.headers.get("content-length") ?? "", 10);
  return Number.isFinite(value) && value >= 0 ? value : null;
}

function payloadTooLarge(message: string) {
  return jsonResponse({ error: message }, 413);
}

async function readLimitedJSON<T>(
  request: Request,
  maxBytes: number,
): Promise<{ body: T } | { response: Response }> {
  const declaredLength = declaredContentLength(request);
  if (declaredLength !== null && declaredLength > maxBytes) {
    return { response: payloadTooLarge("Request body is too large.") };
  }
  const text = await request.text();
  if (new TextEncoder().encode(text).length > maxBytes) {
    return { response: payloadTooLarge("Request body is too large.") };
  }
  try {
    return { body: JSON.parse(text) as T };
  } catch {
    return { response: jsonResponse({ error: "Invalid JSON body" }, 400) };
  }
}

// Hints only steer spelling; the providers use at most a few hundred, so
// oversized lists are trimmed rather than rejected.
function sanitizedHints(value: unknown) {
  if (!Array.isArray(value)) {
    return [];
  }
  return value
    .filter((hint): hint is string => typeof hint === "string" && hint.length <= MAX_HINT_CHARS)
    .slice(0, MAX_HINTS);
}

function bearerToken(request: Request) {
  const authorization = request.headers.get("authorization") ?? "";
  const prefix = "Bearer ";
  return authorization.startsWith(prefix) ? authorization.slice(prefix.length) : null;
}

function normalizeEmail(email: string) {
  return email.trim().toLowerCase();
}

function configuredEmailSet(...names: string[]) {
  const emails = names.flatMap((name) =>
    (process.env[name] ?? "")
      .split(",")
      .map((value) => value.trim())
      .map((value) => value.match(/<([^>]+)>/)?.[1] ?? value)
      .map(normalizeEmail)
      .filter(isValidEmail),
  );
  return new Set(emails);
}

function adminEmailSet() {
  // Only explicitly listed admins; support and signup inboxes are not admins.
  return configuredEmailSet("VOCE_ADMIN_EMAILS");
}

function secretsMatch(provided: string, expected: string) {
  if (provided.length !== expected.length) {
    return false;
  }
  let difference = 0;
  for (let index = 0; index < provided.length; index += 1) {
    difference |= provided.charCodeAt(index) ^ expected.charCodeAt(index);
  }
  return difference === 0;
}

function isAdminEmail(email: string) {
  return adminEmailSet().has(normalizeEmail(email));
}

function isValidEmail(email: string) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

function randomDigits(length: number) {
  // Rejection sampling: bytes 250-255 are discarded so every digit is equally likely.
  const digits: string[] = [];
  const bytes = new Uint8Array(Math.max(16, length * 2));
  while (digits.length < length) {
    crypto.getRandomValues(bytes);
    for (const byte of bytes) {
      if (byte < 250) {
        digits.push(String(byte % 10));
        if (digits.length === length) {
          break;
        }
      }
    }
  }
  return digits.join("");
}

function randomToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(value: string) {
  const data = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function authSecret() {
  return process.env.VOCE_AUTH_SECRET;
}

async function codeHash(email: string, code: string) {
  const secret = authSecret();
  if (!secret) {
    throw new Error("Voce auth is not configured");
  }
  return await sha256Hex(`${secret}:code:${normalizeEmail(email)}:${code}`);
}

async function tokenHash(token: string) {
  const secret = authSecret();
  if (!secret) {
    throw new Error("Voce auth is not configured");
  }
  return await sha256Hex(`${secret}:session:${token}`);
}

async function sendAccessCodeEmail(email: string, code: string) {
  const apiKey = process.env.RESEND_API_KEY;
  const from = process.env.VOCE_AUTH_EMAIL_FROM ?? "Voce <access@voceapp.io>";
  if (!apiKey) {
    throw new Error("Email auth is not configured");
  }

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      from,
      to: email,
      subject: "Your Voce access code",
      text: `Your Voce access code is ${code}. It expires in 10 minutes.`,
    }),
  });

  if (!response.ok) {
    const responseText = await response.text();
    throw new Error(`Resend rejected access code email with ${response.status}: ${responseText}`);
  }
}

function normalizedMultilineText(value: string) {
  return value
    .replace(/\r\n/g, "\n")
    .split("\n")
    .map((line) => line.trimEnd())
    .join("\n")
    .trim();
}

function supportCategoryTitle(category: string) {
  switch (category) {
    case "bug":
      return "Bug report";
    case "feature":
      return "Feature request";
    default:
      return "Support request";
  }
}

function configuredPriceID(plan: string, billing: string) {
  switch (`${plan}:${billing}`) {
    case "base:monthly":
      return process.env.STRIPE_BASE_MONTHLY_PRICE_ID;
    case "base:annual":
      return process.env.STRIPE_BASE_ANNUAL_PRICE_ID;
    case "pro:monthly":
      return process.env.STRIPE_PRO_MONTHLY_PRICE_ID;
    case "pro:annual":
      return process.env.STRIPE_PRO_ANNUAL_PRICE_ID;
    default:
      return undefined;
  }
}

function checkoutSuccessURL() {
  return process.env.STRIPE_CHECKOUT_SUCCESS_URL ?? process.env.STRIPE_PORTAL_RETURN_URL;
}

function checkoutCancelURL() {
  return process.env.STRIPE_CHECKOUT_CANCEL_URL ?? process.env.STRIPE_PORTAL_RETURN_URL;
}

async function sendSupportEmail(payload: {
  category: string;
  email: string;
  subject: string;
  message: string;
  appVersion: string;
  buildNumber: string;
  macOSVersion: string;
  includeDiagnostics: boolean;
  diagnostics?: string;
}) {
  const apiKey = process.env.RESEND_API_KEY;
  const from = process.env.VOCE_SUPPORT_EMAIL_FROM ?? "Voce Support <support@voceapp.io>";
  const to = process.env.VOCE_SUPPORT_EMAIL_TO ?? "h.wright@vervetechgroup.com";
  if (!apiKey) {
    throw new Error("Support email is not configured");
  }

  const lines = [
    `Category: ${supportCategoryTitle(payload.category)}`,
    `From: ${payload.email}`,
    `Subject: ${payload.subject}`,
    `App version: ${payload.appVersion} (${payload.buildNumber})`,
    `macOS: ${payload.macOSVersion}`,
    `Diagnostics included: ${payload.includeDiagnostics ? "yes" : "no"}`,
    "",
    "Message:",
    payload.message,
  ];

  if (payload.includeDiagnostics && payload.diagnostics) {
    lines.push("", "Diagnostics:", payload.diagnostics);
  }

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      from,
      to,
      reply_to: payload.email,
      subject: `[Voce] ${supportCategoryTitle(payload.category)}: ${payload.subject}`,
      text: lines.join("\n"),
    }),
  });

  if (!response.ok) {
    const responseText = await response.text();
    throw new Error(`Resend rejected support email with ${response.status}: ${responseText}`);
  }
}

async function sendSignupEmail(payload: {
  email: string;
  source: string;
  planTier: string;
}) {
  const apiKey = process.env.RESEND_API_KEY;
  const from = process.env.VOCE_SUPPORT_EMAIL_FROM ?? "Voce Support <support@voceapp.io>";
  const to =
    process.env.VOCE_SIGNUP_EMAIL_TO ??
    process.env.VOCE_SUPPORT_EMAIL_TO ??
    "h.wright@vervetechgroup.com";
  if (!apiKey) {
    throw new Error("Signup email is not configured");
  }

  const lines = [
    "A new Voce user verified their email.",
    "",
    `Email: ${payload.email}`,
    `Plan: ${payload.planTier}`,
    `Source: ${payload.source}`,
  ];

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      from,
      to,
      subject: `[Voce] New signup: ${payload.email}`,
      text: lines.join("\n"),
    }),
  });

  if (!response.ok) {
    const responseText = await response.text();
    throw new Error(`Resend rejected signup email with ${response.status}: ${responseText}`);
  }
}

async function verifiedSessionEmail(ctx: any, request: Request, requestedEmail: string) {
  const token = request.headers.get("x-voce-session-token");
  if (!token) {
    return null;
  }

  const hash = await tokenHash(token);
  const session = await ctx.runQuery(internal.auth.sessionForTokenHash, { tokenHash: hash });
  if (!session || session.revokedAt !== undefined || session.expiresAt <= Date.now()) {
    return null;
  }

  const email = normalizeEmail(requestedEmail);
  if (session.email !== email) {
    return null;
  }

  if (Date.now() - session.lastSeenAt >= SESSION_TOUCH_INTERVAL_MS) {
    await ctx.runMutation(internal.auth.touchSession, { tokenHash: hash });
  }
  return email;
}

function cloudEmailHeader(request: Request) {
  const value = request.headers.get("x-voce-email") ?? "";
  return normalizeEmail(value);
}

async function verifiedFeatureEmail(
  ctx: any,
  request: Request,
  feature: string,
): Promise<{ email: string; entitlement: any } | { response: Response }> {
  const requestedEmail = cloudEmailHeader(request);
  if (!requestedEmail || !isValidEmail(requestedEmail)) {
    return { response: jsonResponse({ error: "Missing verified email" }, 400) };
  }

  const email = await verifiedSessionEmail(ctx, request, requestedEmail);
  if (!email) {
    return { response: jsonResponse({ error: "Email verification required" }, 401) };
  }

  const entitlement = await ctx.runQuery(internal.entitlements.check, {
    email,
    feature,
  });
  if (!entitlement.entitled) {
    if (
      feature === CLOUD_DICTATION_FEATURE &&
      entitlement.planTier === "pro" &&
      entitlement.cloudRemainingSeconds === 0
    ) {
      return {
        response: jsonResponse({ error: HOSTED_MINUTES_EXHAUSTED_MESSAGE }, 403),
      };
    }
    return { response: jsonResponse({ error: "Voce Pro cloud dictation is required." }, 403) };
  }

  return { email, entitlement };
}

function cloudErrorResponse(error: unknown) {
  // Provider errors carry messages written for users (quota, timeouts, rate
  // limits). Anything else is an internal failure whose details stay in logs.
  if (error instanceof CloudDictationProviderError) {
    return jsonResponse({ error: error.message }, error.status);
  }

  console.error("cloud dictation internal error", error);
  return jsonResponse({ error: "Cloud dictation is unavailable." }, 500);
}

function productIdFromPrice(price: Stripe.Price | string | null | undefined) {
  if (!price || typeof price === "string") {
    return undefined;
  }
  return typeof price.product === "string" ? price.product : price.product?.id;
}

function priceIdFromSubscription(subscription: Stripe.Subscription) {
  return subscription.items.data[0]?.price?.id;
}

function productIdFromSubscription(subscription: Stripe.Subscription) {
  return productIdFromPrice(subscription.items.data[0]?.price);
}

function stringId(value: unknown) {
  if (typeof value === "string") {
    return value;
  }
  if (value && typeof value === "object" && "id" in value && typeof value.id === "string") {
    return value.id;
  }
  return undefined;
}

function currentPeriodEndFromSubscription(subscription: Stripe.Subscription) {
  const currentPeriodEnd = subscription.items.data[0]?.current_period_end;
  return currentPeriodEnd ? currentPeriodEnd * 1000 : undefined;
}

async function emailForSubscription(stripe: Stripe, subscription: Stripe.Subscription) {
  if (
    subscription.customer &&
    typeof subscription.customer !== "string" &&
    !subscription.customer.deleted
  ) {
    return subscription.customer.email ?? undefined;
  }
  if (typeof subscription.customer === "string") {
    const customer = await stripe.customers.retrieve(subscription.customer);
    if (!customer.deleted) {
      return customer.email ?? undefined;
    }
  }
  return undefined;
}

function subscriptionSnapshot(subscription: Stripe.Subscription) {
  return {
    status: subscription.status as string,
    priceId: priceIdFromSubscription(subscription),
    productId: productIdFromSubscription(subscription),
    currentPeriodEnd: currentPeriodEndFromSubscription(subscription),
    cancelAtPeriodEnd: subscription.cancel_at_period_end,
  };
}

// checkout.session.completed and invoice.paid do not carry the subscription's
// current status. When Stripe is configured, read it instead of assuming
// "active"; fall back to the event data if the lookup fails.
async function liveSubscriptionSnapshot(stripe: Stripe | null, stripeSubscriptionId: string) {
  if (!stripe) {
    return null;
  }
  try {
    return subscriptionSnapshot(await stripe.subscriptions.retrieve(stripeSubscriptionId));
  } catch (error) {
    console.error("Could not retrieve Stripe subscription for webhook", {
      stripeSubscriptionId,
      error: error instanceof Error ? error.message : String(error),
    });
    return null;
  }
}

async function syncSubscription(
  ctx: any,
  stripe: Stripe | null,
  subscription: Stripe.Subscription,
  eventCreatedAt?: number,
) {
  const stripeCustomerId =
    typeof subscription.customer === "string" ? subscription.customer : subscription.customer.id;
  const email = stripe ? await emailForSubscription(stripe, subscription) : undefined;
  if (!email) {
    await ctx.runMutation(internal.stripe.upsertSubscriptionFromWebhook, {
      stripeSubscriptionId: subscription.id,
      stripeCustomerId,
      status: subscription.status,
      priceId: priceIdFromSubscription(subscription),
      productId: productIdFromSubscription(subscription),
      currentPeriodEnd: currentPeriodEndFromSubscription(subscription),
      cancelAtPeriodEnd: subscription.cancel_at_period_end,
      eventCreatedAt,
    });
    return;
  }

  await ctx.runMutation(internal.stripe.upsertCustomer, {
    stripeCustomerId,
    email,
  });
  await ctx.runMutation(internal.stripe.upsertSubscription, {
    stripeSubscriptionId: subscription.id,
    stripeCustomerId,
    email,
    status: subscription.status,
    priceId: priceIdFromSubscription(subscription),
    productId: productIdFromSubscription(subscription),
    currentPeriodEnd: currentPeriodEndFromSubscription(subscription),
    cancelAtPeriodEnd: subscription.cancel_at_period_end,
    eventCreatedAt,
  });
}

async function syncCheckoutSession(
  ctx: any,
  stripe: Stripe | null,
  session: Stripe.Checkout.Session,
  eventCreatedAt: number,
) {
  if (session.mode !== "subscription") {
    return;
  }

  const stripeSubscriptionId = stringId(session.subscription);
  const stripeCustomerId = stringId(session.customer);
  const email = session.customer_details?.email ?? session.customer_email ?? undefined;
  if (!stripeSubscriptionId || !stripeCustomerId || !email) {
    return;
  }

  await ctx.runMutation(internal.stripe.upsertCustomer, {
    stripeCustomerId,
    email,
  });

  // Delayed payment methods complete checkout with payment_status "unpaid";
  // access is granted later by invoice.paid / customer.subscription.updated.
  // "no_payment_required" covers free trials and 100% discounts.
  if (session.payment_status !== "paid" && session.payment_status !== "no_payment_required") {
    return;
  }

  const live = await liveSubscriptionSnapshot(stripe, stripeSubscriptionId);
  await ctx.runMutation(internal.stripe.upsertSubscriptionFromWebhook, {
    stripeSubscriptionId,
    stripeCustomerId,
    email,
    ...(live ?? { status: "active" }),
    eventCreatedAt,
  });
}

async function syncPaidInvoice(
  ctx: any,
  stripe: Stripe | null,
  invoice: Stripe.Invoice,
  eventCreatedAt: number,
) {
  const stripeSubscriptionId =
    stringId((invoice as any).subscription) ??
    stringId((invoice as any).parent?.subscription_details?.subscription) ??
    stringId((invoice.lines?.data[0] as any)?.parent?.subscription_item_details?.subscription);
  const stripeCustomerId = stringId(invoice.customer);
  const email = invoice.customer_email ?? undefined;
  if (!stripeSubscriptionId || !stripeCustomerId || !email) {
    return;
  }

  const line = invoice.lines?.data.find((item: any) => {
    return (
      stringId(item.parent?.subscription_item_details?.subscription) === stripeSubscriptionId ||
      item.period?.end
    );
  }) as any;

  await ctx.runMutation(internal.stripe.upsertCustomer, {
    stripeCustomerId,
    email,
  });
  const live = await liveSubscriptionSnapshot(stripe, stripeSubscriptionId);
  await ctx.runMutation(internal.stripe.upsertSubscriptionFromWebhook, {
    stripeSubscriptionId,
    stripeCustomerId,
    email,
    ...(live ?? {
      status: "active",
      priceId: stringId(line?.pricing?.price_details?.price) ?? stringId(line?.price?.id),
      productId: stringId(line?.pricing?.price_details?.product) ?? stringId(line?.price?.product),
      currentPeriodEnd: line?.period?.end ? line.period.end * 1000 : undefined,
    }),
    eventCreatedAt,
  });
}

async function createPortalSession(ctx: any, email: string) {
  const stripeSecretKey = process.env.STRIPE_SECRET_KEY;
  if (!stripeSecretKey) {
    return jsonResponse({ error: "Stripe portal is not configured" }, 500);
  }

  const customer = await ctx.runQuery(internal.stripe.customerForEmail, { email });
  if (!customer) {
    return jsonResponse({ error: "No Stripe customer found for this email" }, 404);
  }

  const stripe = new Stripe(stripeSecretKey);
  const configuration = process.env.STRIPE_PORTAL_CONFIGURATION_ID;
  const returnUrl = process.env.STRIPE_PORTAL_RETURN_URL;
  const sessionParams: Stripe.BillingPortal.SessionCreateParams = {
    customer: customer.stripeCustomerId,
    ...(configuration ? { configuration } : {}),
    ...(returnUrl ? { return_url: returnUrl } : {}),
  };
  const portalSession = await stripe.billingPortal.sessions.create(sessionParams);
  return jsonResponse({ url: portalSession.url });
}

async function createCheckoutSession(
  ctx: any,
  email: string,
  plan: string,
  billing: string,
) {
  const stripeSecretKey = process.env.STRIPE_SECRET_KEY;
  if (!stripeSecretKey) {
    return jsonResponse({ error: "Stripe checkout is not configured" }, 500);
  }

  if (!CHECKOUT_PLAN_VALUES.has(plan) || !CHECKOUT_BILLING_VALUES.has(billing)) {
    return jsonResponse({ error: "Invalid plan selection" }, 400);
  }

  const priceId = configuredPriceID(plan, billing);
  if (!priceId) {
    return jsonResponse({ error: "That plan is not configured yet" }, 500);
  }

  const successUrl = checkoutSuccessURL();
  const cancelUrl = checkoutCancelURL();
  if (!successUrl || !cancelUrl) {
    return jsonResponse({ error: "Checkout return URLs are not configured" }, 500);
  }

  const stripe = new Stripe(stripeSecretKey);
  const customer = await ctx.runQuery(internal.stripe.customerForEmail, { email });

  const session = await stripe.checkout.sessions.create({
    mode: "subscription",
    customer: customer?.stripeCustomerId,
    customer_email: customer ? undefined : email,
    line_items: [
      {
        price: priceId,
        quantity: 1,
      },
    ],
    allow_promotion_codes: true,
    success_url: successUrl,
    cancel_url: cancelUrl,
    metadata: {
      vocePlan: plan,
      voceBilling: billing,
    },
  });

  return jsonResponse({ url: session.url });
}


http.route({
  path: "/auth/start",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const body = (await request.json()) as { email?: string };
    if (!body.email) {
      return jsonResponse({ error: "Missing email" }, 400);
    }

    const email = normalizeEmail(body.email);
    if (!isValidEmail(email)) {
      return jsonResponse({ error: "Invalid email" }, 400);
    }

    const limited = await rateLimited(
      ctx,
      [{ key: `auth-start:email:${email}`, limit: AUTH_START_LIMIT_PER_EMAIL }],
      {
        error: "Too many code requests. Try again later.",
        code: "too_many_code_requests",
      },
    );
    if (limited) {
      return limited;
    }

    const code = randomDigits(6);
    const hash = await codeHash(email, code);
    await ctx.runMutation(internal.auth.createEmailCode, {
      email,
      codeHash: hash,
      expiresAt: Date.now() + EMAIL_CODE_TTL_MS,
    });
    try {
      await sendAccessCodeEmail(email, code);
    } catch (error) {
      console.error("Could not send Voce access code", {
        emailDomain: email.split("@")[1] ?? "",
        error: error instanceof Error ? error.message : String(error),
      });
      return jsonResponse({ error: "Could not send access code" }, 502);
    }

    return jsonResponse({ sent: true, email });
  }),
});

http.route({
  path: "/auth/verify",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const body = (await request.json()) as { email?: string; code?: string };
    if (!body.email || !body.code) {
      return jsonResponse({ error: "Missing email or code" }, 400);
    }

    const email = normalizeEmail(body.email);
    if (!isValidEmail(email)) {
      return jsonResponse({ error: "Invalid email" }, 400);
    }

    const code = body.code.trim();
    if (!/^\d{6}$/.test(code)) {
      return jsonResponse({ error: "Invalid code" }, 400);
    }

    const hash = await codeHash(email, code);
    const verification = await ctx.runMutation(internal.auth.consumeEmailCode, {
      email,
      codeHash: hash,
    });
    if (!verification.ok) {
      if (verification.locked) {
        return jsonResponse(
          {
            error: "Too many incorrect codes. Request a new code.",
            code: "too_many_incorrect_codes",
          },
          429,
        );
      }
      return jsonResponse({ error: "Invalid or expired code" }, 401);
    }

    const sessionToken = randomToken();
    const session = await ctx.runMutation(internal.auth.createSession, {
      email,
      tokenHash: await tokenHash(sessionToken),
      expiresAt: Date.now() + SESSION_TTL_MS,
    });

    if (session.isFirstSession) {
      const entitlement = await ctx.runQuery(internal.entitlements.check, { email });
      try {
        await sendSignupEmail({
          email,
          source: entitlement.source ?? "unknown",
          planTier: entitlement.planTier ?? "unknown",
        });
      } catch (error) {
        console.error("Could not send Voce signup email", {
          emailDomain: email.split("@")[1] ?? "",
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }

    return jsonResponse({ email, sessionToken, expiresAt: Date.now() + SESSION_TTL_MS });
  }),
});

// Revokes the session identified by x-voce-session-token. Idempotent: an
// unknown or already-revoked token still returns success.
http.route({
  path: "/auth/logout",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const token = request.headers.get("x-voce-session-token")?.trim();
    if (!token) {
      return jsonResponse({ error: "Missing session token" }, 400);
    }

    await ctx.runMutation(internal.auth.revokeSession, { tokenHash: await tokenHash(token) });
    return jsonResponse({ loggedOut: true });
  }),
});

http.route({
  path: "/entitlements/check",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const expectedSecret = process.env.VOCE_ENTITLEMENT_API_SECRET;
    if (expectedSecret && bearerToken(request) !== expectedSecret) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const body = (await request.json()) as { email?: string; feature?: string };
    if (!body.email) {
      return jsonResponse({ error: "Missing email" }, 400);
    }
    const email = await verifiedSessionEmail(ctx, request, body.email);
    if (!email) {
      return jsonResponse({ error: "Email verification required" }, 401);
    }

    const entitlement = await ctx.runQuery(internal.entitlements.check, {
      email,
      feature: body.feature ?? DEFAULT_FEATURE,
    });
    return jsonResponse(entitlement);
  }),
});

http.route({
  path: "/entitlements/record-usage",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const expectedSecret = process.env.VOCE_ENTITLEMENT_API_SECRET;
    if (expectedSecret && bearerToken(request) !== expectedSecret) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const body = (await request.json()) as { email?: string; feature?: string; seconds?: number };
    if (!body.email) {
      return jsonResponse({ error: "Missing email" }, 400);
    }
    const email = await verifiedSessionEmail(ctx, request, body.email);
    if (!email) {
      return jsonResponse({ error: "Email verification required" }, 401);
    }
    if (typeof body.seconds !== "number" || !Number.isFinite(body.seconds)) {
      return jsonResponse({ error: "Missing usage seconds" }, 400);
    }

    const entitlement = await ctx.runMutation(internal.entitlements.recordUsage, {
      email,
      feature: body.feature ?? DEFAULT_FEATURE,
      seconds: body.seconds,
    });
    return jsonResponse(entitlement);
  }),
});

http.route({
  path: "/admin/usage-audit",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const body = (await request.json()) as {
      email?: string;
      months?: number;
      costPerHostedMinuteUSD?: number;
    };
    // Admin bearer access uses its own secret, never the app's shared
    // entitlement secret, and is disabled when VOCE_ADMIN_API_SECRET is unset.
    const expectedSecret = process.env.VOCE_ADMIN_API_SECRET;
    const token = bearerToken(request);

    if (token) {
      if (!expectedSecret || !secretsMatch(token, expectedSecret)) {
        return jsonResponse({ error: "Unauthorized" }, 401);
      }
    } else {
      if (!body.email) {
        return jsonResponse({ error: "Missing email" }, 400);
      }
      const email = await verifiedSessionEmail(ctx, request, body.email);
      if (!email) {
        return jsonResponse({ error: "Email verification required" }, 401);
      }
      if (!isAdminEmail(email)) {
        return jsonResponse({ error: "Admin access required" }, 403);
      }
    }

    const report = await ctx.runQuery(internal.entitlements.usageAudit, {
      months: typeof body.months === "number" && Number.isFinite(body.months)
        ? body.months
        : undefined,
      costPerHostedMinuteUSD:
        typeof body.costPerHostedMinuteUSD === "number" && Number.isFinite(body.costPerHostedMinuteUSD)
          ? body.costPerHostedMinuteUSD
          : undefined,
    });
    return jsonResponse(report);
  }),
});

http.route({
  path: "/cloud-dictation/preflight",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const verification = await verifiedFeatureEmail(ctx, request, CLOUD_DICTATION_FEATURE);
    if ("response" in verification) {
      return verification.response;
    }

    try {
      const body = (await request.json()) as { localeIdentifier?: string };
      const localeIdentifier = (body.localeIdentifier ?? "").trim() || "en-US";
      await runCloudDictationPreflight(localeIdentifier);
      return jsonResponse({ ready: true });
    } catch (error) {
      console.error("cloud dictation preflight failed", {
        emailDomain: verification.email.split("@")[1] ?? "",
        error: error instanceof Error ? error.message : String(error),
      });
      return cloudErrorResponse(error);
    }
  }),
});

http.route({
  path: "/cloud-dictation/transcribe",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const verification = await verifiedFeatureEmail(ctx, request, CLOUD_DICTATION_FEATURE);
    if ("response" in verification) {
      return verification.response;
    }

    const declaredLength = declaredContentLength(request);
    if (
      declaredLength !== null &&
      declaredLength > MAX_TRANSCRIBE_AUDIO_BYTES + MAX_TRANSCRIBE_FORM_OVERHEAD_BYTES
    ) {
      return payloadTooLarge("Audio file is too large for cloud transcription.");
    }

    try {
      const form = await request.formData();
      const localeIdentifier = String(form.get("localeIdentifier") ?? "").trim() || "en-US";
      const hintsField = String(form.get("hints") ?? "[]");
      let rawHints: unknown;
      try {
        rawHints = JSON.parse(hintsField);
      } catch {
        return jsonResponse({ error: "Invalid hints" }, 400);
      }
      const hints = sanitizedHints(rawHints);

      const fileValue = form.get("file");
      if (!fileValue || typeof (fileValue as Blob).arrayBuffer !== "function") {
        return jsonResponse({ error: "Missing audio file" }, 400);
      }

      const blob = fileValue as Blob & { name?: string };
      if (blob.size > MAX_TRANSCRIBE_AUDIO_BYTES) {
        return payloadTooLarge("Audio file is too large for cloud transcription.");
      }
      const filename = (blob.name ?? "voce-audio.wav").trim() || "voce-audio.wav";
      const result = await transcribeWithCloudProvider({
        localeIdentifier,
        hints,
        audioBlob: blob,
        filename,
      });

      return jsonResponse(result);
    } catch (error) {
      console.error("cloud dictation transcription failed", {
        emailDomain: verification.email.split("@")[1] ?? "",
        error: error instanceof Error ? error.message : String(error),
      });
      return cloudErrorResponse(error);
    }
  }),
});

http.route({
  path: "/cloud-dictation/realtime-session",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const verification = await verifiedFeatureEmail(ctx, request, CLOUD_DICTATION_FEATURE);
    if ("response" in verification) {
      return verification.response;
    }

    // A client secret lets the app open a realtime session, so do not mint one
    // when only a few hosted seconds remain.
    const cloudRemainingSeconds = verification.entitlement.cloudRemainingSeconds;
    if (
      typeof cloudRemainingSeconds === "number" &&
      cloudRemainingSeconds < MIN_HOSTED_SECONDS_FOR_REALTIME_SESSION
    ) {
      return jsonResponse({ error: HOSTED_MINUTES_EXHAUSTED_MESSAGE }, 403);
    }

    try {
      const parsed = await readLimitedJSON<{
        localeIdentifier?: string;
        hints?: string[];
        model?: string;
      }>(request, MAX_JSON_BODY_BYTES);
      if ("response" in parsed) {
        return parsed.response;
      }
      const body = parsed.body ?? {};
      const localeIdentifier = (body.localeIdentifier ?? "").trim() || "en-US";
      const hints = sanitizedHints(body.hints);
      const model = typeof body.model === "string" ? body.model.trim() || undefined : undefined;

      const result = await createRealtimeTranscriptionSession({
        localeIdentifier,
        hints,
        model,
      });

      return jsonResponse(result);
    } catch (error) {
      console.error("cloud dictation realtime session failed", {
        emailDomain: verification.email.split("@")[1] ?? "",
        error: error instanceof Error ? error.message : String(error),
      });
      return cloudErrorResponse(error);
    }
  }),
});

http.route({
  path: "/cloud-dictation/refine",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const verification = await verifiedFeatureEmail(ctx, request, CLOUD_DICTATION_FEATURE);
    if ("response" in verification) {
      return verification.response;
    }

    try {
      const parsed = await readLimitedJSON<{
        transcript?: string;
        localeIdentifier?: string;
        dictionary?: Array<{
          term?: string;
          preferred?: string;
          scope?: "global" | "app";
          bundleIdentifier?: string;
        }>;
        profile?: {
          tone?: string;
          structureMode?: string;
          fillerPolicy?: string;
          commandPolicy?: string;
        };
        appContext?: {
          bundleIdentifier?: string;
          appName?: string;
          inputFieldDescription?: string | null;
          isRemoteDesktop?: boolean;
          isIDE?: boolean;
        } | null;
      }>(request, MAX_JSON_BODY_BYTES);
      if ("response" in parsed) {
        return parsed.response;
      }
      const body = parsed.body ?? {};

      const transcript = (typeof body.transcript === "string" ? body.transcript : "").trim();
      if (!transcript) {
        return jsonResponse({ error: "Missing transcript" }, 400);
      }
      if (transcript.length > MAX_REFINE_TRANSCRIPT_CHARS) {
        return payloadTooLarge("Transcript is too long for cloud refinement.");
      }

      const localeIdentifier = (body.localeIdentifier ?? "").trim() || "en-US";
      const dictionary = Array.isArray(body.dictionary)
        ? body.dictionary
            .filter(
              (entry): entry is {
                term: string;
                preferred: string;
                scope: "global" | "app";
                bundleIdentifier?: string;
              } =>
                typeof entry?.term === "string" &&
                typeof entry?.preferred === "string" &&
                (entry.scope === "global" || entry.scope === "app"),
            )
            .map((entry) => ({
              term: entry.term.trim(),
              preferred: entry.preferred.trim(),
              scope: entry.scope,
              bundleIdentifier: entry.bundleIdentifier?.trim() || undefined,
            }))
            .filter(
              (entry) =>
                entry.term.length > 0 &&
                entry.preferred.length > 0 &&
                entry.term.length <= MAX_DICTIONARY_FIELD_CHARS &&
                entry.preferred.length <= MAX_DICTIONARY_FIELD_CHARS,
            )
            .slice(0, MAX_DICTIONARY_ENTRIES)
        : [];

      const profile = {
        tone: body.profile?.tone ?? "natural",
        structureMode: body.profile?.structureMode ?? "natural",
        fillerPolicy: body.profile?.fillerPolicy ?? "balanced",
        commandPolicy: body.profile?.commandPolicy ?? "passthrough",
      };

      const appContext =
        body.appContext &&
        typeof body.appContext.bundleIdentifier === "string" &&
        typeof body.appContext.appName === "string"
          ? {
              bundleIdentifier: body.appContext.bundleIdentifier,
              appName: body.appContext.appName,
              inputFieldDescription: body.appContext.inputFieldDescription ?? null,
              isRemoteDesktop: body.appContext.isRemoteDesktop === true,
              isIDE: body.appContext.isIDE === true,
            }
          : null;

      const result = await refineWithCloudProvider({
        transcript,
        localeIdentifier,
        dictionary,
        profile,
        appContext,
      });

      return jsonResponse(result);
    } catch (error) {
      console.error("cloud dictation refinement failed", {
        emailDomain: verification.email.split("@")[1] ?? "",
        error: error instanceof Error ? error.message : String(error),
      });
      return cloudErrorResponse(error);
    }
  }),
});

http.route({
  path: "/stripe/checkout",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const expectedSecret = process.env.VOCE_ENTITLEMENT_API_SECRET;
    if (expectedSecret && bearerToken(request) !== expectedSecret) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const body = (await request.json()) as {
      email?: string;
      plan?: string;
      billing?: string;
    };
    if (!body.email || !body.plan || !body.billing) {
      return jsonResponse({ error: "Missing checkout parameters" }, 400);
    }

    const email = await verifiedSessionEmail(ctx, request, body.email);
    if (!email) {
      return jsonResponse({ error: "Email verification required" }, 401);
    }

    return await createCheckoutSession(ctx, email, body.plan, body.billing);
  }),
});

http.route({
  path: "/stripe/webhook",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET;
    if (!webhookSecret) {
      return jsonResponse({ error: "Stripe is not configured" }, 500);
    }

    const signature = request.headers.get("stripe-signature");
    if (!signature) {
      return jsonResponse({ error: "Missing Stripe signature" }, 400);
    }

    const payload = await request.text();
    let event: Stripe.Event;
    try {
      event = await Stripe.webhooks.constructEventAsync(payload, signature, webhookSecret);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Invalid Stripe webhook";
      return jsonResponse({ error: message }, 400);
    }

    const stripeSecretKey = process.env.STRIPE_SECRET_KEY;
    const stripe = stripeSecretKey ? new Stripe(stripeSecretKey) : null;
    const eventCreatedAt = event.created * 1000;

    switch (event.type) {
      case "checkout.session.completed":
        await syncCheckoutSession(
          ctx,
          stripe,
          event.data.object as Stripe.Checkout.Session,
          eventCreatedAt,
        );
        break;
      case "invoice.paid":
      case "invoice.payment_succeeded":
        await syncPaidInvoice(ctx, stripe, event.data.object as Stripe.Invoice, eventCreatedAt);
        break;
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted":
        await syncSubscription(
          ctx,
          null,
          event.data.object as Stripe.Subscription,
          eventCreatedAt,
        );
        break;
      default:
        break;
    }

    return jsonResponse({ received: true });
  }),
});

http.route({
  path: "/stripe/portal",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const expectedSecret = process.env.VOCE_ENTITLEMENT_API_SECRET;
    if (expectedSecret && bearerToken(request) !== expectedSecret) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const body = (await request.json()) as { email?: string };
    if (!body.email) {
      return jsonResponse({ error: "Missing email" }, 400);
    }
    const email = await verifiedSessionEmail(ctx, request, body.email);
    if (!email) {
      return jsonResponse({ error: "Email verification required" }, 401);
    }

    return await createPortalSession(ctx, email);
  }),
});

http.route({
  path: "/support/request",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    try {
      const body = (await request.json()) as {
        category?: string;
        email?: string;
        subject?: string;
        message?: string;
        appVersion?: string;
        buildNumber?: string;
        macOSVersion?: string;
        includeDiagnostics?: boolean;
        diagnostics?: string;
      };

      const category = (body.category ?? "support").trim().toLowerCase();
      const email = normalizeEmail(body.email ?? "");
      const subject = (body.subject ?? "").trim();
      const message = normalizedMultilineText(body.message ?? "");
      const appVersion = (body.appVersion ?? "").trim();
      const buildNumber = (body.buildNumber ?? "").trim();
      const macOSVersion = (body.macOSVersion ?? "").trim();
      const includeDiagnostics = body.includeDiagnostics === true;
      const fullDiagnostics = normalizedMultilineText(
        typeof body.diagnostics === "string" ? body.diagnostics : "",
      );
      const diagnostics =
        fullDiagnostics.length > MAX_SUPPORT_DIAGNOSTICS_CHARS
          ? `${fullDiagnostics.slice(0, MAX_SUPPORT_DIAGNOSTICS_CHARS)}\n[diagnostics truncated]`
          : fullDiagnostics;

      if (!["support", "bug", "feature"].includes(category)) {
        return jsonResponse({ error: "Invalid support category" }, 400);
      }
      if (!isValidEmail(email)) {
        return jsonResponse({ error: "Invalid email" }, 400);
      }
      if (subject.length === 0 || subject.length > 140) {
        return jsonResponse({ error: "Subject is required and must be 140 characters or fewer" }, 400);
      }
      if (message.length === 0 || message.length > 5000) {
        return jsonResponse({ error: "Message is required and must be 5000 characters or fewer" }, 400);
      }
      if (appVersion.length === 0 || buildNumber.length === 0 || macOSVersion.length === 0) {
        return jsonResponse({ error: "Missing app metadata" }, 400);
      }

      const limited = await rateLimited(
        ctx,
        [{ key: `support:email:${email}`, limit: SUPPORT_LIMIT_PER_EMAIL }],
        {
          error: "Too many support requests. Please try again later.",
          code: "too_many_support_requests",
        },
      );
      if (limited) {
        return limited;
      }

      await sendSupportEmail({
        category,
        email,
        subject,
        message,
        appVersion,
        buildNumber,
        macOSVersion,
        includeDiagnostics,
        diagnostics: includeDiagnostics && diagnostics.length > 0 ? diagnostics : undefined,
      });

      return jsonResponse({ sent: true });
    } catch (error) {
      console.error("support request failed", error);
      return jsonResponse({ error: "Could not send support request" }, 500);
    }
  }),
});

export default http;
