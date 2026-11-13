-- =====================================================================
-- DATABASE KASIR COFFEE SHOP (Supabase / PostgreSQL)
-- Cara pakai: Supabase Dashboard -> SQL Editor -> New query -> tempel
-- seluruh isi file ini -> Run.
-- Zona waktu laporan: Asia/Makassar (WITA, Tarakan). Ganti jika perlu.
-- =====================================================================

-- ---------- 1. TABEL ----------

-- Pengaturan kedai (hanya 1 baris)
create table if not exists shop_settings (
  id          int primary key default 1 check (id = 1),
  shop_name   text not null default 'Kasir Coffee Shop',
  qris_path   text,                       -- path gambar QRIS di bucket "shop"
  logo_path   text,                       -- path logo kustom di bucket "shop" (kosong = logo bawaan)
  theme       jsonb not null default '{}'::jsonb,  -- pengaturan tampilan (warna, mode, ukuran, dll)
  updated_at  timestamptz not null default now()
);
insert into shop_settings (id) values (1) on conflict do nothing;

-- Daftar menu
create table if not exists menu_items (
  id          bigint generated always as identity primary key,
  name        text    not null,
  category    text    not null default 'Lainnya',
  price       numeric(12,0) not null check (price >= 0),
  is_active   boolean not null default true,   -- false = disembunyikan, riwayat tetap aman
  created_at  timestamptz not null default now()
);
create index if not exists menu_items_category_idx on menu_items (category);

