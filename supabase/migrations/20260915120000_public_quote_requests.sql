-- Let anonymous visitors submit a quote request without an account.
-- Runs as SECURITY DEFINER so RLS never has to trust a client-supplied
-- owner id; anon still cannot read/write the tables directly.

create or replace function public.get_public_rates()
returns table (company text, phone text, hourly_per_mover numeric, travel_fee numeric, long_haul_base numeric)
language sql
security definer
set search_path = ''
stable
as $$
  select company, phone, hourly_per_mover, travel_fee, long_haul_base
  from public.company_settings
  limit 1;
$$;

revoke all on function public.get_public_rates() from public;
grant execute on function public.get_public_rates() to anon, authenticated;

create or replace function public.submit_quote_request(
  p_name text,
  p_phone text default null,
  p_email text default null,
  p_area text default null,
  p_home_size text default null,
  p_move_type text default null,
  p_miles integer default null,
  p_access text default null,
  p_packing boolean default false,
  p_notes text default null,
  p_quote_low integer default null,
  p_quote_high integer default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_id uuid;
begin
  select owner into v_owner from public.company_settings limit 1;
  if v_owner is null then
    raise exception 'No business is configured to receive requests yet.';
  end if;

  insert into public.leads (
    owner, name, phone, email, area, source, stage,
    home_size, move_type, miles, access, packing, notes,
    quote_low, quote_high
  ) values (
    v_owner, p_name, nullif(p_phone,''), nullif(p_email,''), nullif(p_area,''),
    'Website form', 'new',
    p_home_size, p_move_type, p_miles, p_access, coalesce(p_packing,false), nullif(p_notes,''),
    p_quote_low, p_quote_high
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.submit_quote_request(
  text, text, text, text, text, text, integer, text, boolean, text, integer, integer
) from public;
grant execute on function public.submit_quote_request(
  text, text, text, text, text, text, integer, text, boolean, text, integer, integer
) to anon, authenticated;
