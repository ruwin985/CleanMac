create extension if not exists pgcrypto;

create table if not exists public.cleanmac_webhook_events (
  event_id text primary key,
  event_type text not null,
  paddle_transaction_id text,
  payload jsonb not null,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  error_message text
);

create table if not exists public.cleanmac_orders (
  paddle_transaction_id text primary key,
  paddle_customer_id text,
  customer_email text,
  price_id text,
  product_id text,
  currency_code text,
  total_amount_minor integer,
  status text not null default 'completed',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  raw_event_id text references public.cleanmac_webhook_events(event_id)
);

create table if not exists public.cleanmac_licenses (
  license_id uuid primary key default gen_random_uuid(),
  license_code_hash text not null unique,
  license_code_ciphertext text,
  license_code_iv text,
  license_code_prefix text not null,
  paddle_transaction_id text not null references public.cleanmac_orders(paddle_transaction_id),
  customer_email text,
  status text not null default 'active',
  issued_at timestamptz not null default now(),
  last_emailed_at timestamptz,
  email_send_id text,
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists public.cleanmac_activations (
  activation_id uuid primary key default gen_random_uuid(),
  license_id uuid not null references public.cleanmac_licenses(license_id),
  device_id_hash text not null,
  app_version text,
  build_number text,
  platform text,
  activated_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (license_id, device_id_hash)
);

create index if not exists cleanmac_licenses_transaction_idx on public.cleanmac_licenses(paddle_transaction_id);
create index if not exists cleanmac_activations_license_idx on public.cleanmac_activations(license_id);

alter table public.cleanmac_licenses add column if not exists license_code_ciphertext text;
alter table public.cleanmac_licenses add column if not exists license_code_iv text;
