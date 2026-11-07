create table if not exists public.store_product_overrides (
  product_id integer primary key check (product_id > 0),
  name text not null check (char_length(trim(name)) between 1 and 160),
  category text not null check (char_length(trim(category)) between 1 and 80),
  price numeric(10, 2) check (price is null or price >= 0),
  image text not null check (image ~* '^(real/)?[a-z0-9._-]+\.(jpg|jpeg|png|webp)$'),
  updated_at timestamptz not null default now()
);

alter table public.store_product_overrides enable row level security;
revoke all on table public.store_product_overrides from public, anon, authenticated;
grant select on table public.store_product_overrides to anon, authenticated;
grant insert, update on table public.store_product_overrides to authenticated;

drop policy if exists store_product_overrides_public_read on public.store_product_overrides;
create policy store_product_overrides_public_read
  on public.store_product_overrides
  for select
  to anon, authenticated
  using (true);

drop policy if exists store_product_overrides_admin_write on public.store_product_overrides;
create policy store_product_overrides_admin_write
  on public.store_product_overrides
  for all
  to authenticated
  using (
    exists (
      select 1
      from public.store_admins
      where user_id = (select auth.uid())
    )
  )
  with check (
    exists (
      select 1
      from public.store_admins
      where user_id = (select auth.uid())
    )
  );
