-- submit_quote_request() is SECURITY DEFINER and granted to anon, reachable
-- directly via the REST RPC endpoint with the public anon key (normal —
-- that key is meant to be public). The only anti-spam measure was a
-- client-side honeypot field, which only stops bots that execute the page's
-- JS; a script calling the RPC endpoint directly bypasses it completely and
-- could flood public.leads with unlimited garbage rows for free. This adds
-- a simple per-IP rate limit and sane length caps on the free-text fields.
--
-- The IP comes from the x-forwarded-for header PostgREST exposes via
-- request.headers, which Supabase's edge network sets from the real client
-- connection for ordinary requests. Like any header-based IP, it is not
-- unspoofable by a determined attacker crafting raw requests — but it stops
-- the realistic threat here (a script hammering the endpoint from one
-- source) at negligible cost, which is a meaningful improvement over no
-- throttle at all.

create table public.quote_request_log (
  id bigint generated always as identity primary key,
  ip text not null,
  created_at timestamptz not null default now()
);

create index quote_request_log_ip_created_idx on public.quote_request_log (ip, created_at desc);

alter table public.quote_request_log enable row level security;

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
  v_ip text;
  v_recent_count integer;
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

  select owner into v_owner from public.company_settings limit 1;
  if v_owner is null then
    raise exception 'No business is configured to receive requests yet.';
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
  text, text, text, text, text, text, integer, text, boolean, text, integer, integer
) from public;
grant execute on function public.submit_quote_request(
  text, text, text, text, text, text, integer, text, boolean, text, integer, integer
) to anon, authenticated;
