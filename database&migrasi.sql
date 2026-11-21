-- =====================================================================
-- MIGRASI JEMBATAN (jalankan SETELAH database.sql / migrasi.sql,
-- dan SEBELUM migrasi-v2.sql). Aman dijalankan berulang.
-- Supabase Dashboard -> SQL Editor -> New query -> tempel -> Run.
-- Menambah:
--  1. Status bayar / bayar nanti (is_paid, paid_at, customer_name)
--  2. Status antrian (is_made) + fungsi ubah_status_pesanan
--  3. Buku kas manual (cash_entries)
--  4. Laporan hanya menghitung transaksi yang sudah dibayar
-- =====================================================================

-- ---------- 1. STATUS BAYAR ----------
alter table transactions add column if not exists customer_name text;
alter table transactions add column if not exists is_paid boolean not null default true;
alter table transactions add column if not exists paid_at timestamptz;
update transactions set paid_at = created_at where paid_at is null and is_paid;

-- pesanan "bayar nanti": metode belum diketahui
alter table transactions alter column method drop not null;

-- ---------- 2. STATUS ANTRIAN ----------
-- Transaksi lama dianggap sudah dibuat (supaya antrian tidak penuh data lama);
-- transaksi baru default-nya belum dibuat.
alter table transactions add column if not exists is_made boolean not null default true;
alter table transactions alter column is_made set default false;
create index if not exists transactions_queue_idx on transactions (is_made, is_paid);

drop function if exists ubah_status_pesanan(bigint, boolean);
create or replace function ubah_status_pesanan(p_id bigint, p_made boolean) returns void
language plpgsql security definer set search_path = public as $fn$
begin
  update transactions set is_made = p_made where id = p_id;
  if not found then raise exception 'Transaksi tidak ditemukan'; end if;
end $fn$;
revoke all on function ubah_status_pesanan(bigint, boolean) from public;
grant execute on function ubah_status_pesanan(bigint, boolean) to anon, authenticated;

-- fungsi lama (5 parameter) diganti versi baru di migrasi-v2.sql
drop function if exists buat_transaksi(jsonb, text, numeric, text, text);

-- ---------- 3. BUKU KAS MANUAL ----------
create table if not exists cash_entries (
  id          bigint generated always as identity primary key,
  entry_date  timestamptz not null default now(),
  kind        text not null check (kind in ('masuk','keluar')),
  category    text not null default 'Lainnya',
  description text,
  amount      numeric(12,0) not null check (amount > 0),
  created_at  timestamptz not null default now()
);
create index if not exists cash_entries_date_idx on cash_entries (entry_date desc);
alter table cash_entries enable row level security;
drop policy if exists "tulis_admin" on cash_entries;
create policy "tulis_admin" on cash_entries for all to authenticated
  using (is_admin()) with check (is_admin());

-- ---------- 4. LAPORAN: HANYA YANG SUDAH DIBAYAR ----------
create or replace view report_summary with (security_invoker = true) as
with p as (
  select
    (date_trunc('day',   now() at time zone 'Asia/Makassar')) at time zone 'Asia/Makassar' as d,
    (date_trunc('week',  now() at time zone 'Asia/Makassar')) at time zone 'Asia/Makassar' as w,
    (date_trunc('month', now() at time zone 'Asia/Makassar')) at time zone 'Asia/Makassar' as m,
    (date_trunc('year',  now() at time zone 'Asia/Makassar')) at time zone 'Asia/Makassar' as y
), periods(period, since) as (
  select 'Hari ini',    d from p union all
  select 'Minggu ini',  w from p union all
  select 'Bulan ini',   m from p union all
  select 'Tahun ini',   y from p union all
  select 'Semua waktu', '-infinity'::timestamptz
)
select
  per.period,
  coalesce((select count(*) from transactions t where t.is_paid and coalesce(t.paid_at, t.created_at) >= per.since), 0)  as jumlah_transaksi,
  coalesce((select sum(t.total) from transactions t where t.is_paid and coalesce(t.paid_at, t.created_at) >= per.since), 0) as pendapatan,
  coalesce((select sum(b.price) from purchases b where b.purchased_at >= per.since), 0)  as pengeluaran_bahan,
  coalesce((select sum(t.total) from transactions t where t.is_paid and coalesce(t.paid_at, t.created_at) >= per.since), 0)
   - coalesce((select sum(b.price) from purchases b where b.purchased_at >= per.since), 0) as laba_kotor
