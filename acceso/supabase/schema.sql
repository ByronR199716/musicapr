-- =====================================================================
--  SISTEMA DE ACCESO POR CÓDIGOS (tipo gift card) — Esquema Supabase
-- ---------------------------------------------------------------------
--  Cómo usarlo:
--    Supabase > SQL Editor > New query > pegar TODO este archivo > Run
--  Se puede ejecutar varias veces sin romper nada (no borra datos).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 1. TABLAS
-- ---------------------------------------------------------------------

-- Ajustes generales (una sola fila, id = 1)
create table if not exists public.app_settings (
  id                  smallint primary key default 1 check (id = 1),
  demo_enabled        boolean  not null default true,
  demo_hours          integer  not null default 6   check (demo_hours between 1 and 720),
  default_max_devices integer  not null default 2   check (default_max_devices between 1 and 10),
  offline_grace_hours integer  not null default 72  check (offline_grace_hours between 0 and 720),
  revalidate_hours    integer  not null default 12  check (revalidate_hours between 1 and 168),
  donation_url        text     not null default 'https://www.buymeacoffee.com/maxrave',
  welcome_message     text     not null default 'Versión no oficial de SimpMusic. Las donaciones van directamente a su creador, maxrave-dev.',
  updated_at          timestamptz not null default now()
);
insert into public.app_settings (id) values (1) on conflict (id) do nothing;

-- Códigos. "code" se guarda normalizado: solo letras/números en mayúscula, sin guiones.
create table if not exists public.access_codes (
  id             uuid primary key default gen_random_uuid(),
  code           text not null unique check (code ~ '^[A-Z0-9]{6,32}$'),
  duration_hours integer not null check (duration_hours > 0),
  max_devices    integer not null default 2 check (max_devices between 1 and 10),
  note           text,
  disabled       boolean not null default false,
  created_at     timestamptz not null default now(),
  activated_at   timestamptz,          -- se llena en el primer uso
  expires_at     timestamptz           -- activated_at + duration_hours
);
create index if not exists access_codes_created_idx on public.access_codes (created_at desc);
create index if not exists access_codes_expires_idx on public.access_codes (expires_at);

-- Dispositivos registrados en cada código (máximo max_devices por código)
create table if not exists public.code_devices (
  code_id     uuid not null references public.access_codes(id) on delete cascade,
  device_id   text not null,
  device_name text,
  first_seen  timestamptz not null default now(),
  last_seen   timestamptz not null default now(),
  primary key (code_id, device_id)
);
create index if not exists code_devices_device_idx on public.code_devices (device_id);

-- Demos: una sola por dispositivo
create table if not exists public.demo_devices (
  device_id   text primary key,
  device_name text,
  started_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  last_seen   timestamptz not null default now()
);
create index if not exists demo_devices_started_idx on public.demo_devices (started_at desc);

-- Administradores (cuentas de Supabase Auth con acceso al panel)
create table if not exists public.admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. SEGURIDAD (RLS): la app NO puede leer tablas; solo el admin.
-- ---------------------------------------------------------------------

create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.admins a where a.user_id = auth.uid());
$$;

alter table public.app_settings enable row level security;
alter table public.access_codes enable row level security;
alter table public.code_devices enable row level security;
alter table public.demo_devices enable row level security;
alter table public.admins       enable row level security;

revoke all on public.app_settings, public.access_codes, public.code_devices,
              public.demo_devices, public.admins from anon;

drop policy if exists admin_all on public.app_settings;
drop policy if exists admin_all on public.access_codes;
drop policy if exists admin_all on public.code_devices;
drop policy if exists admin_all on public.demo_devices;
drop policy if exists admin_read on public.admins;

create policy admin_all on public.app_settings for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy admin_all on public.access_codes for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy admin_all on public.code_devices for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy admin_all on public.demo_devices for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy admin_read on public.admins for select to authenticated
  using (public.is_admin());

-- ---------------------------------------------------------------------
-- 3. FUNCIONES INTERNAS
-- ---------------------------------------------------------------------

-- Código aleatorio criptográficamente seguro. Alfabeto sin 0/O/1/I.
create or replace function public._random_code(p_len integer default 12)
returns text
language plpgsql volatile set search_path = ''
as $$
declare
  alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'; -- 32 símbolos
  b bytea := extensions.gen_random_bytes(p_len);
  result text := '';
begin
  for i in 0 .. p_len - 1 loop
    result := result || substr(alphabet, (get_byte(b, i) % 32) + 1, 1);
  end loop;
  return result;
