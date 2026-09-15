-- Send a lead to a partner atomically. Previously the owner's browser did
-- this as three separate writes (decrement partner balance using a
-- client-cached number, insert a wallet_transactions charge row, update the
-- lead) with no error checking between them. That let two near-simultaneous
-- handoffs to the same partner both compute the same stale balance and
-- silently lose one deduction (wallet_transactions and partners.balance_cents
-- drift apart), and let any single step's failure leave the others applied.
--
-- This function does the price lookup, the balance check + decrement, the
-- wallet transaction, and the lead update in one transaction. The balance
-- decrement is itself race-safe: `balance_cents >= v_price_cents` is
-- evaluated by the same UPDATE that performs the decrement, so a concurrent
-- handoff either sees the already-reduced balance or is blocked by the row
-- lock, never both computing from the same stale value.

create or replace function public.send_lead_to_partner(p_lead_id uuid, p_partner_id uuid)
returns table (charged_cents integer, new_balance_cents integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lead public.leads;
  v_partner public.partners;
  v_settings public.company_settings;
  v_dollars numeric;
  v_price_cents integer;
  v_new_balance integer;
begin
  if auth.uid() is null then
    raise exception 'Must be signed in.';
  end if;

  select * into v_lead from public.leads where id = p_lead_id and owner = auth.uid();
  if not found then
    raise exception 'Lead not found.';
  end if;

  select * into v_partner from public.partners where id = p_partner_id and owner = auth.uid();
  if not found then
    raise exception 'Partner not found.';
  end if;

  select * into v_settings from public.company_settings where owner = auth.uid();

  v_dollars := case v_lead.home_size
    when 'studio' then coalesce(v_settings.lead_price_small, 12)
    when 'br1'    then coalesce(v_settings.lead_price_small, 12)
    when 'br2'    then coalesce(v_settings.lead_price_medium, 15)
    when 'br3'    then coalesce(v_settings.lead_price_large, 19)
    when 'br4'    then coalesce(v_settings.lead_price_xlarge, 24)
    else               coalesce(v_settings.lead_price_small, 12)
  end;

  if v_lead.move_type = 'long' or coalesce(v_lead.miles, 0) > 30 then
    v_dollars := v_dollars + coalesce(v_settings.lead_price_distance_surcharge, 6);
  end if;

  v_price_cents := round(v_dollars * 100);

  update public.partners
  set balance_cents = balance_cents - v_price_cents
  where id = p_partner_id and balance_cents >= v_price_cents
  returning balance_cents into v_new_balance;

  if not found then
    raise exception 'Insufficient balance for %.', v_partner.name;
  end if;

  insert into public.wallet_transactions (owner, partner_id, amount_cents, kind, lead_id)
  values (auth.uid(), p_partner_id, -v_price_cents, 'lead_charge', p_lead_id);

  update public.leads
  set partner_id = p_partner_id, sent_at = now(), charged_cents = v_price_cents
  where id = p_lead_id;

  return query select v_price_cents, v_new_balance;
end;
$$;

revoke all on function public.send_lead_to_partner(uuid, uuid) from public;
grant execute on function public.send_lead_to_partner(uuid, uuid) to authenticated;
