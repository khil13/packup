-- Referral program: a past customer or a partner can share a link
-- (?ref=<their own lead or partner id>) that gives whoever books through
-- it a discount off their quoted price. The discount amount is per
-- business, configurable in Setup, defaulting to $50. No new codes table
-- needed — the referrer's own row id *is* the code, same pattern already
-- used for partner portal links.

alter table public.company_settings add column referral_discount integer not null default 50;

alter table public.leads add column referred_by_type text
  check (referred_by_type is null or referred_by_type in ('lead', 'partner'));
alter table public.leads add column referred_by_id uuid;
alter table public.leads add column referral_discount_applied integer;

create function public.get_referral_discount(p_ref uuid, p_owner uuid default null)
returns integer
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  v_owner uuid;
  v_count int;
  v_valid boolean;
  v_discount integer;
begin
  if p_ref is null then
    return null;
  end if;

  if p_owner is not null then
    select owner into v_owner from public.company_settings where owner = p_owner;
  else
    select count(*) into v_count from public.company_settings;
    if v_count = 1 then
      select owner into v_owner from public.company_settings limit 1;
    end if;
  end if;

  if v_owner is null then
    return null;
  end if;

  select exists(select 1 from public.leads where id = p_ref and owner = v_owner)
      or exists(select 1 from public.partners where id = p_ref and owner = v_owner)
    into v_valid;

  if not v_valid then
    return null;
  end if;

  select referral_discount into v_discount from public.company_settings where owner = v_owner;
  return v_discount;
end;
$$;

revoke all on function public.get_referral_discount(uuid, uuid) from public;
grant execute on function public.get_referral_discount(uuid, uuid) to anon, authenticated;

drop function if exists public.submit_quote_request(
  text, text, text, text, text, text, integer, text, boolean, text, integer, integer, uuid, text, text, text
);

create function public.submit_quote_request(
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
  p_quote_high integer default null,
  p_owner uuid default null,
  p_utm_source text default null,
  p_utm_medium text default null,
  p_utm_campaign text default null,
  p_ref uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_id uuid;
  v_ip text;
  v_recent_count integer;
  v_count int;
  v_referred_by_type text;
  v_referred_by_id uuid;
  v_referral_discount integer;
begin
  if length(coalesce(p_name, '')) > 200 then
    raise exception 'Name is too long.';
  end if;
  if length(coalesce(p_phone, '')) > 40 then
    raise exception 'Phone number is too long.';
  end if;
  if length(coalesce(p_email, '')) > 320 then
    raise exception 'Email address is too long.';
  end if;
  if length(coalesce(p_area, '')) > 200 then
    raise exception 'Area is too long.';
  end if;
  if length(coalesce(p_notes, '')) > 4000 then
    raise exception 'Notes are too long.';
  end if;
  if length(coalesce(p_utm_source, '')) > 200 then
    raise exception 'utm_source is too long.';
  end if;
  if length(coalesce(p_utm_medium, '')) > 200 then
    raise exception 'utm_medium is too long.';
  end if;
  if length(coalesce(p_utm_campaign, '')) > 200 then
    raise exception 'utm_campaign is too long.';
  end if;

  v_ip := coalesce(
    nullif(split_part(current_setting('request.headers', true)::json->>'x-forwarded-for', ',', 1), ''),
    'unknown'
  );

  select count(*) into v_recent_count
  from public.quote_request_log
  where ip = v_ip and created_at > now() - interval '1 hour';

  if v_recent_count >= 5 then
    raise exception 'Too many requests — please try again later.';
  end if;

  if p_owner is not null then
    select owner into v_owner from public.company_settings where owner = p_owner;
  else
    select count(*) into v_count from public.company_settings;
    if v_count = 1 then
      select owner into v_owner from public.company_settings limit 1;
    end if;
  end if;

  if v_owner is null then
    raise exception 'This link is missing which business it belongs to.';
  end if;

  -- resolve the referral server-side rather than trusting a client-supplied
  -- discount — the quote range itself is only ever advisory (a human
  -- confirms final pricing), but what we record against the lead shouldn't be
  if p_ref is not null then
    if exists(select 1 from public.leads where id = p_ref and owner = v_owner) then
      v_referred_by_type := 'lead';
      v_referred_by_id := p_ref;
    elsif exists(select 1 from public.partners where id = p_ref and owner = v_owner) then
      v_referred_by_type := 'partner';
      v_referred_by_id := p_ref;
    end if;

    if v_referred_by_id is not null then
      select referral_discount into v_referral_discount from public.company_settings where owner = v_owner;
    end if;
  end if;

  insert into public.quote_request_log (ip) values (v_ip);

  insert into public.leads (
    owner, name, phone, email, area, source, stage,
    home_size, move_type, miles, access, packing, notes,
    quote_low, quote_high, utm_source, utm_medium, utm_campaign,
    referred_by_type, referred_by_id, referral_discount_applied
  ) values (
    v_owner, p_name, nullif(p_phone,''), nullif(p_email,''), nullif(p_area,''),
    'Website form', 'new',
    p_home_size, p_move_type, p_miles, p_access, coalesce(p_packing,false), nullif(p_notes,''),
    p_quote_low, p_quote_high, nullif(p_utm_source,''), nullif(p_utm_medium,''), nullif(p_utm_campaign,''),
    v_referred_by_type, v_referred_by_id, v_referral_discount
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.submit_quote_request(
  text, text, text, text, text, text, integer, text, boolean, text, integer, integer, uuid, text, text, text, uuid
) from public;
grant execute on function public.submit_quote_request(
  text, text, text, text, text, text, integer, text, boolean, text, integer, integer, uuid, text, text, text, uuid
) to anon, authenticated;