end;
$$;

-- Respuesta estándar que recibe la app
create or replace function public._access_result(
  p_ok boolean, p_reason text, p_kind text, p_expires timestamptz
) returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'ok',                  p_ok,
    'reason',              p_reason,
    'kind',                p_kind,
    'expires_at',          p_expires,
    'server_time',         now(),
    'expires_ms',          (extract(epoch from p_expires) * 1000)::bigint,
    'server_ms',           (extract(epoch from now()) * 1000)::bigint,
    'revalidate_hours',    s.revalidate_hours,
    'offline_grace_hours', s.offline_grace_hours
  )
  from public.app_settings s where s.id = 1;
$$;

-- ---------------------------------------------------------------------
-- 4. FUNCIONES PÚBLICAS (las llama la app, sin iniciar sesión)
-- ---------------------------------------------------------------------

-- Datos para mostrar en la pantalla de acceso
create or replace function public.get_public_config()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'demo_enabled',    s.demo_enabled,
    'demo_hours',      s.demo_hours,
    'donation_url',    s.donation_url,
    'welcome_message', s.welcome_message
  )
  from public.app_settings s where s.id = 1;
$$;

-- Valida (y en el primer uso, activa) un código para un dispositivo.
-- reason: ok | invalid | disabled | expired | device_limit | bad_request
create or replace function public.validate_access(
  p_code text, p_device_id text, p_device_name text default null
) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_code   text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_device text := left(coalesce(p_device_id, ''), 128);
  v_name   text := left(p_device_name, 80);
  r        public.access_codes;
  v_count  integer;
begin
  if length(v_device) < 4 or length(v_code) < 6 or length(v_code) > 32 then
    return public._access_result(false, case when length(v_device) < 4 then 'bad_request' else 'invalid' end, 'code', null);
  end if;

  select * into r from public.access_codes where code = v_code for update;
  if not found then
    return public._access_result(false, 'invalid', 'code', null);
  end if;
  if r.disabled then
    return public._access_result(false, 'disabled', 'code', r.expires_at);
  end if;
  if r.expires_at is not null and r.expires_at <= now() then
    return public._access_result(false, 'expired', 'code', r.expires_at);
  end if;

  if exists (select 1 from public.code_devices d where d.code_id = r.id and d.device_id = v_device) then
    update public.code_devices
       set last_seen = now(), device_name = coalesce(v_name, device_name)
     where code_id = r.id and device_id = v_device;
  else
    select count(*) into v_count from public.code_devices d where d.code_id = r.id;
    if v_count >= r.max_devices then
      return public._access_result(false, 'device_limit', 'code', r.expires_at);
    end if;
    insert into public.code_devices (code_id, device_id, device_name) values (r.id, v_device, v_name);
  end if;

  if r.activated_at is null then
    update public.access_codes
       set activated_at = now(), expires_at = now() + make_interval(hours => r.duration_hours)
     where id = r.id
     returning * into r;
  end if;

  return public._access_result(true, 'ok', 'code', r.expires_at);
end;
$$;

-- Inicia (o continúa) la demo de un dispositivo. Una demo por dispositivo.
-- reason: ok | demo_used | demo_disabled | bad_request
create or replace function public.start_demo(
  p_device_id text, p_device_name text default null
) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_device text := left(coalesce(p_device_id, ''), 128);
  v_name   text := left(p_device_name, 80);
  s        public.app_settings;
  d        public.demo_devices;
begin
  if length(v_device) < 4 then
    return public._access_result(false, 'bad_request', 'demo', null);
  end if;

  select * into d from public.demo_devices where device_id = v_device for update;
  if found then
    if d.expires_at > now() then
      update public.demo_devices set last_seen = now() where device_id = v_device;
      return public._access_result(true, 'ok', 'demo', d.expires_at);
    end if;
    return public._access_result(false, 'demo_used', 'demo', d.expires_at);
  end if;

  select * into s from public.app_settings where id = 1;
  if not s.demo_enabled then
    return public._access_result(false, 'demo_disabled', 'demo', null);
  end if;

  insert into public.demo_devices (device_id, device_name, expires_at)
  values (v_device, v_name, now() + make_interval(hours => s.demo_hours))
  on conflict (device_id) do nothing
  returning * into d;

  if d.device_id is null then -- dos solicitudes simultáneas: devolver la existente
    select * into d from public.demo_devices where device_id = v_device;
  end if;
  return public._access_result(d.expires_at > now(), case when d.expires_at > now() then 'ok' else 'demo_used' end, 'demo', d.expires_at);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. FUNCIONES DEL PANEL ADMIN (requieren sesión de administrador)
