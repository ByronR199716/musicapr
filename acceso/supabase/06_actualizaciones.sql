-- Actualizaciones dentro de las apps (2026-10-09).
--
-- Cada app, al abrir, pregunta get_app_update(servicio, plataforma). Si la versión
-- instalada es menor que version_code, muestra "Hay una nueva versión"; si es menor que
-- min_version_code, la actualización es obligatoria.
--
-- Números de versión: todas las apps compilan en GitHub con versionCode = 100 + N,
-- donde N es el número de la compilación (release "build-N").
-- version_code = 0 apaga el aviso para esa app.

create table if not exists public.app_releases (
  service_id       text not null references public.services(id) on delete cascade,
  platform         text not null check (platform in ('android', 'tv', 'pc')),
  version_code     integer not null default 0 check (version_code >= 0),
  min_version_code integer not null default 0 check (min_version_code >= 0),
  download_url     text,
  notes            text,
  github_repo      text,
  updated_at       timestamptz not null default now(),
  primary key (service_id, platform)
);

alter table public.app_releases enable row level security;

drop policy if exists admin_all on public.app_releases;
create policy admin_all on public.app_releases for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create or replace function public.get_app_update(p_service text, p_platform text default 'android')
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select jsonb_build_object(
              'version_code', r.version_code,
              'min_version_code', r.min_version_code,
              'url', r.download_url,
              'notes', coalesce(r.notes, ''))
       from public.app_releases r
      where r.service_id = p_service
        and r.platform = p_platform
        and r.version_code > 0
        and coalesce(r.download_url, '') <> ''),
    '{}'::jsonb);
$$;

revoke all on function public.get_app_update(text, text) from public;
grant execute on function public.get_app_update(text, text) to anon, authenticated;

-- Filas iniciales (aviso apagado hasta publicar la primera versión desde el panel).
insert into public.app_releases (service_id, platform, download_url, github_repo) values
  ('premiummusic', 'android', 'https://github.com/ByronR199716/musicapr/releases/latest/download/PremiumMusic-universal-release.apk', 'ByronR199716/musicapr'),
  ('ytpremium',    'android', 'https://github.com/ByronR199716/YTPREMIUM/releases/latest/download/YTPremium.apk',                 'ByronR199716/YTPREMIUM'),
  ('ytpremium',    'tv',      'https://github.com/ByronR199716/YTENTV/releases/latest/download/YTTVPremium-armeabi-v7a.apk',      'ByronR199716/YTENTV')
on conflict (service_id, platform) do nothing;
