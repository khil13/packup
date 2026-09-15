// Creates a Stripe Checkout Session so a partner can top up their PackUp
// lead wallet by card. Requires a signed-in partner session (verify_jwt is
// on) — the partner is derived from the caller's own auth.uid() via
// partner_user_id, never from a client-supplied partner_id, so one partner
// can never open a checkout session (or see the balance) for another.
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2024-12-18.acacia",
});
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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
    const authHeader = req.headers.get("Authorization") ?? "";
    const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !userData?.user) return json({ error: "Sign in required." }, 401);

    const { amount } = await req.json();
    const cents = Math.round(Number(amount) * 100);
    if (!Number.isFinite(cents) || cents <= 0) return json({ error: "Invalid amount" }, 400);

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: partner, error } = await supabase
      .from("partners")
      .select("id, name, balance_cents")
      .eq("partner_user_id", userData.user.id)
      .single();
    if (error || !partner) return json({ error: "No partner account is linked to this login." }, 404);

    if (partner.balance_cents === 0 && cents < 7500) {
      return json({ error: "First top-up must be at least $75." }, 400);
    }

    const origin = req.headers.get("origin") || "";
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
      success_url: `${origin}/partner-topup.html?status=success`,
      cancel_url: `${origin}/partner-topup.html?status=cancelled`,
    });

    return json({ url: session.url });
  } catch (e) {
    console.error(e);
    return json({ error: e instanceof Error ? e.message : "Unexpected error" }, 500);
  }
});