from periods per;

create or replace view report_daily with (security_invoker = true) as
select (coalesce(paid_at, created_at) at time zone 'Asia/Makassar')::date as tanggal,
       count(*)   as jumlah_transaksi,
       sum(total) as pendapatan
from transactions
where is_paid
group by 1
order by 1 desc;

create or replace view report_monthly with (security_invoker = true) as
with inc as (
  select date_trunc('month', coalesce(paid_at, created_at) at time zone 'Asia/Makassar')::date as bulan,
         count(*) as jumlah_transaksi, sum(total) as pendapatan
  from transactions where is_paid group by 1
), exp as (
  select date_trunc('month', purchased_at at time zone 'Asia/Makassar')::date as bulan,
         sum(price) as pengeluaran_bahan
  from purchases group by 1
)
select coalesce(inc.bulan, exp.bulan) as bulan,
       coalesce(inc.jumlah_transaksi, 0)  as jumlah_transaksi,
       coalesce(inc.pendapatan, 0)        as pendapatan,
       coalesce(exp.pengeluaran_bahan, 0) as pengeluaran_bahan,
       coalesce(inc.pendapatan, 0) - coalesce(exp.pengeluaran_bahan, 0) as laba_kotor
from inc full join exp on inc.bulan = exp.bulan
order by 1 desc;

create or replace view report_top_items with (security_invoker = true) as
select i.name, sum(i.qty) as terjual, sum(i.qty * i.price) as omzet
from transaction_items i
join transactions t on t.id = i.transaction_id
where t.is_paid
  and coalesce(t.paid_at, t.created_at) >= (date_trunc('month', now() at time zone 'Asia/Makassar')) at time zone 'Asia/Makassar'
group by i.name
order by terjual desc;

-- SELESAI. Lanjut jalankan migrasi-v2.sql.


-- =====================================================================
-- MIGRASI V2 (jalankan SETELAH database.sql / migrasi.sql yang lama)
-- Supabase Dashboard -> SQL Editor -> New query -> tempel -> Run.
-- Aman dijalankan berulang. Menambah:
--  1. Peran admin / manager
--  2. Resep menu (hanya admin)
--  3. Catatan per pesanan
--  4. Loyalitas member (nama / WA, poin, benefit)
--  5. Dukungan mode offline (anti-dobel + waktu asli transaksi)
-- =====================================================================

-- ---------- 1. PERAN ----------
alter table admins add column if not exists role text not null default 'admin';
alter table admins drop constraint if exists admins_role_chk;
alter table admins add constraint admins_role_chk check (role in ('admin','manager'));

-- is_admin() sekarang hanya role 'admin' (manager tidak bisa menulis/menghapus)
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from public.admins where user_id = auth.uid() and role = 'admin');
$fn$;
revoke all on function is_admin() from public;
grant execute on function is_admin() to anon, authenticated;

create or replace function is_staff() returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from public.admins where user_id = auth.uid() and role in ('admin','manager'));
$fn$;
revoke all on function is_staff() from public;
grant execute on function is_staff() to anon, authenticated;

-- Manager boleh MEMBACA pembukuan (tidak boleh menulis)
drop policy if exists "baca_staff" on cash_entries;
create policy "baca_staff" on cash_entries for select to authenticated using (is_staff());

-- Cara menjadikan seseorang manager (ganti emailnya):
--   insert into admins (user_id, role)
--   select id, 'manager' from auth.users where email = 'manager@contoh.com'
--   on conflict (user_id) do update set role = 'manager';

-- ---------- 2. RESEP (hanya admin) ----------
create table if not exists recipes (
  id          bigint generated always as identity primary key,
  menu_id     bigint not null unique references menu_items(id) on delete cascade,
  ingredients text,
  steps       text,
  updated_at  timestamptz not null default now()
);
alter table recipes enable row level security;
drop policy if exists "resep_admin" on recipes;
create policy "resep_admin" on recipes for all to authenticated
  using (is_admin()) with check (is_admin());

-- ---------- 4a. TABEL LOYALITAS ----------
alter table shop_settings add column if not exists loyalty jsonb not null default '{}'::jsonb;

