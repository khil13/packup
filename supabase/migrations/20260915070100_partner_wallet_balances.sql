-- Prepaid wallet balance per partner, funded either manually (recorded here)
-- or later via Stripe, and debited automatically when a lead is handed off.

alter table public.partners add column balance_cents integer not null default 0 check (balance_cents >= 0);

create table public.wallet_transactions (
  id                      uuid primary key default gen_random_uuid(),
  owner                   uuid not null default auth.uid() references auth.users on delete cascade,
  partner_id              uuid not null references public.partners(id) on delete cascade,
  amount_cents            integer not null, -- positive = funds added, negative = lead charge
  kind                    text not null check (kind in ('topup','lead_charge','adjustment')),
  lead_id                 uuid references public.leads(id) on delete set null,
  stripe_payment_intent_id text,
  note                    text,
  created_at              timestamptz not null default now()
);

create index wallet_tx_partner_idx on public.wallet_transactions (partner_id, created_at desc);

alter table public.wallet_transactions enable row level security;

create policy "wallet transactions are private to owner" on public.wallet_transactions
  for all to authenticated
  using (auth.uid() = owner)
  with check (auth.uid() = owner);

grant select, insert, update, delete on public.wallet_transactions to authenticated, service_role;

-- record what a lead was actually charged at handoff, for reporting
alter table public.leads add column charged_cents integer;
