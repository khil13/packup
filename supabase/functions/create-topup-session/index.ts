// Creates a Stripe Checkout Session so a partner can top up their PackUp
// lead wallet by card. Called anonymously (partners don't have a login) —
// verify_jwt is off for this function; the partner_id + server-side lookup
// is what scopes the request, not a Supabase session.
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2024-12-18.acacia",
});
const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });

  try {
    const { partner_id, amount, origin: bodyOrigin } = await req.json();
    if (!partner_id || !amount) return json({ error: "partner_id and amount are required" }, 400);

    const cents = Math.round(Number(amount) * 100);
    if (!Number.isFinite(cents) || cents <= 0) return json({ error: "Invalid amount" }, 400);

    const { data: partner, error } = await supabase
      .from("partners")
      .select("id, name, balance_cents")
      .eq("id", partner_id)
      .single();
    if (error || !partner) return json({ error: "Partner not found" }, 404);

    if (partner.balance_cents === 0 && cents < 7500) {
      return json({ error: "First top-up must be at least $75." }, 400);
    }

    const origin = bodyOrigin || req.headers.get("origin") || "";
    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      payment_method_types: ["card"],
      line_items: [
        {
          price_data: {
            currency: "usd",
            product_data: { name: `PackUp lead wallet top-up — ${partner.name}` },
            unit_amount: cents,
          },
          quantity: 1,
        },
      ],
      metadata: { partner_id: partner.id, kind: "wallet_topup" },
      success_url: `${origin}/partner-topup.html?partner=${partner.id}&status=success`,
      cancel_url: `${origin}/partner-topup.html?partner=${partner.id}&status=cancelled`,
    });

    return json({ url: session.url });
  } catch (e) {
    console.error(e);
    return json({ error: e instanceof Error ? e.message : "Unexpected error" }, 500);
  }
});
