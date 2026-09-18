-- get_public_rates' RETURNS TABLE columns (company, phone, hourly_per_mover,
-- travel_fee, long_haul_base) share names with the company_settings columns
-- they select. plpgsql resolves an unqualified column reference against the
-- OUT parameters before the table, so an unaliased `select company, phone, ...
-- from company_settings` returns the (null) OUT parameters back at themselves
-- instead of the row data — no error, just silently empty results. This was
-- caught immediately after deploying multi_tenant_public_scoping and hot-
-- fixed directly; recorded here so the migration history matches what's
-- actually applied. The fix (aliasing the table and qualifying every column)
-- is already reflected in multi_tenant_public_scoping's committed source —
-- this migration just re-asserts it, and is a no-op against a database that
-- already has it.

create or replace function public.get_public_rates(p_owner uuid default null)
returns table (company text, phone text, hourly_per_mover numeric, travel_fee numeric, long_haul_base numeric)
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  v_count int;
begin
  if p_owner is not null then
    return query
      select cs.company, cs.phone, cs.hourly_per_mover, cs.travel_fee, cs.long_haul_base
      from public.company_settings cs where cs.owner = p_owner;
    return;
  end if;

  select count(*) into v_count from public.company_settings;
  if v_count = 1 then
    return query
      select cs.company, cs.phone, cs.hourly_per_mover, cs.travel_fee, cs.long_haul_base
      from public.company_settings cs limit 1;
    return;
  end if;

  raise exception 'This link is missing which business it belongs to.';
end;
$$;
