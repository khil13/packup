-- leads.source has always been the hardcoded literal 'Website form' — it
-- says how someone reached out, not which marketing channel sent them. The
-- moment there's more than one lead channel (paid search, a partner's own
-- link, social), there's no way to tell which one is actually working.
-- Add utm_source/utm_medium/utm_campaign, captured client-side from the
-- standard ?utm_source=&utm_medium=&utm_campaign= query params and passed
-- through untouched — same shape any ad platform or link shortener already
-- produces, no new convention to invent.

alter table public.leads add column utm_source text;
alter table public.leads add column utm_medium text;
alter table public.leads add column utm_campaign text;

drop function if exists public.submit_quote_request(
  text, text, text, text, text, text, integer, text, boolean, text, integer, integer, uuid
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
  p_utm_campaign text default null
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

  insert into public.quote_request_log (ip) values (v_ip);

  insert into public.leads (
    owner, name, phone, email, area, source, stage,
    home_size, move_type, miles, access, packing, notes,
    quote_low, quote_high, utm_source, utm_medium, utm_campaign
  ) values (
    v_owner, p_name, nullif(p_phone,''), nullif(p_email,''), nullif(p_area,''),
    'Website form', 'new',
    p_home_size, p_move_type, p_miles, p_access, coalesce(p_packing,false), nullif(p_notes,''),
    p_quote_low, p_quote_high, nullif(p_utm_source,''), nullif(p_utm_medium,''), nullif(p_utm_campaign,'')
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.submit_quote_request(
  text, text, text, text, text, text, integer, text, boolean, text, integer, integer, uuid, text, text, text
) from public;
grant execute on function public.submit_quote_request(
  text, text, text, text, text, text, integer, text, boolean, text, integer, integer, uuid, text, text, text
) to anon, authenticated;
