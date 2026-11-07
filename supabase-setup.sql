create table if not exists public.store_delivery_staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.store_delivery_staff enable row level security;
revoke all on table public.store_delivery_staff from public, anon, authenticated;
grant select on table public.store_delivery_staff to authenticated;

drop policy if exists store_delivery_staff_read_self on public.store_delivery_staff;
create policy store_delivery_staff_read_self
  on public.store_delivery_staff
  for select
  to authenticated
  using (user_id = (select auth.uid()));

create table if not exists public.store_orders (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  created_at timestamptz not null default now(),
  customer text not null check (char_length(trim(customer)) between 1 and 120),
  phone text not null check (char_length(phone) between 8 and 30),
  normalized_phone text not null check (normalized_phone ~ '^[0-9]{10,15}$'),
  address text not null check (char_length(trim(address)) between 1 and 1000),
  payment_method text not null check (payment_method in ('cash', 'wallet', 'instapay', 'kashier')),
  payment_recipient text not null default '',
  customer_email text not null default '',
  receipt_path text,
  kashier_session_id text,
  kashier_session_url text,
  kashier_session_expires_at timestamptz,
  kashier_transaction_id text,
  notes text not null default '' check (char_length(notes) <= 2000),
  items jsonb not null check (jsonb_typeof(items) = 'array'),
  subtotal numeric(10, 2) not null check (subtotal >= 0),
  coupon_code text,
  coupon_discount numeric(10, 2) not null default 0 check (coupon_discount >= 0),
  points_used integer not null default 0 check (points_used >= 0),
  discount numeric(10, 2) not null default 0 check (discount >= 0),
  delivery_fee numeric(10, 2) not null default 0 check (delivery_fee >= 0),
  delivery_distance_km numeric(10, 4),
  delivery_latitude numeric(9, 6),
  delivery_longitude numeric(9, 6),
  total numeric(10, 2) not null check (total >= 0),
  points_earned integer not null default 0 check (points_earned >= 0),
  status text not null check (status in ('طلب جديد', 'بانتظار تأكيد الدفع', 'تم تأكيد الدفع', 'تعذر تأكيد الدفع')),
  fulfillment_status text not null default 'قيد التجهيز',
  delivery_status text not null default 'غير جاهز',
  delivery_user_id uuid references public.store_delivery_staff(user_id),
  delivered_at timestamptz,
  constraint store_orders_payment_receipt_check check (
    (payment_method = 'cash' and receipt_path is null and status = 'طلب جديد')
    or
    (
      payment_method in ('wallet', 'instapay')
      and receipt_path is not null
      and status in ('بانتظار تأكيد الدفع', 'تم تأكيد الدفع', 'تعذر تأكيد الدفع')
      and customer_email = ''
      and kashier_session_id is null
      and kashier_session_url is null
      and kashier_session_expires_at is null
      and kashier_transaction_id is null
    )
    or (
      payment_method = 'kashier'
      and receipt_path is null
      and customer_email ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'
      and status in ('بانتظار تأكيد الدفع', 'تم تأكيد الدفع', 'تعذر تأكيد الدفع')
    )
  )
);

alter table public.store_orders
  add column if not exists fulfillment_status text not null default 'قيد التجهيز';
alter table public.store_orders
  add column if not exists delivery_status text not null default 'غير جاهز';
alter table public.store_orders
  add column if not exists delivery_user_id uuid references public.store_delivery_staff(user_id);
alter table public.store_orders
  add column if not exists delivered_at timestamptz;
alter table public.store_orders
  add column if not exists delivery_fee numeric(10, 2) not null default 0;
alter table public.store_orders
  add column if not exists delivery_distance_km numeric(10, 4);
alter table public.store_orders
  add column if not exists delivery_latitude numeric(9, 6);
alter table public.store_orders
  add column if not exists delivery_longitude numeric(9, 6);
alter table public.store_orders
  add column if not exists customer_email text not null default '';
alter table public.store_orders
  add column if not exists kashier_session_id text;
alter table public.store_orders
  add column if not exists kashier_session_url text;
alter table public.store_orders
  add column if not exists kashier_session_expires_at timestamptz;
alter table public.store_orders
  add column if not exists kashier_transaction_id text;
alter table public.store_orders
  drop constraint if exists store_orders_payment_method_check;
