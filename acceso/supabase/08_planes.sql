--  PARTE 8: planes (1, 2, 3, 6, 12 meses) que se activan/desactivan,
--  regalo automático de meses por plan y demo con duración elegida.
--  Se ejecuta DESPUÉS de 03_pruebas.sql. Se puede ejecutar varias veces.
--
--  Reglas:
--    * Planes y regalos valen para TODOS los servicios.
--    * Un plan desactivado no se puede generar (ni revendedores ni, desde el
--      panel, el admin). Los códigos ya generados siguen funcionando igual.
--    * Regalo: si el plan de 3 meses tiene "regalo = 1", cada código de 3 meses
--      sale con 4 meses. El revendedor paga SOLO los 3 meses (el regalo lo
--      asume el admin). En 0 no se regala nada.
--    * Demo: una sola duración (Ajustes > Demo de los códigos). Es gratis y
--      cuenta para el límite diario de pruebas del revendedor.
--    * Los revendedores solo pueden generar la demo y los planes activos.
--      El admin además puede generar duraciones libres (sin regalo).

-- 1. TABLAS Y COLUMNAS

create table if not exists public.plans (
  months       integer primary key check (months between 1 and 120),
  active       boolean not null default true,
  bonus_months integer not null default 0 check (bonus_months between 0 and 12),
  updated_at   timestamptz not null default now()
);
insert into public.plans (months) values (1), (2), (3), (6), (12)
on conflict (months) do nothing;

alter table public.app_settings
  add column if not exists trial_plan_enabled boolean not null default true,
  add column if not exists trial_hours        integer not null default 24
                                               check (trial_hours between 1 and 168);

-- Cuántos meses de regalo trae cada código (para mostrarlo en el panel)
alter table public.access_codes
  add column if not exists bonus_months integer not null default 0 check (bonus_months >= 0);

-- 2. SEGURIDAD: solo el admin escribe planes; los revendedores los leen por función

alter table public.plans enable row level security;
revoke all on public.plans from anon;
drop policy if exists admin_all on public.plans;
create policy admin_all on public.plans for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Lo que el panel necesita para armar el formulario de generar
create or replace function public.get_plan_options()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select case when public.is_admin() or public.is_reseller() then
    jsonb_build_object(
      'trial_enabled', s.trial_plan_enabled,
      'trial_hours',   s.trial_hours,
      'plans', coalesce((
        select jsonb_agg(jsonb_build_object('months', p.months, 'active', p.active,
                                            'bonus_months', p.bonus_months) order by p.months)
          from public.plans p
         where public.is_admin() or p.active), '[]'::jsonb))
  else null end
  from public.app_settings s where s.id = 1;
$$;

-- 3. GENERAR CÓDIGOS (planes, regalo y demo)
drop function if exists public.generate_codes(text, integer, integer, integer, text);
create or replace function public.generate_codes(
  p_service text, p_count integer, p_duration_hours integer,
  p_max_devices integer default null, p_note text default null,
  p_apply_plan boolean default true
) returns setof public.access_codes
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_admin    boolean := public.is_admin();
  v_uid      uuid := auth.uid();
  v_max      integer;
  v_cost     integer := 0;
  v_total    integer := 0;
  v_balance  integer;
  v_row      public.access_codes;
  v_made     integer := 0;
  v_svc      public.services;
  v_limit    integer;
  v_daily    integer;
  v_today    integer;
  v_trial_on boolean;
  v_trial_h  integer;
  v_apply    boolean := coalesce(p_apply_plan, true) or not v_admin;
  v_plan     public.plans;
  v_is_plan  boolean := false;
  v_bonus    integer := 0;
  v_hours    integer;
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

  select s.default_max_devices, s.reseller_daily_trials, s.trial_plan_enabled, s.trial_hours
    into v_max, v_daily, v_trial_on, v_trial_h
    from public.app_settings s where s.id = 1;
  if v_admin and p_max_devices between 1 and 10 then v_max := p_max_devices; end if;

  -- ¿Es un plan de meses completos?
  if v_apply and p_duration_hours % 720 = 0 then
    select * into v_plan from public.plans where months = p_duration_hours / 720;
    if found then
      v_is_plan := true;
      if v_plan.active then
        v_bonus := v_plan.bonus_months;
      elsif not v_admin then
        raise exception 'El plan de % mes(es) no está disponible por ahora', v_plan.months;
      end if;
    end if;
  end if;

  -- Revendedores: solo la demo o un plan activo
  if not v_admin and not v_is_plan then
    if p_duration_hours <= 168 then
      if not coalesce(v_trial_on, true) then
        raise exception 'Las demos están desactivadas por ahora';
      end if;
      if p_duration_hours <> v_trial_h then
        raise exception 'Duración no permitida: la demo actual es de % hora(s)', v_trial_h;
      end if;
    else
      raise exception 'Esa duración no está disponible. Elige uno de los planes';
    end if;
  end if;

  v_hours := case when v_is_plan then (v_plan.months + v_bonus) * 720 else p_duration_hours end;

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

    -- Se cobran solo los meses del plan; el regalo no se descuenta
    v_cost  := case when v_is_plan then v_plan.months else 0 end;
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
                     case when v_is_plan
                          then v_plan.months || ' mes(es)' ||
                               case when v_bonus > 0 then ' + ' || v_bonus || ' de regalo' else '' end
                          when p_duration_hours % 720 = 0 then (p_duration_hours / 720) || ' mes(es)'
                          else round(p_duration_hours / 24.0, 1) || ' día(s)' end),
              v_uid);
    end if;
  end if;

  while v_made < p_count loop
    insert into public.access_codes (code, duration_hours, max_devices, note, service_id, created_by, credits_cost, bonus_months)
    values (public._random_code(12), v_hours, v_max, nullif(trim(p_note), ''), p_service, v_uid, v_cost, v_bonus)
    on conflict (code) do nothing
    returning * into v_row;
    if found then
      v_made := v_made + 1;
      return next v_row;
    end if;
  end loop;
end;
$$;

-- 4. PERMISOS
revoke all on function public.generate_codes(text, integer, integer, integer, text, boolean) from public, anon;
revoke all on function public.get_plan_options() from public, anon;
grant execute on function public.generate_codes(text, integer, integer, integer, text, boolean) to authenticated;
grant execute on function public.get_plan_options() to authenticated;
