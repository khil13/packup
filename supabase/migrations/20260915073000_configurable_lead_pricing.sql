alter table public.company_settings
  add column lead_price_small       numeric(10,2) not null default 12,
  add column lead_price_medium      numeric(10,2) not null default 15,
  add column lead_price_large       numeric(10,2) not null default 19,
  add column lead_price_xlarge      numeric(10,2) not null default 24,
  add column lead_price_distance_surcharge numeric(10,2) not null default 6;
