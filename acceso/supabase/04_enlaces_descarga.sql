-- 04 · Enlace de descarga por servicio (2026-10-07). Ya aplicado en el servidor.
-- Lo ven admin y revendedores en Panel > Descargas; el admin lo edita en Panel > Servicios.
alter table public.services add column if not exists download_url text
  check (download_url is null or download_url ~* '^https?://');
update public.services set download_url = 'https://github.com/ByronR199716/musicapr/releases/latest/download/PremiumMusic-universal-release.apk'
 where id = 'premiummusic' and download_url is null;
update public.services set download_url = 'https://github.com/ByronR199716/YTPREMIUM/releases/download/build-2/YTPremium-1.0.2.apk'
 where id = 'ytpremium' and download_url is null;
