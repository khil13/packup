-- Let partners create their own login and see only their own data.

alter table public.partners add column partner_user_id uuid references auth.users(id) on delete set null;
create unique index partners_partner_user_id_idx on public.partners (partner_user_id) where partner_user_id is not null;

-- Link the calling (authenticated) user to a partner row, but only once —
-- never lets someone re-point an already-claimed partner to a new account.
create or replace function public.claim_partner_account(p_partner_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_updated int;
begin
  if auth.uid() is null then
    raise exception 'Must be signed in to claim a partner account.';
  end if;

  update public.partners
  set partner_user_id = auth.uid()
  where id = p_partner_id and partner_user_id is null;

  get diagnostics v_updated = row_count;
  return v_updated > 0;
end;
$$;

revoke all on function public.claim_partner_account(uuid) from public;
grant execute on function public.claim_partner_account(uuid) to authenticated;

-- a partner can see their own partner row once claimed (never anyone else's)
create policy "partners can view own row" on public.partners
  for select to authenticated
  using (partner_user_id = auth.uid());

-- a partner can see leads that were sent to them, nothing else
create policy "partners can view their own leads" on public.leads
  for select to authenticated
  using (partner_id in (select id from public.partners where partner_user_id = auth.uid()));

-- a partner can see their own wallet history, nothing else
create policy "partners can view their own wallet transactions" on public.wallet_transactions
  for select to authenticated
  using (partner_id in (select id from public.partners where partner_user_id = auth.uid()));

-- business-owner signups (index.html) still get a company_settings row;
-- partner signups (partner-portal.html, tagged via signup metadata) don't
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(new.raw_user_meta_data->>'signup_role', 'owner') = 'owner' then
    insert into public.company_settings (owner)
    values (new.id)
    on conflict (owner) do nothing;
  end if;
  return new;
end;
$$;
