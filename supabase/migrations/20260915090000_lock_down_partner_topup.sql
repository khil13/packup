-- Lock down the top-up flow: only the authenticated, owning partner may look
-- up their own wallet info. Previously get_partner_topup_info(p_partner_id)
-- was security definer and granted to anon, keyed off an unauthenticated
-- partner_id passed in the URL — anyone holding (or guessing) a partner's
-- UUID could see their name and balance. Replace it with a no-arg version
-- that derives the partner from auth.uid(), granted to authenticated only.

drop function if exists public.get_partner_topup_info(uuid);

create function public.get_partner_topup_info()
returns table (id uuid, name text, balance_cents integer)
language sql
security definer
set search_path = ''
stable
as $$
  select id, name, balance_cents from public.partners where partner_user_id = auth.uid();
$$;

revoke all on function public.get_partner_topup_info() from public;
grant execute on function public.get_partner_topup_info() to authenticated;
