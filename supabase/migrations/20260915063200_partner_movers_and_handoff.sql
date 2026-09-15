-- Partner moving companies leads get handed off to, and a record of the handoff.

create table public.partners (
  id             uuid primary key default gen_random_uuid(),
  owner          uuid not null default auth.uid() references auth.users on delete cascade,
  name           text not null check (length(trim(name)) > 0),
  license_number text,
  contact_email  text,
  contact_phone  text,
  notes          text,
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index partners_owner_idx on public.partners (owner);

create trigger partners_touch before update on public.partners
  for each row execute function public.touch_updated_at();

alter table public.partners enable row level security;

create policy "partners are private to owner" on public.partners
  for all to authenticated
  using (auth.uid() = owner)
  with check (auth.uid() = owner);

grant select, insert, update, delete on public.partners to authenticated, service_role;

alter table public.leads
  add column partner_id uuid references public.partners(id) on delete set null,
  add column sent_at timestamptz;
