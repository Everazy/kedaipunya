-- =====================================================================
-- MIGRASI untuk database yang SUDAH berjalan (data lama tetap aman).
-- Supabase Dashboard -> SQL Editor -> New query -> tempel -> Run.
-- Aman dijalankan berulang kali.
-- (Instalasi baru dari nol: cukup jalankan database.sql, tidak perlu file ini.)
-- =====================================================================

-- 1. Pengaturan tampilan + logo
alter table shop_settings add column if not exists logo_path text;
alter table shop_settings add column if not exists theme jsonb not null default '{}'::jsonb;

-- 2. Kasir
create table if not exists cashiers (
  id          bigint generated always as identity primary key,
  name        text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
alter table transactions add column if not exists cashier_name text;

-- 3. Nota belanja bahan
create table if not exists purchase_notes (
  id            bigint generated always as identity primary key,
  purchased_at  timestamptz not null default now(),
  note          text,
  created_at    timestamptz not null default now()
);
create index if not exists purchase_notes_date_idx on purchase_notes (purchased_at desc);

alter table purchases add column if not exists note_id    bigint references purchase_notes(id) on delete cascade;
alter table purchases add column if not exists unit       text;
alter table purchases add column if not exists qty        numeric(12,3);
alter table purchases add column if not exists unit_price numeric(12,0);
create index if not exists purchases_note_idx on purchases (note_id);

-- 4. Keamanan (RLS) untuk tabel baru
alter table purchase_notes enable row level security;
alter table cashiers       enable row level security;
do $$
declare t text;
begin
  foreach t in array array['purchase_notes','cashiers']
  loop
    execute format('drop policy if exists "akses_login" on %I', t);
    execute format(
      'create policy "akses_login" on %I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

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

-- SELESAI. Pembelian lama (sebelum migrasi) tetap tampil sebagai "catatan lama".
-- Mode admin aktif: akun yang sudah ada = admin; kasir memakai aplikasi tanpa login.