alter table public.store_orders
  add constraint store_orders_payment_method_check
  check (payment_method in ('cash', 'wallet', 'instapay', 'kashier'));
alter table public.store_orders
  drop constraint if exists store_orders_payment_receipt_check;
alter table public.store_orders
  add constraint store_orders_payment_receipt_check check (
    (payment_method = 'cash' and receipt_path is null and status = 'طلب جديد')
    or (
      payment_method in ('wallet', 'instapay')
      and receipt_path is not null
      and status in ('بانتظار تأكيد الدفع', 'تم تأكيد الدفع', 'تعذر تأكيد الدفع')
      and customer_email = ''
      and kashier_session_id is null
      and kashier_session_url is null
      and kashier_session_expires_at is null
      and kashier_transaction_id is null
    )
    or (
      payment_method = 'kashier'
      and receipt_path is null
      and customer_email ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'
      and status in ('بانتظار تأكيد الدفع', 'تم تأكيد الدفع', 'تعذر تأكيد الدفع')
    )
  );
alter table public.store_orders
  drop constraint if exists store_orders_check;
alter table public.store_orders
  drop constraint if exists store_orders_total_check;
alter table public.store_orders
  add constraint store_orders_total_check
  check (total >= 0 and total = greatest(0, subtotal - discount) + delivery_fee);
alter table public.store_orders
  drop constraint if exists store_orders_delivery_location_check;
alter table public.store_orders
  add constraint store_orders_delivery_location_check
  check (
    (
      delivery_latitude is null
      and delivery_longitude is null
      and delivery_distance_km is null
      and delivery_fee = 0
    )
    or
    (
      delivery_latitude is not null
      and delivery_longitude is not null
      and delivery_distance_km is not null
      and delivery_latitude between -90 and 90
      and delivery_longitude between -180 and 180
      and delivery_distance_km >= 0
      and delivery_fee = round(delivery_distance_km * 8, 2)
    )
  );
alter table public.store_orders
  drop constraint if exists store_orders_fulfillment_status_check;
alter table public.store_orders
  add constraint store_orders_fulfillment_status_check
  check (fulfillment_status in ('قيد التجهيز', 'مكتمل'));
alter table public.store_orders
  drop constraint if exists store_orders_delivery_status_check;
alter table public.store_orders
  add constraint store_orders_delivery_status_check
  check (delivery_status in ('غير جاهز', 'متاح', 'مع المندوب', 'تم التوصيل'));

update public.store_orders
set delivery_status = 'متاح'
where fulfillment_status = 'مكتمل'
  and (payment_method = 'cash' or status = 'تم تأكيد الدفع')
  and delivery_status = 'غير جاهز';

alter table public.store_orders enable row level security;
revoke all on table public.store_orders from public, anon, authenticated;
grant insert on table public.store_orders to anon, authenticated;

drop policy if exists store_orders_anon_insert on public.store_orders;
create policy store_orders_anon_insert
  on public.store_orders
  for insert
  to anon, authenticated
  with check (
    (payment_method = 'cash' and receipt_path is null and status = 'طلب جديد'
      and customer_email = '' and kashier_session_id is null and kashier_session_url is null and kashier_session_expires_at is null and kashier_transaction_id is null)
    or
    (payment_method in ('wallet', 'instapay') and receipt_path is not null and status = 'بانتظار تأكيد الدفع'
      and customer_email = '' and kashier_session_id is null and kashier_session_url is null and kashier_session_expires_at is null and kashier_transaction_id is null)
    or
    (payment_method = 'kashier' and receipt_path is null
      and customer_email ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'
      and status = 'بانتظار تأكيد الدفع' and kashier_session_id is null and kashier_session_url is null and kashier_session_expires_at is null and kashier_transaction_id is null)
  );

create table if not exists public.store_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.store_admins enable row level security;
revoke all on table public.store_admins from public, anon, authenticated;
grant select on table public.store_admins to authenticated;

drop policy if exists store_admins_read_self on public.store_admins;
create policy store_admins_read_self
  on public.store_admins
  for select
  to authenticated
  using (user_id = (select auth.uid()));

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

grant select on table public.store_orders to authenticated;
grant update (status, fulfillment_status) on table public.store_orders to authenticated;

drop policy if exists store_orders_admin_select on public.store_orders;
create policy store_orders_admin_select
  on public.store_orders
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.store_admins
      where user_id = (select auth.uid())
    )
  );

