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

-- Pembelian bahan
create table if not exists purchases (
  id            bigint generated always as identity primary key,
  name          text not null,
  quantity_note text,                            -- contoh: "5 kg"
  price         numeric(12,0) not null check (price >= 0),
  purchased_at  timestamptz not null default now(),
  created_at    timestamptz not null default now()
);
create index if not exists purchases_date_idx on purchases (purchased_at desc);

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
-- Hanya pengguna yang sudah LOGIN (akun kasir/pemilik) yang boleh membaca dan menulis.
-- Pengunjung anonim tidak punya akses sama sekali.
-- Buat akun di: Authentication -> Users -> Add user.

alter table shop_settings     enable row level security;
alter table menu_items        enable row level security;
alter table transactions      enable row level security;
alter table transaction_items enable row level security;
alter table purchases         enable row level security;

do $$
declare t text;
begin
  foreach t in array array['shop_settings','menu_items','transactions','transaction_items','purchases']
  loop
    execute format('drop policy if exists "akses_login" on %I', t);
    execute format(
      'create policy "akses_login" on %I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

-- ---------- 5. PENYIMPANAN FOTO (Storage) ----------
-- payment-proofs : foto bukti transaksi (privat)
-- shop           : gambar QRIS (privat)
insert into storage.buckets (id, name, public)
values ('payment-proofs', 'payment-proofs', false),
       ('shop',           'shop',           false)
on conflict (id) do nothing;

drop policy if exists "storage_akses_login" on storage.objects;
create policy "storage_akses_login" on storage.objects
  for all to authenticated
  using      (bucket_id in ('payment-proofs','shop'))
  with check (bucket_id in ('payment-proofs','shop'));

-- =====================================================================
-- SELESAI. Contoh pengecekan:
--   select * from report_summary;
--   select * from report_monthly;
-- =====================================================================
