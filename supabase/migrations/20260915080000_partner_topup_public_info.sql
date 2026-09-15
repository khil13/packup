-- Let an anonymous partner (no login) look up their own name + balance by
-- their partner id, so the top-up page can show them what they're funding.
-- No other partner fields are exposed (no email/phone/license/other partners).

create or replace function public.get_partner_topup_info(p_partner_id uuid)
returns table (name text, balance_cents integer)
language sql
security definer
set search_path = ''
stable
as $$
  select name, balance_cents from public.partners where id = p_partner_id;
$$;

revoke all on function public.get_partner_topup_info(uuid) from public;
grant execute on function public.get_partner_topup_info(uuid) to anon, authenticated;
