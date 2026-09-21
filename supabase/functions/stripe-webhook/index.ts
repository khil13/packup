// Credits a partner's wallet when their top-up Checkout Session completes.
// verify_jwt is off — Stripe doesn't send a Supabase JWT. Authenticity comes
// from verifying the Stripe-Signature header against STRIPE_WEBHOOK_SECRET,
// not from anything Supabase-level.
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2024-12-18.acacia",
});
const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;
const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve(async (req) => {
  const signature = req.headers.get("stripe-signature");
  const body = await req.text();

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, signature!, webhookSecret);
  } catch (e) {
    console.error("Signature verification failed", e);
    return new Response("Invalid signature", { status: 400 });
  }

  if (event.type === "checkout.session.completed") {
    const session = event.data.object as Stripe.Checkout.Session;
    if (session.metadata?.kind === "wallet_topup" && session.payment_status === "paid") {
      const partnerId = session.metadata.partner_id;
      const cents = session.amount_total ?? 0;
      const paymentIntentId = typeof session.payment_intent === "string"
        ? session.payment_intent
        : session.payment_intent?.id ?? session.id; // fall back to session id if no PI

      // credit_partner_wallet_from_stripe does the idempotency check (a
      // unique index on stripe_payment_intent_id, not a racy select-then-
      // insert) and the balance increment atomically in one statement, so a
      // redelivered webhook or a concurrent lead charge can't double-credit
      // or lose an update.
      const { error: creditError } = await supabase.rpc("credit_partner_wallet_from_stripe", {
        p_partner_id: partnerId,
        p_amount_cents: cents,
        p_payment_intent_id: paymentIntentId,
      });
      if (creditError) console.error("credit_partner_wallet_from_stripe failed", creditError);
    }
  }

  return new Response(JSON.stringify({ received: true }), {
    headers: { "Content-Type": "application/json" },
  });
});
