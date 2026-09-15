-- Bots/crawlers/link-previewers were counting as "visits" in the funnel
-- stats (confirmed live: a real page view landed alongside one from a
-- clearly automated source, e.g. a cloud-hosted IP fetching the page with
-- no human involved). Filter on User-Agent before logging — PostgREST
-- exposes it via request.headers same as x-forwarded-for, and browsers
-- can't be scripted to override it, so this is the real client UA for
-- genuine visitors. No client change needed.

create or replace function public.log_page_view(p_path text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ip text;
  v_ua text;
begin
  v_ua := current_setting('request.headers', true)::json->>'user-agent';

  if v_ua is null or trim(v_ua) = '' then
    return; -- no UA at all: not a real browser, skip
  end if;
  if v_ua ~* '(bot|spider|crawl|slurp|facebookexternalhit|slackbot|discordbot|telegrambot|whatsapp|preview|headless|curl/|wget/|python-requests|go-http-client|okhttp|postmanruntime|node-fetch|axios/)' then
    return; -- known bot/fetcher signature: skip
  end if;

  v_ip := coalesce(
    nullif(split_part(current_setting('request.headers', true)::json->>'x-forwarded-for', ',', 1), ''),
    'unknown'
  );
  insert into public.page_view_log (path, ip) values (left(coalesce(p_path, ''), 200), v_ip);
end;
$$;
