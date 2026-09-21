-- Same class of bug as record_partner_topup / send_lead_to_partner: the
-- Stripe webhook credited a partner's wallet by reading balance_cents in
-- JS and writing back balance + cents, which can lose an update if it
-- races another balance change (another topup, a lead charge, or a
-- redelivered webhook event). It also relied only on a select-before-insert
-- in application code for idempotency, which is itself a race under
-- concurrent delivery of the same event.
--
-- A unique index gives idempotency a real guarantee at the DB level, and
-- this function does the idempotent insert and the atomic balance
-- increment in one statement/transaction. Runs as service_role only (the
-- webhook has no authenticated user — no auth.uid() to check against).

create unique index wallet_tx_stripe_payment_intent_idx
  on public.wallet_transactions (stripe_payment_intent_id)
  where stripe_payment_intent_id is not null;

create or replace function public.credit_partner_wallet_from_stripe(
  p_partner_id uuid, p_amount_cents integer, p_payment_intent_id text
)
returns table (new_balance_cents integer, credited boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_new_balance integer;
  v_inserted boolean;
begin
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'Amount must be greater than zero.';
  end if;

  select owner into v_owner from public.partners where id = p_partner_id;
  if not found then
    raise exception 'Partner not found.';
  end if;

  insert into public.wallet_transactions (owner, partner_id, amount_cents, kind, stripe_payment_intent_id)
  values (v_owner, p_partner_id, p_amount_cents, 'topup', p_payment_intent_id)
  on conflict (stripe_payment_intent_id) where stripe_payment_intent_id is not null do nothing;

  v_inserted := found;

  if not v_inserted then
    -- already credited by an earlier delivery of the same Stripe event
    select balance_cents into v_new_balance from public.partners where id = p_partner_id;
    return query select v_new_balance, false;
    return;
  end if;

  update public.partners
  set balance_cents = balance_cents + p_amount_cents
  where id = p_partner_id
  returning balance_cents into v_new_balance;

  return query select v_new_balance, true;
end;
$$;

revoke all on function public.credit_partner_wallet_from_stripe(uuid, integer, text) from public;
grant execute on function public.credit_partner_wallet_from_stripe(uuid, integer, text) to service_role;
