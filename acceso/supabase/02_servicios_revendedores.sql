-- =====================================================================
--  PARTE 2: varios servicios + revendedores con créditos
-- ---------------------------------------------------------------------
--  Se ejecuta DESPUÉS de schema.sql. Se puede ejecutar varias veces.
--
--  Reglas de créditos:
--    * 1 crédito = 1 mes (30 días). 2 meses = 2 créditos, etc.
--    * Hasta 7 días (6 h, 1 día, 7 días…) no cuesta créditos.
--    * Más de 7 días: créditos = meses redondeados (mínimo 1).
--    * El admin genera gratis.
--    * Si un revendedor anula un código SIN USAR, se le devuelven
--      los créditos y el código queda anulado para siempre.
--      Si el código ya estaba en uso, se deshabilita sin devolución.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. TABLAS
-- ---------------------------------------------------------------------

create table if not exists public.services (
  id         text primary key check (id ~ '^[a-z0-9-]{2,40}$'),
  name       text not null check (length(trim(name)) between 1 and 60),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
insert into public.services (id, name) values ('premiummusic', 'PremiumMusic')
on conflict (id) do nothing;

-- Revendedores (cuentas del panel que generan con créditos)
create table if not exists public.panel_users (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  email        text not null,
  display_name text,
  credits      integer not null default 0 check (credits >= 0),
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

alter table public.access_codes
  add column if not exists service_id   text not null default 'premiummusic'
                                         references public.services(id) on update cascade,
  add column if not exists created_by   uuid references auth.users(id) on delete set null,
  add column if not exists credits_cost integer not null default 0 check (credits_cost >= 0),
  add column if not exists voided_at    timestamptz;
create index if not exists access_codes_service_idx    on public.access_codes (service_id);
create index if not exists access_codes_created_by_idx on public.access_codes (created_by, created_at desc);

-- Historial de créditos
create table if not exists public.credit_ledger (
  id            bigint generated always as identity primary key,
  user_id       uuid not null references public.panel_users(user_id) on delete cascade,
  delta         integer not null,
  balance_after integer not null,
  kind          text not null check (kind in ('recarga', 'ajuste', 'consumo', 'devolucion')),
  code_id       uuid references public.access_codes(id) on delete set null,
  note          text,
  actor         uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now()
);
create index if not exists credit_ledger_user_idx on public.credit_ledger (user_id, created_at desc);

-- ---------------------------------------------------------------------
-- 2. SEGURIDAD
-- ---------------------------------------------------------------------

create or replace function public.is_reseller()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.panel_users u where u.user_id = auth.uid() and u.active);
$$;

alter table public.services      enable row level security;
alter table public.panel_users   enable row level security;
alter table public.credit_ledger enable row level security;
revoke all on public.services, public.panel_users, public.credit_ledger from anon;

drop policy if exists admin_all       on public.services;
drop policy if exists reseller_read   on public.services;
drop policy if exists admin_all       on public.panel_users;
drop policy if exists self_read       on public.panel_users;
drop policy if exists admin_read      on public.credit_ledger;
drop policy if exists self_read       on public.credit_ledger;
drop policy if exists reseller_read   on public.access_codes;
drop policy if exists reseller_read   on public.code_devices;

create policy admin_all on public.services for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy reseller_read on public.services for select to authenticated
  using (public.is_reseller());

create policy admin_all on public.panel_users for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy self_read on public.panel_users for select to authenticated
  using (user_id = auth.uid());

-- El historial solo se escribe desde las funciones
create policy admin_read on public.credit_ledger for select to authenticated
  using (public.is_admin());
create policy self_read on public.credit_ledger for select to authenticated
  using (user_id = auth.uid());

-- El revendedor solo VE sus propios códigos y cuántos dispositivos usan
create policy reseller_read on public.access_codes for select to authenticated
  using (created_by = auth.uid() and public.is_reseller());
create policy reseller_read on public.code_devices for select to authenticated
  using (public.is_reseller() and exists (
    select 1 from public.access_codes c where c.id = code_id and c.created_by = auth.uid()));

-- ---------------------------------------------------------------------
-- 3. FUNCIONES
-- ---------------------------------------------------------------------

-- Créditos que cuesta UN código de esa duración
create or replace function public.credit_cost(p_hours integer)
returns integer
language sql immutable set search_path = ''
as $$
  select case when p_hours <= 168 then 0
              else greatest(1, round(p_hours / 720.0)::integer) end;
$$;

-- Quién soy en el panel
create or replace function public.my_profile()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select case
    when public.is_admin() then jsonb_build_object('role', 'admin')
    when u.user_id is not null then jsonb_build_object(
      'role', 'reseller', 'active', u.active, 'credits', u.credits,
      'name', coalesce(u.display_name, u.email))
    else jsonb_build_object('role', null)
  end
  from (select 1) x
  left join public.panel_users u on u.user_id = auth.uid();
$$;

-- Valida un código PARA UN SERVICIO. Las apps que no envían p_service
-- (PremiumMusic actual) usan 'premiummusic'.
drop function if exists public.validate_access(text, text, text);
create or replace function public.validate_access(
  p_code text, p_device_id text, p_device_name text default null,
  p_service text default 'premiummusic'
) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_code    text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_device  text := left(coalesce(p_device_id, ''), 128);
  v_name    text := left(p_device_name, 80);
  v_service text := lower(coalesce(nullif(trim(p_service), ''), 'premiummusic'));
  r         public.access_codes;
  v_count   integer;
begin
  if length(v_device) < 4 or length(v_code) < 6 or length(v_code) > 32 then
    return public._access_result(false, case when length(v_device) < 4 then 'bad_request' else 'invalid' end, 'code', null);
  end if;

  select * into r from public.access_codes where code = v_code for update;
  if not found or r.service_id <> v_service then
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

-- Genera códigos. Admin: gratis. Revendedor: descuenta créditos.
create or replace function public.generate_codes(
  p_service text, p_count integer, p_duration_hours integer,
  p_max_devices integer default null, p_note text default null
) returns setof public.access_codes
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_admin   boolean := public.is_admin();
  v_uid     uuid := auth.uid();
  v_max     integer;
  v_cost    integer := 0;
  v_total   integer := 0;
  v_balance integer;
  v_row     public.access_codes;
  v_made    integer := 0;
  v_svc     public.services;
  v_limit   integer;
begin
  if not v_admin and not public.is_reseller() then
    raise exception 'No tienes permiso para generar códigos' using errcode = '42501';
  end if;
  select * into v_svc from public.services where id = p_service;
  if not found or (not v_svc.active and not v_admin) then
    raise exception 'Ese servicio no está disponible';
  end if;
  v_limit := case when v_admin then 1000 else 100 end;
  if p_count is null or p_count < 1 or p_count > v_limit then
    raise exception 'La cantidad debe estar entre 1 y %', v_limit;
  end if;
  if p_duration_hours is null or p_duration_hours < 1 or p_duration_hours > 87600 then
    raise exception 'Duración inválida';
  end if;

  select s.default_max_devices into v_max from public.app_settings s where s.id = 1;
  if v_admin and p_max_devices between 1 and 10 then v_max := p_max_devices; end if;

  if not v_admin then
    v_cost  := public.credit_cost(p_duration_hours);
    v_total := v_cost * p_count;
    if v_total > 0 then
      select credits into v_balance from public.panel_users where user_id = v_uid for update;
      if v_balance < v_total then
        raise exception 'Créditos insuficientes: necesitas %, tienes %', v_total, v_balance;
      end if;
      update public.panel_users set credits = credits - v_total where user_id = v_uid
      returning credits into v_balance;
      insert into public.credit_ledger (user_id, delta, balance_after, kind, note, actor)
      values (v_uid, -v_total, v_balance, 'consumo',
              format('%s código(s) %s · %s', p_count, v_svc.name,
                     case when p_duration_hours % 720 = 0 then (p_duration_hours / 720) || ' mes(es)'
                          else round(p_duration_hours / 24.0, 1) || ' día(s)' end),
              v_uid);
    end if;
  end if;

  while v_made < p_count loop
    insert into public.access_codes (code, duration_hours, max_devices, note, service_id, created_by, credits_cost)
    values (public._random_code(12), p_duration_hours, v_max, nullif(trim(p_note), ''), p_service, v_uid, v_cost)
    on conflict (code) do nothing
    returning * into v_row;
    if found then
      v_made := v_made + 1;
      return next v_row;
    end if;
  end loop;
end;
$$;

-- Versión anterior del panel: sigue funcionando, genera para PremiumMusic
create or replace function public.admin_generate_codes(
  p_count integer, p_duration_hours integer,
  p_max_devices integer default null, p_note text default null
) returns setof public.access_codes
language plpgsql volatile security definer set search_path = ''
as $$
begin
  perform public._require_admin();
  return query select * from public.generate_codes('premiummusic', p_count, p_duration_hours, p_max_devices, p_note);
end;
$$;

-- Deshabilita/anula un código. Sin usar → anulado y créditos devueltos.
create or replace function public.disable_code(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  r          public.access_codes;
  v_used     boolean;
  v_refund   integer := 0;
  v_balance  integer;
begin
  select * into r from public.access_codes where id = p_id for update;
  if not found then raise exception 'Código no encontrado'; end if;
  if not public.is_admin() and not (public.is_reseller() and r.created_by = auth.uid()) then
    raise exception 'No tienes permiso sobre este código' using errcode = '42501';
  end if;
  if r.disabled then
    return jsonb_build_object('voided', r.voided_at is not null, 'refunded', 0);
  end if;

  v_used := r.activated_at is not null
            or exists (select 1 from public.code_devices d where d.code_id = r.id);

  if v_used then
    update public.access_codes set disabled = true where id = r.id;
    return jsonb_build_object('voided', false, 'refunded', 0);
  end if;

  update public.access_codes set disabled = true, voided_at = now() where id = r.id;
  if r.credits_cost > 0 and exists (select 1 from public.panel_users u where u.user_id = r.created_by) then
    v_refund := r.credits_cost;
    update public.panel_users set credits = credits + v_refund where user_id = r.created_by
    returning credits into v_balance;
    insert into public.credit_ledger (user_id, delta, balance_after, kind, code_id, note, actor)
    values (r.created_by, v_refund, v_balance, 'devolucion', r.id,
            'Código anulado sin usar ' || r.code, auth.uid());
  end if;
  return jsonb_build_object('voided', true, 'refunded', v_refund);
end;
$$;

-- Solo admin: volver a habilitar un código deshabilitado (no los anulados)
create or replace function public.admin_enable_code(p_id uuid)
returns void
language plpgsql volatile security definer set search_path = ''
as $$
begin
  perform public._require_admin();
  update public.access_codes set disabled = false where id = p_id and voided_at is null;
  if not found then raise exception 'Un código anulado no se puede volver a habilitar'; end if;
end;
$$;

-- Solo admin: eliminar. Si era de un revendedor y estaba sin usar, devuelve créditos.
create or replace function public.admin_delete_code(p_id uuid)
returns void
language plpgsql volatile security definer set search_path = ''
as $$
declare r public.access_codes;
begin
  perform public._require_admin();
  select * into r from public.access_codes where id = p_id for update;
  if not found then return; end if;
  if not r.disabled then perform public.disable_code(p_id); end if;
  delete from public.access_codes where id = p_id;
end;
$$;

-- Solo admin: sumar o quitar créditos
create or replace function public.admin_add_credits(p_user uuid, p_delta integer, p_note text default null)
returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare v_balance integer;
begin
  perform public._require_admin();
  if p_delta is null or p_delta = 0 or abs(p_delta) > 100000 then raise exception 'Cantidad inválida'; end if;
  update public.panel_users set credits = credits + p_delta
   where user_id = p_user and credits + p_delta >= 0
  returning credits into v_balance;
  if not found then raise exception 'El usuario no existe o quedaría con saldo negativo'; end if;
  insert into public.credit_ledger (user_id, delta, balance_after, kind, note, actor)
  values (p_user, p_delta, v_balance, case when p_delta > 0 then 'recarga' else 'ajuste' end,
          nullif(trim(p_note), ''), auth.uid());
  return v_balance;
end;
$$;

-- Solo admin: lista de revendedores con sus números
create or replace function public.admin_list_users()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare res jsonb;
begin
  perform public._require_admin();
  select coalesce(jsonb_agg(x order by x.created_at desc), '[]'::jsonb) into res from (
    select u.user_id, u.email, u.display_name, u.credits, u.active, u.created_at,
           count(c.id)                                              as codes_total,
           count(c.id) filter (where c.activated_at is not null)    as codes_used,
           count(c.id) filter (where c.voided_at is not null)       as codes_voided,
           (select coalesce(-sum(l.delta), 0) from public.credit_ledger l
             where l.user_id = u.user_id and l.kind in ('consumo', 'devolucion')) as credits_spent
      from public.panel_users u
      left join public.access_codes c on c.created_by = u.user_id
     group by u.user_id
  ) x;
  return res;
end;
$$;

-- Cifras del tablero (admin: todo; revendedor: lo suyo)
create or replace function public.panel_stats(p_service text default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_admin boolean := public.is_admin();
  res jsonb;
begin
  if not v_admin and not public.is_reseller() then
    raise exception 'Sin permiso' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'total',    count(*),
    'unused',   count(*) filter (where not disabled and activated_at is null),
    'active',   count(*) filter (where not disabled and expires_at > now()),
    'expired',  count(*) filter (where not disabled and expires_at <= now()),
    'disabled', count(*) filter (where disabled),
    'credits',  (select credits from public.panel_users where user_id = auth.uid())
  ) into res
  from public.access_codes c
  where (v_admin or c.created_by = auth.uid())
    and (p_service is null or c.service_id = p_service);
  return res;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. PERMISOS DE EJECUCIÓN
-- ---------------------------------------------------------------------

revoke all on function public.is_reseller()                                 from public, anon;
revoke all on function public.credit_cost(integer)                          from public, anon;
revoke all on function public.my_profile()                                  from public, anon;
revoke all on function public.generate_codes(text, integer, integer, integer, text) from public, anon;
revoke all on function public.admin_generate_codes(integer, integer, integer, text) from public, anon;
revoke all on function public.disable_code(uuid)                            from public, anon;
revoke all on function public.admin_enable_code(uuid)                       from public, anon;
revoke all on function public.admin_delete_code(uuid)                       from public, anon;
revoke all on function public.admin_add_credits(uuid, integer, text)        from public, anon;
revoke all on function public.admin_list_users()                            from public, anon;
revoke all on function public.panel_stats(text)                             from public, anon;

grant execute on function public.validate_access(text, text, text, text)    to anon, authenticated;
grant execute on function public.is_reseller()                              to authenticated;
grant execute on function public.credit_cost(integer)                       to authenticated;
grant execute on function public.my_profile()                               to authenticated;
grant execute on function public.generate_codes(text, integer, integer, integer, text) to authenticated;
grant execute on function public.admin_generate_codes(integer, integer, integer, text) to authenticated;
grant execute on function public.disable_code(uuid)                         to authenticated;
grant execute on function public.admin_enable_code(uuid)                    to authenticated;
grant execute on function public.admin_delete_code(uuid)                    to authenticated;
grant execute on function public.admin_add_credits(uuid, integer, text)     to authenticated;
grant execute on function public.admin_list_users()                         to authenticated;
grant execute on function public.panel_stats(text)                          to authenticated;
