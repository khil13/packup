-- The schema is built for multi-tenancy (every table has an owner column,
-- RLS scoped per-owner throughout), but the public entry points
-- (get_public_rates, submit_quote_request) and the funnel stats RPC all
-- either grabbed an arbitrary company_settings row via LIMIT 1 or, in
-- get_lead_funnel_stats' case, didn't scope by owner at all. Dormant today
-- (exactly one business exists), but the moment a second one signs up this
-- silently mixes businesses' leads, rates, and analytics together.
--
-- Fix: every public call can now carry an explicit p_owner (the business's
-- own auth.users id — no new slug/identifier concept needed). Omitting it
-- still works exactly as before as long as there's exactly one business in
-- the database; the moment there's more than one, it fails loudly instead
-- of guessing. get_lead_funnel_stats is scoped by the caller's own
-- auth.uid(), which it always should have been.
--
-- CREATE OR REPLACE does not replace a function when the parameter list
-- changes (even by adding one with a default) — it silently creates a
-- second overload and leaves the old, unscoped signature callable. Every
-- changed signature below is explicitly dropped first.

drop function if exists public.get_public_rates();

create function public.get_public_rates(p_owner uuid default null)
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

revoke all on function public.get_public_rates(uuid) from public;
grant execute on function public.get_public_rates(uuid) to anon, authenticated;

drop function if exists public.submit_quote_request(
  text, text, text, text, text, text, integer, text, boolean, text, integer, integer
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
  p_owner uuid default null
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

  insert into public.quote_request_log (ip) values (v_ip);

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
  text, text, text, text, text, text, integer, text, boolean, text, integer, integer, uuid
) from public;
grant execute on function public.submit_quote_request(
  text, text, text, text, text, text, integer, text, boolean, text, integer, integer, uuid
) to anon, authenticated;

alter table public.page_view_log add column owner uuid references auth.users(id) on delete set null;

drop function if exists public.log_page_view(text);

create function public.log_page_view(p_path text, p_owner uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ip text;
  v_ua text;
  v_owner uuid;
  v_count int;
begin
  v_ua := current_setting('request.headers', true)::json->>'user-agent';

  if v_ua is null or trim(v_ua) = '' then
    return;
  end if;
  if v_ua ~* '(bot|spider|crawl|slurp|facebookexternalhit|slackbot|discordbot|telegrambot|whatsapp|preview|headless|curl/|wget/|python-requests|go-http-client|okhttp|postmanruntime|node-fetch|axios/)' then
    return;
  end if;

  if p_owner is not null then
    select owner into v_owner from public.company_settings where owner = p_owner;
  else
    select count(*) into v_count from public.company_settings;
    if v_count = 1 then
      select owner into v_owner from public.company_settings limit 1;
    end if;
  end if;

  v_ip := coalesce(
    nullif(split_part(current_setting('request.headers', true)::json->>'x-forwarded-for', ',', 1), ''),
    'unknown'
  );
  insert into public.page_view_log (path, ip, owner) values (left(coalesce(p_path, ''), 200), v_ip, v_owner);
end;
$$;

revoke all on function public.log_page_view(text, uuid) from public;
grant execute on function public.log_page_view(text, uuid) to anon, authenticated;

create or replace function public.get_lead_funnel_stats()
returns table (views_7d bigint, requests_7d bigint)
language sql
security definer
set search_path = ''
stable
as $$
  select
    (select count(*) from public.page_view_log where path = 'request.html' and owner = auth.uid() and created_at > now() - interval '7 days'),
    (select count(*) from public.leads where source = 'Website form' and owner = auth.uid() and created_at > now() - interval '7 days');
$$;
