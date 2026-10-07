-- =====================================================================
-- 03 · Protección de códigos de prueba (2026-10-06)
--
-- "Prueba" = código de 7 días (168 h) o menos (los mismos que no gastan créditos).
--
-- 1. Una prueba por teléfono y por servicio: si un dispositivo ya usó un
--    código de prueba de ese servicio, otro código de prueba distinto se
--    rechaza en ese dispositivo. Las apps actuales muestran el mensaje de
--    "código vencido" ("Pide uno nuevo…"), sin necesidad de recompilarlas.
--    Los códigos pagados (más de 7 días) no se ven afectados.
-- 2. Límite diario de códigos de prueba por revendedor (el admin no tiene límite).
--
-- Ambas cosas se configuran en el panel > Ajustes. Se puede ejecutar más de una vez.
-- =====================================================================

-- 1. AJUSTES
alter table public.app_settings
  add column if not exists trial_one_per_device  boolean not null default true,
  add column if not exists reseller_daily_trials integer not null default 5
                           check (reseller_daily_trials between 0 and 1000);

-- 2. REGISTRO DE PRUEBAS USADAS (sin FK al código: si se borra el código,
--    el teléfono sigue contando como que ya usó su prueba)
create table if not exists public.trial_devices (
  service_id text not null references public.services(id) on update cascade on delete cascade,
  device_id  text not null,
  code_id    uuid not null,
  used_at    timestamptz not null default now(),
  primary key (service_id, device_id)
);
alter table public.trial_devices enable row level security;
revoke all on public.trial_devices from anon;
drop policy if exists admin_all on public.trial_devices;
create policy admin_all on public.trial_devices for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Pruebas usadas antes de este cambio (la más antigua por teléfono y servicio)
insert into public.trial_devices (service_id, device_id, code_id, used_at)
select distinct on (c.service_id, d.device_id) c.service_id, d.device_id, c.id, d.first_seen
  from public.code_devices d
  join public.access_codes c on c.id = d.code_id
 where c.duration_hours <= 168
 order by c.service_id, d.device_id, d.first_seen
on conflict do nothing;

-- 3. VALIDACIÓN (igual que 02, más la regla de una prueba por dispositivo)
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
  v_trial   boolean;
  v_rule    boolean;
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

    -- Una prueba por teléfono y por servicio
    v_trial := r.duration_hours <= 168;
    if v_trial then
      select s.trial_one_per_device into v_rule from public.app_settings s where s.id = 1;
      if coalesce(v_rule, true) and exists (
        select 1 from public.trial_devices t
         where t.service_id = r.service_id and t.device_id = v_device and t.code_id <> r.id
      ) then
        -- "expired": las apps actuales muestran "Tu código venció. Pide uno nuevo…"
        return public._access_result(false, 'expired', 'code', null);
      end if;
      insert into public.trial_devices (service_id, device_id, code_id)
      values (r.service_id, v_device, r.id)
      on conflict (service_id, device_id) do nothing;
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

-- 4. GENERAR CÓDIGOS (igual que 02, más el límite diario de pruebas por revendedor)
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
  v_daily   integer;
  v_today   integer;
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

  select s.default_max_devices, s.reseller_daily_trials into v_max, v_daily
    from public.app_settings s where s.id = 1;
  if v_admin and p_max_devices between 1 and 10 then v_max := p_max_devices; end if;

  if not v_admin then
    -- Límite diario de pruebas (≤ 7 días), contando el día en hora de Ecuador
    if p_duration_hours <= 168 then
      perform pg_advisory_xact_lock(hashtext('trials:' || v_uid::text));
      select count(*) into v_today from public.access_codes c
       where c.created_by = v_uid and c.duration_hours <= 168
         and c.created_at >= (date_trunc('day', now() at time zone 'America/Guayaquil') at time zone 'America/Guayaquil');
      if v_today + p_count > coalesce(v_daily, 5) then
        raise exception 'Límite diario de pruebas: puedes generar % al día y hoy ya generaste %', coalesce(v_daily, 5), v_today;
      end if;
    end if;

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

grant execute on function public.validate_access(text, text, text, text) to anon, authenticated;
grant execute on function public.generate_codes(text, integer, integer, integer, text) to authenticated;
