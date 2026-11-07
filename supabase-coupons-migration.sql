create table if not exists public.store_coupons (
  code text primary key check (code ~ '^[A-Z0-9_-]{2,40}$'),
  discount_type text not null check (discount_type in ('fixed', 'percent')),
  discount_value numeric(10, 2) not null check (
    discount_value > 0 and (discount_type <> 'percent' or discount_value <= 100)
  ),
  product_names text[] not null default array[]::text[],
  starts_at timestamptz,
  expires_at timestamptz,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (expires_at is null or starts_at is null or expires_at > starts_at)
);

alter table public.store_coupons enable row level security;
revoke all on table public.store_coupons from public, anon, authenticated;
grant select, insert, update, delete on table public.store_coupons to authenticated;

drop policy if exists store_coupons_admin_select on public.store_coupons;
create policy store_coupons_admin_select
  on public.store_coupons for select to authenticated
  using (exists (select 1 from public.store_admins where user_id = (select auth.uid())));

drop policy if exists store_coupons_admin_insert on public.store_coupons;
create policy store_coupons_admin_insert
  on public.store_coupons for insert to authenticated
  with check (exists (select 1 from public.store_admins where user_id = (select auth.uid())));

drop policy if exists store_coupons_admin_update on public.store_coupons;
create policy store_coupons_admin_update
  on public.store_coupons for update to authenticated
  using (exists (select 1 from public.store_admins where user_id = (select auth.uid())))
  with check (exists (select 1 from public.store_admins where user_id = (select auth.uid())));

drop policy if exists store_coupons_admin_delete on public.store_coupons;
create policy store_coupons_admin_delete
  on public.store_coupons for delete to authenticated
  using (exists (select 1 from public.store_admins where user_id = (select auth.uid())));

insert into public.store_coupons (code, discount_type, discount_value)
values ('SAVE50', 'fixed', 50)
on conflict (code) do nothing;

create or replace function public.get_store_coupon(p_code text)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
  select jsonb_build_object(
    'code', coupon.code,
    'discount_type', coupon.discount_type,
    'discount_value', coupon.discount_value,
    'product_names', coupon.product_names
  )
  from public.store_coupons as coupon
  where coupon.code = upper(btrim(p_code))
    and coupon.is_active
    and (coupon.starts_at is null or coupon.starts_at <= now())
    and (coupon.expires_at is null or coupon.expires_at > now())
  limit 1;
$$;

revoke all on function public.get_store_coupon(text) from public, anon, authenticated;
grant execute on function public.get_store_coupon(text) to anon, authenticated;

create or replace function public.calculate_store_coupon_discount(
  p_code text,
  p_items jsonb,
  p_subtotal numeric
)
returns numeric
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_coupon jsonb;
  v_product_names text[];
  v_eligible_subtotal numeric;
  v_discount numeric;
begin
  if p_code is null or btrim(p_code) = '' then
    return 0;
  end if;
  if jsonb_typeof(p_items) <> 'array' or p_subtotal < 0 then
    raise exception 'Invalid coupon cart' using errcode = '22023';
  end if;

  v_coupon := public.get_store_coupon(p_code);
  if v_coupon is null then
    raise exception 'Invalid or expired coupon code' using errcode = '22023';
  end if;

  select array_agg(value)
    into v_product_names
  from jsonb_array_elements_text(v_coupon->'product_names') as names(value);

  select coalesce(sum(greatest(0, (item->>'subtotal')::numeric)), 0)
    into v_eligible_subtotal
  from jsonb_array_elements(p_items) as items(item)
  where coalesce(cardinality(v_product_names), 0) = 0
     or exists (
       select 1
       from unnest(v_product_names) as selected(name)
       where lower(btrim(selected.name)) = lower(btrim(item->>'name'))
     );

  v_eligible_subtotal := least(v_eligible_subtotal, p_subtotal);
  if v_coupon->>'discount_type' = 'percent' then
    v_discount := v_eligible_subtotal * (v_coupon->>'discount_value')::numeric / 100;
  else
    v_discount := least(v_eligible_subtotal, (v_coupon->>'discount_value')::numeric);
  end if;
  return round(v_discount, 2);
end;
$$;

revoke all on function public.calculate_store_coupon_discount(text, jsonb, numeric) from public, anon, authenticated;

create or replace function public.apply_store_order_coupon_and_points()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_balance integer;
  v_points_used integer;
  v_use_limit integer;
begin
  new.fulfillment_status := 'قيد التجهيز';
  new.delivery_status := 'غير جاهز';
  new.delivery_user_id := null;
  new.delivered_at := null;
  new.loyalty_settled := false;
  new.coupon_code := nullif(upper(btrim(new.coupon_code)), '');
  new.coupon_discount := public.calculate_store_coupon_discount(
    new.coupon_code, new.items, new.subtotal
  );

  insert into public.store_loyalty_accounts (normalized_phone)
  values (new.normalized_phone)
  on conflict (normalized_phone) do nothing;

  select account.points_balance
    into v_balance
  from public.store_loyalty_accounts as account
  where account.normalized_phone = new.normalized_phone
  for update;

  v_use_limit := greatest(
    0,
    floor(greatest(0, new.subtotal - new.coupon_discount))::integer
  );
  if new.points_used > v_balance or new.points_used > v_use_limit then
    raise exception 'Loyalty points balance changed; refresh and try again' using errcode = 'P0001';
  end if;
  v_points_used := new.points_used;

  new.points_used := v_points_used;
  new.points_earned := floor(new.subtotal / 100)::integer * 3;
  new.discount := new.coupon_discount + v_points_used;
  new.total := greatest(0, new.subtotal - new.discount) + new.delivery_fee;

  update public.store_loyalty_accounts
  set points_balance = points_balance - v_points_used,
      updated_at = now()
  where normalized_phone = new.normalized_phone;

  return new;
end;
$$;

revoke all on function public.apply_store_order_coupon_and_points() from public, anon, authenticated;

drop trigger if exists store_orders_apply_loyalty_points on public.store_orders;
drop trigger if exists store_orders_apply_coupon_and_points on public.store_orders;
create trigger store_orders_apply_coupon_and_points
before insert on public.store_orders
for each row
execute function public.apply_store_order_coupon_and_points();

notify pgrst, 'reload schema';