-- ---------------------------------------------------------------------

create or replace function public._require_admin()
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo administradores' using errcode = '42501';
  end if;
end;
$$;

-- Genera N códigos con una duración (en horas)
create or replace function public.admin_generate_codes(
  p_count integer, p_duration_hours integer,
  p_max_devices integer default null, p_note text default null
) returns setof public.access_codes
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_max integer;
  v_row public.access_codes;
  v_made integer := 0;
begin
  perform public._require_admin();
  if p_count is null or p_count < 1 or p_count > 1000 then
    raise exception 'La cantidad debe estar entre 1 y 1000';
  end if;
  if p_duration_hours is null or p_duration_hours < 1 then
    raise exception 'La duración debe ser de al menos 1 hora';
  end if;
  select coalesce(p_max_devices, s.default_max_devices) into v_max from public.app_settings s where s.id = 1;

  while v_made < p_count loop
    insert into public.access_codes (code, duration_hours, max_devices, note)
    values (public._random_code(12), p_duration_hours, v_max, nullif(trim(p_note), ''))
    on conflict (code) do nothing
    returning * into v_row;
    if found then
      v_made := v_made + 1;
      return next v_row;
    end if;
  end loop;
end;
$$;

-- Extiende un código. Sin usar: suma a la duración. Activo: suma al vencimiento.
-- Vencido: lo reactiva desde ahora.
create or replace function public.admin_extend_code(p_id uuid, p_hours integer)
returns public.access_codes
language plpgsql volatile security definer set search_path = ''
as $$
declare r public.access_codes;
begin
  perform public._require_admin();
  if p_hours is null or p_hours < 1 then raise exception 'Horas inválidas'; end if;
  update public.access_codes c
     set duration_hours = case when c.activated_at is null then c.duration_hours + p_hours else c.duration_hours end,
         expires_at     = case when c.activated_at is null then null
                               else greatest(c.expires_at, now()) + make_interval(hours => p_hours) end
   where c.id = p_id
   returning * into r;
  if not found then raise exception 'Código no encontrado'; end if;
  return r;
end;
$$;

-- Números para el tablero
create or replace function public.admin_stats()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare res jsonb;
begin
  perform public._require_admin();
  select jsonb_build_object(
    'total',        count(*),
    'unused',       count(*) filter (where not disabled and activated_at is null),
    'active',       count(*) filter (where not disabled and expires_at > now()),
    'expired',      count(*) filter (where not disabled and expires_at <= now()),
    'disabled',     count(*) filter (where disabled),
    'activated_7d', count(*) filter (where activated_at > now() - interval '7 days'),
    'devices',      (select count(*) from public.code_devices),
    'demos_active', (select count(*) from public.demo_devices where expires_at > now()),
    'demos_total',  (select count(*) from public.demo_devices)
  ) into res
  from public.access_codes;
  return res;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. PERMISOS DE EJECUCIÓN
-- ---------------------------------------------------------------------

revoke all on function public.is_admin()                                   from public, anon;
revoke all on function public._random_code(integer)                        from public, anon, authenticated;
revoke all on function public._access_result(boolean, text, text, timestamptz) from public, anon, authenticated;
revoke all on function public._require_admin()                             from public, anon, authenticated;
revoke all on function public.admin_generate_codes(integer, integer, integer, text) from public, anon;
revoke all on function public.admin_extend_code(uuid, integer)             from public, anon;
revoke all on function public.admin_stats()                                from public, anon;

grant execute on function public.get_public_config()                       to anon, authenticated;
grant execute on function public.validate_access(text, text, text)         to anon, authenticated;
grant execute on function public.start_demo(text, text)                    to anon, authenticated;
grant execute on function public.is_admin()                                to authenticated;
grant execute on function public.admin_generate_codes(integer, integer, integer, text) to authenticated;
grant execute on function public.admin_extend_code(uuid, integer)          to authenticated;
grant execute on function public.admin_stats()                             to authenticated;

-- =====================================================================
--  ÚLTIMO PASO (una sola vez): hacerte administrador.
--  1) Supabase > Authentication > Users > Add user (tu correo + contraseña)
--  2) Ejecuta esta línea cambiando el correo:
--
--  insert into public.admins (user_id)
--  select id from auth.users where email = 'TU_CORREO@gmail.com'
--  on conflict do nothing;
-- =====================================================================
