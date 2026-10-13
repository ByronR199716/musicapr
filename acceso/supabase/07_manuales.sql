-- =====================================================================
--  07 · Manuales de instalación (pestaña "Manuales" del panel)
--
--  El admin sube PDFs; admin y revendedores los ven y descargan.
--  - Archivos en Storage, bucket público "manuales" (solo PDF, máx. 20 MB):
--    un manual no es secreto y así el enlace se le puede pasar al cliente.
--    Solo el admin puede subir, cambiar o borrar archivos.
--  - Tabla public.manuals con título y servicio de cada manual.
--  Se puede ejecutar más de una vez.
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('manuales', 'manuales', true, 20971520, array['application/pdf'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "manuales: admin lista" on storage.objects;
drop policy if exists "manuales: admin sube" on storage.objects;
drop policy if exists "manuales: admin cambia" on storage.objects;
drop policy if exists "manuales: admin borra" on storage.objects;

create policy "manuales: admin lista" on storage.objects for select to authenticated
  using (bucket_id = 'manuales' and public.is_admin());
create policy "manuales: admin sube" on storage.objects for insert to authenticated
  with check (bucket_id = 'manuales' and public.is_admin());
create policy "manuales: admin cambia" on storage.objects for update to authenticated
  using (bucket_id = 'manuales' and public.is_admin())
  with check (bucket_id = 'manuales' and public.is_admin());
create policy "manuales: admin borra" on storage.objects for delete to authenticated
  using (bucket_id = 'manuales' and public.is_admin());

create table if not exists public.manuals (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (char_length(trim(title)) between 1 and 120),
  service_id  text references public.services(id) on delete set null,
  file_path   text not null unique,
  file_name   text not null,
  size_bytes  bigint,
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid()
);

alter table public.manuals enable row level security;

drop policy if exists manuals_read on public.manuals;
drop policy if exists manuals_admin_insert on public.manuals;
drop policy if exists manuals_admin_update on public.manuals;
drop policy if exists manuals_admin_delete on public.manuals;

create policy manuals_read on public.manuals for select to authenticated
  using (public.is_admin() or public.is_reseller());
create policy manuals_admin_insert on public.manuals for insert to authenticated
  with check (public.is_admin());
create policy manuals_admin_update on public.manuals for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy manuals_admin_delete on public.manuals for delete to authenticated
  using (public.is_admin());

grant select, insert, update, delete on public.manuals to authenticated;
revoke all on public.manuals from anon;
