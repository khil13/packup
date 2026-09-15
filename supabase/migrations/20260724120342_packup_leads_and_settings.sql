-- PackUp: leads pipeline + per-business rate settings

create table public.leads (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null default auth.uid() references auth.users on delete cascade,
  name        text not null check (length(trim(name)) > 0),
  phone       text,
  email       text,
  area        text,
  stage       text not null default 'new'
              check (stage in ('new','quoted','booked','lost')),
  source      text,
  home_size   text check (home_size in ('studio','br1','br2','br3','br4')),
  move_type   text check (move_type in ('local','long')),
  miles       integer check (miles >= 0),
  access      text check (access in ('ground','oneFlight','twoPlus','elevator')),
  packing     boolean not null default false,
  quote_low   integer check (quote_low >= 0),
  quote_high  integer check (quote_high >= 0),
  move_date   date,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index leads_owner_stage_idx on public.leads (owner, stage);
create index leads_owner_created_idx on public.leads (owner, created_at desc);

create table public.company_settings (
  owner             uuid primary key default auth.uid() references auth.users on delete cascade,
  company           text not null default 'My Moving Co',
  phone             text,
  hourly_per_mover  numeric(10,2) not null default 62,
  travel_fee        numeric(10,2) not null default 95,
  long_haul_base    numeric(10,4) not null default 0.35,
  areas             text[] not null default '{}',
  updated_at        timestamptz not null default now()
);

-- keep updated_at honest
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger leads_touch before update on public.leads
  for each row execute function public.touch_updated_at();
create trigger settings_touch before update on public.company_settings
  for each row execute function public.touch_updated_at();

-- row level security: a row belongs to exactly one account
alter table public.leads enable row level security;
alter table public.company_settings enable row level security;

create policy "leads are private to owner" on public.leads
  for all to authenticated
  using (auth.uid() = owner)
  with check (auth.uid() = owner);

create policy "settings are private to owner" on public.company_settings
  for all to authenticated
  using (auth.uid() = owner)
  with check (auth.uid() = owner);
