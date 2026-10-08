-- Enlace de descarga de la versión para computadora (Windows) de un servicio
-- (ej. YTPremium PC para ytpremium). No es un servicio aparte: los códigos son
-- los mismos y cada PC ocupa uno de los dispositivos del código. Aplicado 2026-10-08.
alter table public.services add column if not exists pc_download_url text;
update public.services
   set pc_download_url = 'https://github.com/ByronR199716/YTPREMIUM/releases/download/pc/YTPremium-Setup.exe'
 where id = 'ytpremium' and pc_download_url is null;