create table if not exists customers (
  id              bigint generated always as identity primary key,
  name            text not null,
  phone           text,
  points          int not null default 0,
  lifetime_points int not null default 0,
  created_at      timestamptz not null default now()
);
create unique index if not exists customers_phone_uq on customers (phone) where phone is not null;

create table if not exists loyalty_log (
  id             bigint generated always as identity primary key,
  customer_id    bigint not null references customers(id) on delete cascade,
  transaction_id bigint references transactions(id) on delete set null,
  delta          int not null,
  reason         text,
  cashier        text,
  created_at     timestamptz not null default now()
);
create index if not exists loyalty_log_cust_idx on loyalty_log (customer_id, created_at desc);

alter table customers   enable row level security;
alter table loyalty_log enable row level security;
drop policy if exists "tulis_admin" on customers;
drop policy if exists "baca_staff"  on customers;
drop policy if exists "tulis_admin" on loyalty_log;
drop policy if exists "baca_staff"  on loyalty_log;
create policy "tulis_admin" on customers   for all to authenticated using (is_admin()) with check (is_admin());
create policy "baca_staff"  on customers   for select to authenticated using (is_staff());
create policy "tulis_admin" on loyalty_log for all to authenticated using (is_admin()) with check (is_admin());
create policy "baca_staff"  on loyalty_log for select to authenticated using (is_staff());

-- ---------- 3 + 4b + 5. KOLOM TRANSAKSI ----------
alter table transactions add column if not exists note          text;
alter table transactions add column if not exists customer_id   bigint references customers(id) on delete set null;
alter table transactions add column if not exists points_earned int not null default 0;
alter table transactions add column if not exists client_id     text;
create unique index if not exists transactions_client_uq on transactions (client_id) where client_id is not null;

-- ---------- FUNGSI LOYALITAS ----------
create or replace function norm_phone(p text) returns text
language sql immutable as $fn$
  select case when d = '' then null
              when d like '0%' then '62' || substr(d, 2)
              when d like '8%'  then '62' || d
              else d end
  from (select regexp_replace(coalesce(p,''), '\D', '', 'g') as d) s;
$fn$;

create or replace function mask_phone(p text) returns text
language sql immutable as $fn$
  select case when p is null then null when length(p) < 7 then p
              else left(p, 4) || '****' || right(p, 2) end;
$fn$;

-- Pencarian member. Kasir tanpa login: minimal 3 huruf nama / 6 digit WA, nomor disamarkan.
create or replace function cari_member(p_q text)
returns table (id bigint, name text, phone text, points int, lifetime_points int, created_at timestamptz)
language plpgsql security definer set search_path = public as $fn$
declare q text := trim(coalesce(p_q,'')); ph text := norm_phone(trim(coalesce(p_q,''))); st boolean := is_staff();
begin
  if not st and length(q) < 3 then return; end if;
  return query
    select c.id, c.name, case when st then c.phone else mask_phone(c.phone) end,
           c.points, c.lifetime_points, c.created_at
    from customers c
    where q = ''
       or c.name ilike '%' || q || '%'
       or (ph is not null and length(ph) >= (case when st then 4 else 6 end) and c.phone like '%' || ph || '%')
    order by c.points desc, c.name
    limit 50;
end $fn$;
revoke all on function cari_member(text) from public;
grant execute on function cari_member(text) to anon, authenticated;

