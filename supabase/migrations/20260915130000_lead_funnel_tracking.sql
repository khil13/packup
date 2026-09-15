-- Lightweight first-party visit tracking for the public quote form, so the
-- owner can see visits vs. actual submissions (there was previously zero
-- visibility into that funnel). Deliberately its own table, not a reuse of
-- quote_request_log — that table's row count drives the submission rate
-- limit, so mixing page views into it would silently tighten that limit.

create table public.page_view_log (
  id bigint generated always as identity primary key,
  path text not null,
  ip text not null,
  created_at timestamptz not null default now()
);

create index page_view_log_created_idx on public.page_view_log (created_at desc);

alter table public.page_view_log enable row level security;

create or replace function public.log_page_view(p_path text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ip text;
begin
  v_ip := coalesce(
    nullif(split_part(current_setting('request.headers', true)::json->>'x-forwarded-for', ',', 1), ''),
    'unknown'
  );
  insert into public.page_view_log (path, ip) values (left(coalesce(p_path, ''), 200), v_ip);
end;
$$;

revoke all on function public.log_page_view(text) from public;
grant execute on function public.log_page_view(text) to anon, authenticated;

-- app is single-tenant in practice (every public RPC already assumes one
-- company_settings row via `limit 1`), so this is a plain aggregate, not
-- scoped per-owner
create or replace function public.get_lead_funnel_stats()
returns table (views_7d bigint, requests_7d bigint)
language sql
security definer
set search_path = ''
stable
as $$
  select
    (select count(*) from public.page_view_log where path = 'request.html' and created_at > now() - interval '7 days'),
    (select count(*) from public.leads where source = 'Website form' and created_at > now() - interval '7 days');
$$;

revoke all on function public.get_lead_funnel_stats() from public;
grant execute on function public.get_lead_funnel_stats() to authenticated;
