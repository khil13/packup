-- Reassigning a lead to a different partner used to just re-run the same
-- charge logic against the new partner, leaving the original partner paying
-- for a lead they no longer have — even though they already saw the
-- contact info and could follow up on their own without PackUp knowing.
-- Business call: refund the original partner half of what they were
-- charged (they got the lead info, just not exclusivity going forward),
-- then charge the new partner in full — both in the same transaction as
-- the rest of the handoff, so this can't drift out of sync either.

drop function if exists public.send_lead_to_partner(uuid, uuid);

create function public.send_lead_to_partner(p_lead_id uuid, p_partner_id uuid)
returns table (charged_cents integer, new_balance_cents integer, refunded_partner_id uuid, refunded_partner_name text, refunded_cents integer)
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
  v_prev_partner public.partners;
  v_refund_cents integer;
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

  -- reassignment: refund the previous partner half of what they paid
  if v_lead.partner_id is not null and v_lead.partner_id <> p_partner_id and coalesce(v_lead.charged_cents, 0) > 0 then
    select * into v_prev_partner from public.partners where id = v_lead.partner_id;
    if found then
      v_refund_cents := round(v_lead.charged_cents::numeric / 2);
      update public.partners
      set balance_cents = balance_cents + v_refund_cents
      where id = v_prev_partner.id;

      insert into public.wallet_transactions (owner, partner_id, amount_cents, kind, lead_id, note)
      values (auth.uid(), v_prev_partner.id, v_refund_cents, 'adjustment', p_lead_id, 'Partial refund — lead reassigned to another partner');
    end if;
  end if;

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

  return query select v_price_cents, v_new_balance, v_prev_partner.id, v_prev_partner.name, v_refund_cents;
end;
$$;

revoke all on function public.send_lead_to_partner(uuid, uuid) from public;
grant execute on function public.send_lead_to_partner(uuid, uuid) to authenticated;