create or replace function daftar_member(p_name text, p_phone text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  ph text := norm_phone(p_phone); nm text := nullif(trim(coalesce(p_name,'')), '');
  cfg jsonb := coalesce((select loyalty from shop_settings where id = 1), '{}'::jsonb);
  bonus int := 0; c customers;
begin
  if nm is null and ph is null then raise exception 'Isi nama atau nomor WA'; end if;
  if ph is not null and length(ph) < 8 then raise exception 'Nomor WA terlalu pendek'; end if;
  if ph is not null and exists (select 1 from customers where phone = ph) then
    raise exception 'Nomor WA sudah terdaftar. Cari dengan nomor itu.';
  end if;
  if nm is null then nm := 'Member ' || right(ph, 4); end if;
  if coalesce((cfg->>'enabled')::boolean, false) then bonus := coalesce((cfg->>'welcome')::int, 0); end if;
  insert into customers (name, phone, points, lifetime_points) values (nm, ph, bonus, bonus) returning * into c;
  if bonus > 0 then insert into loyalty_log (customer_id, delta, reason) values (c.id, bonus, 'Bonus member baru'); end if;
  return jsonb_build_object('id', c.id, 'name', c.name, 'phone', mask_phone(c.phone), 'points', c.points, 'welcome', bonus);
end $fn$;
revoke all on function daftar_member(text, text) from public;
grant execute on function daftar_member(text, text) to anon, authenticated;

-- Beri poin untuk transaksi yang sudah dibayar (idempoten). Dipanggil internal saja.
create or replace function award_points(p_trx_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare t transactions; cfg jsonb; per numeric; pts int := 0; c customers;
begin
  select * into t from transactions where id = p_trx_id;
  if not found or t.customer_id is null or not t.is_paid or t.points_earned > 0 then return null; end if;
  cfg := coalesce((select loyalty from shop_settings where id = 1), '{}'::jsonb);
  if coalesce((cfg->>'enabled')::boolean, false) then
    per := coalesce(nullif((cfg->>'rp_per_point')::numeric, 0), 10000);
    pts := floor(t.total / per)::int;
  end if;
  if pts > 0 then
    update customers set points = points + pts, lifetime_points = lifetime_points + pts
      where id = t.customer_id returning * into c;
    update transactions set points_earned = pts where id = t.id;
    insert into loyalty_log (customer_id, transaction_id, delta, reason)
      values (t.customer_id, t.id, pts, 'Belanja ' || t.invoice_no);
  else
    select * into c from customers where id = t.customer_id;
  end if;
  return jsonb_build_object('name', c.name, 'earned', pts, 'total', c.points);
end $fn$;
revoke all on function award_points(bigint) from public;

create or replace function tukar_poin(p_customer_id bigint, p_idx int, p_cashier text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare cfg jsonb; b jsonb; cost int; c customers;
begin
  if not exists (select 1 from cashiers where name = p_cashier and is_active) then
    raise exception 'Kasir tidak dikenal';
  end if;
  cfg := coalesce((select loyalty from shop_settings where id = 1), '{}'::jsonb);
  if not coalesce((cfg->>'enabled')::boolean, false) then raise exception 'Loyalitas tidak aktif'; end if;
  b := cfg->'benefits'->p_idx;
  if b is null then raise exception 'Benefit tidak ditemukan'; end if;
  cost := (b->>'cost')::int;
  select * into c from customers where id = p_customer_id for update;
  if not found then raise exception 'Member tidak ditemukan'; end if;
  if c.points < cost then raise exception 'Poin tidak cukup'; end if;
  update customers set points = points - cost where id = c.id returning * into c;
  insert into loyalty_log (customer_id, delta, reason, cashier)
    values (c.id, -cost, 'Tukar: ' || (b->>'name'), p_cashier);
  return jsonb_build_object('name', c.name, 'benefit', b->>'name', 'cost', cost, 'points', c.points);
end $fn$;
revoke all on function tukar_poin(bigint, int, text) from public;
grant execute on function tukar_poin(bigint, int, text) to anon, authenticated;

-- ---------- TRANSAKSI (catatan, member, anti-dobel offline) ----------
drop function if exists buat_transaksi(jsonb, text, numeric, text, text, text, boolean);
create or replace function buat_transaksi(
  p_items jsonb, p_method text, p_paid numeric, p_cashier text, p_proof text,
  p_customer text default null, p_is_paid boolean default true,
  p_note text default null, p_customer_id bigint default null,
  p_client_id text default null, p_at timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_total numeric := 0; v_day text; v_n int; v_inv text; v_at timestamptz;
  v_trx transactions; v_items jsonb; it jsonb; m menu_items%rowtype; q int;
  v_cust text := nullif(trim(coalesce(p_customer,'')), '');
  v_note text := nullif(left(trim(coalesce(p_note,'')), 200), '');
  v_mem customers; v_info jsonb;
begin
  -- pengiriman ulang dari antrean offline: kembalikan transaksi yang sudah ada
  if p_client_id is not null then
    select * into v_trx from transactions where client_id = p_client_id;
    if found then
      select jsonb_agg(jsonb_build_object('name', name, 'price', price, 'qty', qty)) into v_items
        from transaction_items where transaction_id = v_trx.id;
      return to_jsonb(v_trx) || jsonb_build_object('transaction_items', coalesce(v_items,'[]'::jsonb), 'member_info', null);
    end if;
  end if;

  if p_customer_id is not null then
    select * into v_mem from customers where id = p_customer_id;
    if not found then raise exception 'Member tidak ditemukan'; end if;
    if v_cust is null then v_cust := v_mem.name; end if;
  end if;

  if p_is_paid and p_method not in ('Tunai','QRIS') then raise exception 'Metode pembayaran tidak valid'; end if;
  if not p_is_paid and v_cust is null then raise exception 'Nama pemesan wajib untuk pesanan bayar nanti'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Pesanan kosong';
  end if;
  if not exists (select 1 from cashiers where name = p_cashier and is_active) then
    raise exception 'Kasir tidak dikenal';
  end if;

  for it in select * from jsonb_array_elements(p_items) loop
    q := (it->>'qty')::int;
    select * into m from menu_items where id = (it->>'id')::bigint and is_active;
    if not found or q is null or q <= 0 then raise exception 'Item pesanan tidak valid'; end if;
    v_total := v_total + m.price * q;
  end loop;

  if p_is_paid and p_method = 'Tunai' and coalesce(p_paid, 0) < v_total then
    raise exception 'Uang diterima kurang dari total';
  end if;
  if p_is_paid and p_method = 'QRIS' and (p_proof is null or p_proof !~ '^[0-9]{8}/[0-9]+\.jpg$') then
    raise exception 'Foto bukti QRIS wajib';
  end if;

  -- waktu asli transaksi (untuk yang dibuat saat offline), maksimal 3 hari ke belakang
  v_at := case when p_at is not null and p_at <= now() and p_at > now() - interval '3 days' then p_at else now() end;

  perform pg_advisory_xact_lock(hashtext('invoice_no'));
  v_day := to_char(v_at at time zone 'Asia/Makassar', 'YYYYMMDD');
  select coalesce(max(substring(invoice_no from '-([0-9]+)$')::int), 0) + 1 into v_n
    from transactions where invoice_no like 'INV-' || v_day || '-%';
  v_inv := 'INV-' || v_day || '-' || lpad(v_n::text, 3, '0');

  insert into transactions (invoice_no, created_at, method, total, paid, change_amount, proof_path,
                            cashier_name, customer_name, is_paid, paid_at, is_made,
                            note, customer_id, client_id)
  values (v_inv, v_at,
          case when p_is_paid then p_method end,
          v_total,
          case when not p_is_paid then 0 when p_method = 'QRIS' then v_total else p_paid end,
          case when not p_is_paid or p_method = 'QRIS' then 0 else p_paid - v_total end,
          case when p_is_paid then p_proof end,
          p_cashier, v_cust, p_is_paid,
          case when p_is_paid then v_at end,
          false, v_note, p_customer_id, p_client_id)
  returning * into v_trx;

  insert into transaction_items (transaction_id, menu_item_id, name, price, qty)
  select v_trx.id, mi.id, mi.name, mi.price, (e->>'qty')::int
    from jsonb_array_elements(p_items) e
    join menu_items mi on mi.id = (e->>'id')::bigint;

  if p_is_paid and p_customer_id is not null then
    v_info := award_points(v_trx.id);
    select * into v_trx from transactions where id = v_trx.id;
  end if;

  select jsonb_agg(jsonb_build_object('name', name, 'price', price, 'qty', qty)) into v_items
    from transaction_items where transaction_id = v_trx.id;

  return to_jsonb(v_trx) || jsonb_build_object('transaction_items', coalesce(v_items,'[]'::jsonb), 'member_info', v_info);
end $fn$;
revoke all on function buat_transaksi(jsonb, text, numeric, text, text, text, boolean, text, bigint, text, timestamptz) from public;
grant execute on function buat_transaksi(jsonb, text, numeric, text, text, text, boolean, text, bigint, text, timestamptz) to anon, authenticated;

create or replace function bayar_transaksi(
  p_id bigint, p_method text, p_paid numeric, p_proof text
) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_trx transactions; v_items jsonb; v_info jsonb;
begin
  select * into v_trx from transactions where id = p_id for update;
  if not found then raise exception 'Transaksi tidak ditemukan'; end if;
  if v_trx.is_paid then raise exception 'Pesanan ini sudah dibayar'; end if;
  if p_method not in ('Tunai','QRIS') then raise exception 'Metode pembayaran tidak valid'; end if;
  if p_method = 'Tunai' and coalesce(p_paid, 0) < v_trx.total then
    raise exception 'Uang diterima kurang dari total';
  end if;
  if p_method = 'QRIS' and (p_proof is null or p_proof !~ '^[0-9]{8}/[0-9]+\.jpg$') then
    raise exception 'Foto bukti QRIS wajib';
  end if;

  update transactions set
    method = p_method, is_paid = true, paid_at = now(),
    paid = case when p_method = 'QRIS' then total else p_paid end,
    change_amount = case when p_method = 'QRIS' then 0 else p_paid - total end,
    proof_path = case when p_method = 'QRIS' then p_proof end
  where id = p_id;

  if v_trx.customer_id is not null then v_info := award_points(p_id); end if;
  select * into v_trx from transactions where id = p_id;

  select jsonb_agg(jsonb_build_object('name', name, 'price', price, 'qty', qty)) into v_items
    from transaction_items where transaction_id = v_trx.id;
  return to_jsonb(v_trx) || jsonb_build_object('transaction_items', coalesce(v_items,'[]'::jsonb), 'member_info', v_info);
end $fn$;
revoke all on function bayar_transaksi(bigint, text, numeric, text) from public;
grant execute on function bayar_transaksi(bigint, text, numeric, text) to anon, authenticated;

-- SELESAI.


-- =====================================================================
-- MIGRASI V3 - LOGIN STAF (KASIR) TERPISAH DARI OWNER
-- Jalankan SETELAH semua migrasi di atas. Aman dijalankan berulang.
--
-- LANGKAH WAJIB SEBELUM MENJALANKAN:
--   Supabase Dashboard -> Authentication -> Users -> Add user
--   email: myeverast@gmail.com , isi password, centang Auto Confirm User.
--   (Password tidak bisa dibuat lewat SQL ini.)
--
-- Peran:  admin (owner) | manager | kasir
--   kasir   : Kasir, Bazar, Antrian, Member, Riwayat
--   manager : + Bahan, Laporan, Pembukuan (hanya baca)
--   owner   : semua, termasuk Menu, Resep, Pengaturan
-- =====================================================================

-- 1. izinkan peran 'kasir'
alter table admins drop constraint if exists admins_role_chk;
alter table admins add constraint admins_role_chk check (role in ('admin','manager','kasir'));

-- 2. daftarkan myeverast@gmail.com sebagai kasir (tidak menurunkan owner/manager)
insert into admins (user_id, role)
select id, 'kasir' from auth.users where email = 'myeverast@gmail.com'
on conflict (user_id) do nothing;

-- 3. fungsi cek: akun terdaftar sebagai staf apa pun (owner/manager/kasir)
create or replace function is_cashier() returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from public.admins where user_id = auth.uid());
$fn$;
revoke all on function is_cashier() from public;
grant execute on function is_cashier() to authenticated;

-- 4. KUNCI fungsi transaksi: tamu (anon) tidak boleh memanggil lagi
revoke execute on function buat_transaksi(jsonb, text, numeric, text, text, text, boolean, text, bigint, text, timestamptz) from anon;
revoke execute on function bayar_transaksi(bigint, text, numeric, text) from anon;
revoke execute on function ubah_status_pesanan(bigint, boolean) from anon;
revoke execute on function cari_member(text) from anon;
revoke execute on function daftar_member(text, text) from anon;
revoke execute on function tukar_poin(bigint, int, text) from anon;
grant execute on function buat_transaksi(jsonb, text, numeric, text, text, text, boolean, text, bigint, text, timestamptz) to authenticated;
grant execute on function bayar_transaksi(bigint, text, numeric, text) to authenticated;
grant execute on function ubah_status_pesanan(bigint, boolean) to authenticated;
grant execute on function cari_member(text) to authenticated;
grant execute on function daftar_member(text, text) to authenticated;
grant execute on function tukar_poin(bigint, int, text) to authenticated;

-- Cek hasil:  select u.email, a.role from admins a join auth.users u on u.id = a.user_id;
