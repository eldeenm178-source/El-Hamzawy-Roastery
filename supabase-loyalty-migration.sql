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