drop policy if exists store_orders_admin_update_status on public.store_orders;
create policy store_orders_admin_update_status
  on public.store_orders
  for update
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

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-receipts', 'payment-receipts', false, 1048576, array['image/jpeg'])
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists payment_receipts_anon_upload on storage.objects;
grant insert on table storage.objects to anon, authenticated;
create policy payment_receipts_anon_upload
  on storage.objects
  for insert
  to anon, authenticated
  with check (
    bucket_id = 'payment-receipts'
    and (storage.foldername(name))[1] = 'orders'
    and array_length(storage.foldername(name), 1) = 1
    and lower(storage.extension(name)) = 'jpg'
  );

grant select on table storage.objects to authenticated;
drop policy if exists payment_receipts_admin_read on storage.objects;
create policy payment_receipts_admin_read
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'payment-receipts'
    and exists (
      select 1
      from public.store_admins
      where user_id = (select auth.uid())
    )
  );

create or replace function public.lookup_store_order(p_code text, p_phone text)
returns table (payment_status text, fulfillment_status text)
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
  select orders.status, orders.fulfillment_status
  from public.store_orders as orders
  where orders.code = upper(btrim(p_code))
    and orders.normalized_phone = p_phone
  limit 1;
$$;

revoke all on function public.lookup_store_order(text, text) from public, anon, authenticated;
grant execute on function public.lookup_store_order(text, text) to anon, authenticated;

notify pgrst, 'reload schema';

create table if not exists public.store_loyalty_accounts (
  normalized_phone text primary key check (normalized_phone ~ '^[0-9]{10,15}$'),
  points_balance integer not null default 0 check (points_balance >= 0),
  updated_at timestamptz not null default now()
);

alter table public.store_orders
  add column if not exists loyalty_settled boolean not null default true;

alter table public.store_loyalty_accounts enable row level security;
revoke all on table public.store_loyalty_accounts from public, anon, authenticated;

create or replace function public.get_store_loyalty_points(p_phone text)
returns integer
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_points integer;
begin
  if p_phone is null or p_phone !~ '^[0-9]{10,15}$' then
    raise exception 'Invalid normalized phone number' using errcode = '22023';
  end if;

  select account.points_balance
    into v_points
  from public.store_loyalty_accounts as account
  where account.normalized_phone = p_phone;

  return coalesce(v_points, 0);
end;
$$;

revoke all on function public.get_store_loyalty_points(text) from public, anon, authenticated;
grant execute on function public.get_store_loyalty_points(text) to anon, authenticated;

create or replace function public.apply_store_order_loyalty_points()
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

revoke all on function public.apply_store_order_loyalty_points() from public, anon, authenticated;

drop trigger if exists store_orders_apply_loyalty_points on public.store_orders;
create trigger store_orders_apply_loyalty_points
before insert on public.store_orders
for each row
execute function public.apply_store_order_loyalty_points();

create or replace function public.settle_store_order_loyalty_points()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_points_delta integer;
begin
  new.loyalty_settled := old.loyalty_settled;

  if old.status <> new.status and old.status <> 'بانتظار تأكيد الدفع' then
    raise exception 'Resolved payment status cannot be changed' using errcode = '23514';
  end if;

  if not old.loyalty_settled
     and old.status = 'بانتظار تأكيد الدفع'
     and new.status in ('تم تأكيد الدفع', 'تعذر تأكيد الدفع') then
    v_points_delta := case when new.status = 'تم تأكيد الدفع'
      then old.points_earned
      else old.points_used
    end;

    insert into public.store_loyalty_accounts (normalized_phone, points_balance)
    values (old.normalized_phone, v_points_delta)
    on conflict (normalized_phone) do update
      set points_balance = public.store_loyalty_accounts.points_balance + excluded.points_balance,
          updated_at = now();
    new.loyalty_settled := true;
  elsif not old.loyalty_settled
        and old.payment_method = 'cash'
        and old.fulfillment_status <> 'مكتمل'
        and new.fulfillment_status = 'مكتمل' then
    insert into public.store_loyalty_accounts (normalized_phone, points_balance)
    values (old.normalized_phone, old.points_earned)
    on conflict (normalized_phone) do update
      set points_balance = public.store_loyalty_accounts.points_balance + excluded.points_balance,
          updated_at = now();
    new.loyalty_settled := true;
  end if;

  return new;
end;
$$;

