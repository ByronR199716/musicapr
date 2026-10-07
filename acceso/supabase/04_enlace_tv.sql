-- Enlace de descarga de la versión TV de un servicio (ej. YTTVPremium para ytpremium).
-- No es un servicio aparte: los códigos son los mismos. Aplicado 2026-10-07.
alter table public.services add column if not exists tv_download_url text;
update public.services
   set tv_download_url = 'https://github.com/ByronR199716/YTENTV/releases/latest/download/YTTVPremium-armeabi-v7a.apk'
 where id = 'ytpremium' and tv_download_url is null;
