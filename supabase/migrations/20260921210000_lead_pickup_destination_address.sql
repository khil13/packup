-- Leads only ever captured a free-text "area" (neighborhood) plus a
-- self-reported distance slider -- no actual address. A partner mover
-- receiving a lead had no way to know where the move even was without
-- calling the customer first. Add real pickup/destination addresses, and
-- require both server-side the same way phone/email is required -- this
-- RPC is granted to anon and callable directly, so that's where the real
-- guarantee has to live (index.html also checks client-side for feedback).

alter table public.leads
  add column pickup_address text,
  add column destination_address text;

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
  p_quote_high integer default null,
  p_owner uuid default null,
  p_utm_source text default null,
  p_utm_medium text default null,
  p_utm_campaign text default null,
  p_ref uuid default null,
  p_pickup_address text default null,
  p_destination_address text default null
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
  if nullif(p_phone,'') is null and nullif(p_email,'') is null then
    raise exception 'A phone number or email address is required.';
  end if;
  if nullif(trim(p_pickup_address),'') is null then
    raise exception 'A pickup address is required.';
  end if;
  if nullif(trim(p_destination_address),'') is null then
    raise exception 'A destination address is required.';
  end if;

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
  if length(coalesce(p_pickup_address, '')) > 300 then
    raise exception 'Pickup address is too long.';
  end if;
  if length(coalesce(p_destination_address, '')) > 300 then
    raise exception 'Destination address is too long.';
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
    referred_by_type, referred_by_id, referral_discount_applied,
    pickup_address, destination_address
  ) values (
    v_owner, p_name, nullif(p_phone,''), nullif(p_email,''), nullif(p_area,''),
    'Website form', 'new',
    p_home_size, p_move_type, p_miles, p_access, coalesce(p_packing,false), nullif(p_notes,''),
    p_quote_low, p_quote_high, nullif(p_utm_source,''), nullif(p_utm_medium,''), nullif(p_utm_campaign,''),
    v_referred_by_type, v_referred_by_id, v_referral_discount,
    nullif(trim(p_pickup_address),''), nullif(trim(p_destination_address),'')
  )
  returning id into v_id;

  return v_id;
end;
$$;