revoke all on function public.settle_store_order_loyalty_points() from public, anon, authenticated;

drop trigger if exists store_orders_settle_loyalty_points on public.store_orders;
create trigger store_orders_settle_loyalty_points
before update of status, fulfillment_status on public.store_orders
for each row
execute function public.settle_store_order_loyalty_points();

notify pgrst, 'reload schema';

create or replace function public.sync_store_delivery_readiness()
returns trigger
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if new.fulfillment_status = 'مكتمل'
    and (new.payment_method = 'cash' or new.status = 'تم تأكيد الدفع')
    and new.delivery_status = 'غير جاهز' then
    new.delivery_status := 'متاح';
  elsif new.fulfillment_status <> 'مكتمل' and new.delivery_status = 'متاح' then
    new.delivery_status := 'غير جاهز';
  end if;
  return new;
end;
$$;

drop trigger if exists store_orders_sync_delivery_readiness on public.store_orders;
create trigger store_orders_sync_delivery_readiness
  before update of fulfillment_status, status on public.store_orders
  for each row execute function public.sync_store_delivery_readiness();

create or replace function public.count_store_orders_delivered_today()
returns bigint
language sql
stable
security invoker
set search_path = pg_catalog, public, pg_temp
as $$
  select count(*)
  from public.store_orders
  where delivery_status = 'تم التوصيل'
    and delivered_at >= timezone('Africa/Cairo', date_trunc('day', timezone('Africa/Cairo', now())));
$$;

revoke all on function public.count_store_orders_delivered_today() from public, anon, authenticated;
grant execute on function public.count_store_orders_delivered_today() to authenticated;

drop function if exists public.list_store_delivery_orders();
create function public.list_store_delivery_orders()
returns table (
  id uuid,
  code text,
  created_at timestamptz,
  customer text,
  phone text,
  address text,
  notes text,
  items jsonb,
  delivery_fee numeric,
  delivery_distance_km numeric,
  delivery_latitude numeric,
  delivery_longitude numeric,
  total numeric,
  payment_method text,
  payment_status text,
  delivery_status text
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if not exists (select 1 from public.store_delivery_staff where user_id = auth.uid()) then
    raise exception 'not authorized';
  end if;

  return query
  select orders.id, orders.code, orders.created_at, orders.customer, orders.phone,
    orders.address, orders.notes, orders.items, orders.delivery_fee, orders.delivery_distance_km,
    orders.delivery_latitude, orders.delivery_longitude, orders.total, orders.payment_method,
    orders.status, orders.delivery_status
  from public.store_orders as orders
  where orders.fulfillment_status = 'مكتمل'
    and (orders.payment_method = 'cash' or orders.status = 'تم تأكيد الدفع')
    and (
      orders.delivery_status = 'متاح'
      or (orders.delivery_status = 'مع المندوب' and orders.delivery_user_id = auth.uid())
    )
  order by orders.created_at;
end;
$$;

create or replace function public.claim_store_delivery_order(p_order_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if not exists (select 1 from public.store_delivery_staff where user_id = auth.uid()) then
    raise exception 'not authorized';
  end if;

  update public.store_orders as orders
  set delivery_status = 'مع المندوب', delivery_user_id = auth.uid()
  where orders.id = p_order_id
    and orders.fulfillment_status = 'مكتمل'
    and (orders.payment_method = 'cash' or orders.status = 'تم تأكيد الدفع')
    and orders.delivery_status = 'متاح';
  return found;
end;
$$;

create or replace function public.complete_store_delivery_order(p_order_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if not exists (select 1 from public.store_delivery_staff where user_id = auth.uid()) then
    raise exception 'not authorized';
  end if;

  update public.store_orders as orders
  set delivery_status = 'تم التوصيل', delivered_at = now()
  where orders.id = p_order_id
    and orders.delivery_status = 'مع المندوب'
    and orders.delivery_user_id = auth.uid();
  return found;
end;
$$;

revoke all on function public.list_store_delivery_orders() from public, anon;
revoke all on function public.claim_store_delivery_order(uuid) from public, anon;
revoke all on function public.complete_store_delivery_order(uuid) from public, anon;
grant execute on function public.list_store_delivery_orders() to authenticated;
grant execute on function public.claim_store_delivery_order(uuid) to authenticated;
grant execute on function public.complete_store_delivery_order(uuid) to authenticated;

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
