import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";
import { api, internal } from "./_generated/api";
import Stripe from "stripe";

const http = httpRouter();

const DEFAULT_FEATURE = "voce_app_access";

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function bearerToken(request: Request) {
  const authorization = request.headers.get("authorization") ?? "";
  const prefix = "Bearer ";
  return authorization.startsWith(prefix) ? authorization.slice(prefix.length) : null;
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

async function syncSubscription(ctx: any, stripe: Stripe | null, subscription: Stripe.Subscription) {
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
  });
}

async function syncCheckoutSession(ctx: any, session: Stripe.Checkout.Session) {
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
  await ctx.runMutation(internal.stripe.upsertSubscriptionFromWebhook, {
    stripeSubscriptionId,
    stripeCustomerId,
    email,
    status: "active",
  });
}

async function syncPaidInvoice(ctx: any, invoice: Stripe.Invoice) {
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
  await ctx.runMutation(internal.stripe.upsertSubscriptionFromWebhook, {
    stripeSubscriptionId,
    stripeCustomerId,
    email,
    status: "active",
    priceId: stringId(line?.pricing?.price_details?.price) ?? stringId(line?.price?.id),
    productId: stringId(line?.pricing?.price_details?.product) ?? stringId(line?.price?.product),
    currentPeriodEnd: line?.period?.end ? line.period.end * 1000 : undefined,
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

    const entitlement = await ctx.runQuery(api.entitlements.check, {
      email: body.email,
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
    if (typeof body.seconds !== "number" || !Number.isFinite(body.seconds)) {
      return jsonResponse({ error: "Missing usage seconds" }, 400);
    }

    const entitlement = await ctx.runMutation(api.entitlements.recordUsage, {
      email: body.email,
      feature: body.feature ?? DEFAULT_FEATURE,
      seconds: body.seconds,
    });
    return jsonResponse(entitlement);
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

    switch (event.type) {
      case "checkout.session.completed":
        await syncCheckoutSession(ctx, event.data.object as Stripe.Checkout.Session);
        break;
      case "invoice.paid":
      case "invoice.payment_succeeded":
        await syncPaidInvoice(ctx, event.data.object as Stripe.Invoice);
        break;
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted":
        await syncSubscription(ctx, null, event.data.object as Stripe.Subscription);
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

    return await createPortalSession(ctx, body.email);
  }),
});

export default http;
