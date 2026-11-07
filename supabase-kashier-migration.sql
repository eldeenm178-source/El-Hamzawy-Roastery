begin;

alter table public.store_orders
  add column if not exists customer_email text not null default '',
  add column if not exists kashier_session_id text,
  add column if not exists kashier_session_url text,
  add column if not exists kashier_session_expires_at timestamptz,
  add column if not exists kashier_transaction_id text;

alter table public.store_orders
  drop constraint if exists store_orders_payment_method_check,
  add constraint store_orders_payment_method_check
    check (payment_method in ('cash', 'wallet', 'instapay', 'kashier'));

alter table public.store_orders
  drop constraint if exists store_orders_payment_receipt_check,
  add constraint store_orders_payment_receipt_check check (
    (payment_method = 'cash' and receipt_path is null and status = 'طلب جديد')
    or (
      payment_method in ('wallet', 'instapay')
      and receipt_path is not null
      and status in ('بانتظار تأكيد الدفع', 'تم تأكيد الدفع', 'تعذر تأكيد الدفع')
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

drop policy if exists store_orders_anon_insert on public.store_orders;
create policy store_orders_anon_insert
  on public.store_orders
  for insert
  to anon, authenticated
  with check (
    (
      payment_method = 'cash'
      and receipt_path is null
      and status = 'طلب جديد'
      and customer_email = ''
      and kashier_session_id is null
      and kashier_session_url is null
      and kashier_session_expires_at is null
      and kashier_transaction_id is null
    )
    or (
      payment_method in ('wallet', 'instapay')
      and receipt_path is not null
      and status = 'بانتظار تأكيد الدفع'
      and customer_email = ''
      and kashier_session_id is null
      and kashier_session_url is null
      and kashier_transaction_id is null
    )
    or (
      payment_method = 'kashier'
      and receipt_path is null
      and customer_email ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'
      and status = 'بانتظار تأكيد الدفع'
      and kashier_session_id is null
      and kashier_session_url is null
      and kashier_session_expires_at is null
      and kashier_transaction_id is null
    )
  );

commit;