-- Daftar kasir (dipilih lewat tombol saat transaksi, tidak diketik)
create table if not exists cashiers (
  id          bigint generated always as identity primary key,
  name        text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

-- Transaksi penjualan
create table if not exists transactions (
  id            bigint generated always as identity primary key,
  invoice_no    text not null unique,            -- contoh: INV-20261114-001
  created_at    timestamptz not null default now(),
  method        text not null check (method in ('Tunai','QRIS')),
  total         numeric(12,0) not null check (total >= 0),
  paid          numeric(12,0) not null check (paid >= 0),
  change_amount numeric(12,0) not null default 0 check (change_amount >= 0),
  proof_path    text,                            -- path foto bukti di bucket "payment-proofs"
  cashier_name  text,                            -- nama kasir yang melayani (disalin agar riwayat aman)
  -- transaksi QRIS wajib punya foto bukti
  constraint qris_needs_proof check (method <> 'QRIS' or proof_path is not null)
);
create index if not exists transactions_created_idx on transactions (created_at desc);

-- Isi tiap transaksi (nama dan harga disalin agar riwayat tidak berubah saat menu diubah)
create table if not exists transaction_items (
  id              bigint generated always as identity primary key,
  transaction_id  bigint not null references transactions(id) on delete cascade,
  menu_item_id    bigint references menu_items(id) on delete set null,
  name            text not null,
  price           numeric(12,0) not null check (price >= 0),
  qty             int not null check (qty > 0)
);
create index if not exists transaction_items_trx_idx on transaction_items (transaction_id);

-- Nota belanja bahan (1 nota = 1 hari/1 kali belanja, isinya banyak bahan)
create table if not exists purchase_notes (
  id            bigint generated always as identity primary key,
  purchased_at  timestamptz not null default now(),
  note          text,                            -- catatan/toko (opsional)
  created_at    timestamptz not null default now()
);
create index if not exists purchase_notes_date_idx on purchase_notes (purchased_at desc);

-- Isi nota: tiap baris = 1 bahan. price = TOTAL baris (qty x unit_price),
-- sehingga view laporan di bawah tetap bekerja tanpa perubahan.
create table if not exists purchases (
  id            bigint generated always as identity primary key,
  note_id       bigint references purchase_notes(id) on delete cascade,  -- kosong = catatan lama
  name          text not null,
  unit          text,                            -- satuan: kg, liter, pcs, ...
  qty           numeric(12,3),                   -- jumlah dibeli
  unit_price    numeric(12,0),                   -- harga per satuan
  quantity_note text,                            -- teks ringkas, contoh: "5 kg"
  price         numeric(12,0) not null check (price >= 0),   -- total baris
  purchased_at  timestamptz not null default now(),
  created_at    timestamptz not null default now()
);
create index if not exists purchases_date_idx on purchases (purchased_at desc);
create index if not exists purchases_note_idx on purchases (note_id);

-- ---------- 2. DATA AWAL (contoh menu, boleh dihapus) ----------
insert into menu_items (name, category, price)
select * from (values
  ('Espresso','Kopi',15000),
  ('Americano','Kopi',18000),
  ('Cafe Latte','Kopi',25000),
  ('Kopi Susu Gula Aren','Kopi',22000),
  ('Matcha Latte','Non-kopi',27000),
  ('Coklat Panas','Non-kopi',22000),
  ('Croissant','Makanan',20000),
  ('Roti Bakar Coklat','Makanan',18000)
) as v(name, category, price)
where not exists (select 1 from menu_items);

-- ---------- 3. VIEW LAPORAN ----------
-- security_invoker: view mengikuti aturan akses (RLS) si pemanggil.

-- Pendapatan, pengeluaran, laba: hari ini / minggu ini / bulan ini / tahun ini / semua
create or replace view report_summary with (security_invoker = true) as
with p as (
  select
    (date_trunc('day',   now() at time zone 'Asia/Makassar')) at time zone 'Asia/Makassar' as d,
    (date_trunc('week',  now() at time zone 'Asia/Makassar')) at time zone 'Asia/Makassar' as w,  -- minggu mulai Senin
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
  coalesce((select count(*) from transactions t where t.created_at >= per.since), 0)  as jumlah_transaksi,
  coalesce((select sum(t.total) from transactions t where t.created_at >= per.since), 0) as pendapatan,
  coalesce((select sum(b.price) from purchases b where b.purchased_at >= per.since), 0)  as pengeluaran_bahan,
  coalesce((select sum(t.total) from transactions t where t.created_at >= per.since), 0)
   - coalesce((select sum(b.price) from purchases b where b.purchased_at >= per.since), 0) as laba_kotor
from periods per;

-- Pendapatan per hari
create or replace view report_daily with (security_invoker = true) as
select (created_at at time zone 'Asia/Makassar')::date as tanggal,
       count(*)   as jumlah_transaksi,
       sum(total) as pendapatan
from transactions
group by 1
order by 1 desc;

-- Pendapatan, pengeluaran, laba per bulan
create or replace view report_monthly with (security_invoker = true) as
with inc as (
  select date_trunc('month', created_at at time zone 'Asia/Makassar')::date as bulan,
         count(*) as jumlah_transaksi, sum(total) as pendapatan
  from transactions group by 1
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

-- Menu terlaris
create or replace view report_top_items with (security_invoker = true) as
select i.name, sum(i.qty) as terjual, sum(i.qty * i.price) as omzet
from transaction_items i
join transactions t on t.id = i.transaction_id
where t.created_at >= (date_trunc('month', now() at time zone 'Asia/Makassar')) at time zone 'Asia/Makassar'
group by i.name
order by terjual desc;

-- ---------- 4. KEAMANAN (Row Level Security) ----------
-- Admin = akun login (Authentication -> Users -> Add user). Kasir = tanpa login,
-- aksesnya dibatasi ketat (lihat bagian MODE ADMIN + KASIR TANPA LOGIN di bawah).

alter table shop_settings     enable row level security;
alter table menu_items        enable row level security;
alter table transactions      enable row level security;
alter table transaction_items enable row level security;
alter table purchases         enable row level security;
alter table purchase_notes    enable row level security;
alter table cashiers          enable row level security;

-- (aturan akses per tabel ada di bagian MODE ADMIN di bawah)

-- ---------- 5. PENYIMPANAN FOTO (Storage) ----------
-- payment-proofs : foto bukti transaksi (privat)
-- shop           : gambar QRIS (privat)
insert into storage.buckets (id, name, public)
values ('payment-proofs', 'payment-proofs', false),
       ('shop',           'shop',           false)
on conflict (id) do nothing;

-- (aturan akses foto ada di bagian MODE ADMIN di bawah)

-- =====================================================================
-- MODE ADMIN + KASIR TANPA LOGIN
-- * Kasir: buka aplikasi langsung, tanpa akun. Hanya bisa memakai halaman
--   Kasir (lihat menu, pilih kasir, bayar). Tidak bisa melihat riwayat,
--   laporan, belanja bahan, atau mengubah apa pun.
-- * Admin: login email + kata sandi. Akun yang terdaftar di tabel "admins"
--   bisa semuanya: riwayat (termasuk hapus), menu, bahan, laporan, pengaturan.
-- Aturan dijaga di database (RLS), bukan hanya disembunyikan di tampilan.
-- =====================================================================
create table if not exists admins (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);
alter table admins enable row level security;
drop policy if exists "admin_baca_diri" on admins;
create policy "admin_baca_diri" on admins for select to authenticated
  using (user_id = auth.uid());

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from public.admins where user_id = auth.uid());
$fn$;
revoke all on function is_admin() from public;
grant execute on function is_admin() to anon, authenticated;

-- Semua akun yang SUDAH ada saat file ini dijalankan dijadikan admin.
-- (Instalasi baru: buat akun admin dulu di Authentication -> Users,
--  lalu jalankan lagi baris insert di bawah ini.)
insert into admins (user_id) select id from auth.users on conflict do nothing;

-- Bersihkan aturan lama pada tabel data, lalu pasang aturan baru
do $$
declare r record; t text;
begin
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public'
             and tablename in ('shop_settings','menu_items','cashiers','transactions','transaction_items','purchases','purchase_notes')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;

  -- hanya ADMIN yang boleh membaca dan menulis semua tabel
  foreach t in array array['shop_settings','menu_items','cashiers','transactions','transaction_items','purchases','purchase_notes']
  loop
    execute format('create policy "tulis_admin" on %I for all to authenticated using (is_admin()) with check (is_admin())', t);
  end loop;

  -- yang boleh DIBACA kasir tanpa login: menu, nama kedai/QRIS/tema, daftar kasir
  foreach t in array array['shop_settings','menu_items','cashiers']
  loop
    execute format('create policy "baca_publik" on %I for select to anon, authenticated using (true)', t);
  end loop;
end $$;

-- Transaksi dibuat lewat fungsi ini (kasir tanpa login memanggilnya).
-- Total dihitung ulang dari harga menu di database, jadi tidak bisa dipalsukan.
create or replace function buat_transaksi(
  p_items jsonb, p_method text, p_paid numeric, p_cashier text, p_proof text
) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_total numeric := 0; v_day text; v_n int; v_inv text;
  v_trx transactions; v_items jsonb; it jsonb; m menu_items%rowtype; q int;
begin
  if p_method not in ('Tunai','QRIS') then raise exception 'Metode pembayaran tidak valid'; end if;
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

  if p_method = 'Tunai' and coalesce(p_paid, 0) < v_total then
    raise exception 'Uang diterima kurang dari total';
  end if;
  if p_method = 'QRIS' and (p_proof is null or p_proof !~ '^[0-9]{8}/[0-9]+\.jpg$') then
    raise exception 'Foto bukti QRIS wajib';
  end if;

  perform pg_advisory_xact_lock(hashtext('invoice_no'));
  v_day := to_char(now() at time zone 'Asia/Makassar', 'YYYYMMDD');
  select coalesce(max(substring(invoice_no from '-([0-9]+)$')::int), 0) + 1 into v_n
    from transactions where invoice_no like 'INV-' || v_day || '-%';
  v_inv := 'INV-' || v_day || '-' || lpad(v_n::text, 3, '0');

  insert into transactions (invoice_no, method, total, paid, change_amount, proof_path, cashier_name)
  values (v_inv, p_method, v_total,
          case when p_method = 'QRIS' then v_total else p_paid end,
          case when p_method = 'QRIS' then 0 else p_paid - v_total end,
          p_proof, p_cashier)
  returning * into v_trx;

  insert into transaction_items (transaction_id, menu_item_id, name, price, qty)
  select v_trx.id, mi.id, mi.name, mi.price, (e->>'qty')::int
    from jsonb_array_elements(p_items) e
    join menu_items mi on mi.id = (e->>'id')::bigint;

  select jsonb_agg(jsonb_build_object('name', name, 'price', price, 'qty', qty)) into v_items
    from transaction_items where transaction_id = v_trx.id;

  return to_jsonb(v_trx) || jsonb_build_object('transaction_items', coalesce(v_items, '[]'::jsonb));
end $fn$;
revoke all on function buat_transaksi(jsonb, text, numeric, text, text) from public;
grant execute on function buat_transaksi(jsonb, text, numeric, text, text) to anon, authenticated;

-- Foto: kasir tanpa login hanya boleh melihat QRIS/logo (bucket "shop") dan
-- mengunggah bukti QRIS (JPEG kecil, nama file berpola tanggal).
-- Selain itu hanya admin.
update storage.buckets
   set file_size_limit = 3145728, allowed_mime_types = array['image/jpeg']
 where id = 'payment-proofs';

drop policy if exists "storage_akses_login" on storage.objects;
drop policy if exists "storage_baca" on storage.objects;
drop policy if exists "storage_baca_shop" on storage.objects;
drop policy if exists "storage_bukti_tambah" on storage.objects;
drop policy if exists "storage_admin" on storage.objects;
create policy "storage_baca_shop" on storage.objects for select to anon, authenticated
  using (bucket_id = 'shop');
create policy "storage_bukti_tambah" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'payment-proofs' and name ~ '^[0-9]{8}/[0-9]+\.jpg$');
create policy "storage_admin" on storage.objects for all to authenticated
  using (bucket_id in ('payment-proofs','shop') and is_admin())
  with check (bucket_id in ('payment-proofs','shop') and is_admin());

-- =====================================================================
-- SELESAI. Contoh pengecekan:
--   select * from report_summary;
--   select * from report_monthly;
-- =====================================================================
