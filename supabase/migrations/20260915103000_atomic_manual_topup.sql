-- Same class of bug as the lead handoff: the owner's manual "record a
-- top-up" action in Setup did a client-computed balance increment
-- (patchPartner) followed by a separate wallet_transactions insert, with no
-- error checking between them and no atomicity. Two near-simultaneous
-- top-ups could both read the same stale balance and lose one increment,
-- and a failure partway through could credit the ledger without the
-- balance or vice versa.

create or replace function public.record_partner_topup(p_partner_id uuid, p_amount_cents integer, p_note text default null)
returns table (new_balance_cents integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_partner public.partners;
  v_new_balance integer;
begin
  if auth.uid() is null then
    raise exception 'Must be signed in.';
  end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'Amount must be greater than zero.';
  end if;

  select * into v_partner from public.partners where id = p_partner_id and owner = auth.uid();
  if not found then
    raise exception 'Partner not found.';
  end if;

  if v_partner.balance_cents = 0 and p_amount_cents < 7500 then
    raise exception 'First top-up needs to be at least $75.';
  end if;

  update public.partners
  set balance_cents = balance_cents + p_amount_cents
  where id = p_partner_id
  returning balance_cents into v_new_balance;

  insert into public.wallet_transactions (owner, partner_id, amount_cents, kind, note)
  values (auth.uid(), p_partner_id, p_amount_cents, 'topup', p_note);

  return query select v_new_balance;
end;
$$;

revoke all on function public.record_partner_topup(uuid, integer, text) from public;
grant execute on function public.record_partner_topup(uuid, integer, text) to authenticated;
