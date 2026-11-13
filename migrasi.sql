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

-- SELESAI. Pembelian lama (sebelum migrasi) tetap tampil sebagai "catatan lama".
