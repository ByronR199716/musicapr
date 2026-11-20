--  PARTE 9: los revendedores pueden EXTENDER (renovar) sus propios códigos.
--  Se ejecuta DESPUÉS de 08_planes.sql. Se puede ejecutar varias veces.
--
--  Reglas:
--    * Se extiende con un plan ACTIVO (1, 2, 3, 6, 12 meses), igual que al generar.
--    * Cuesta los meses del plan en créditos; el regalo del plan lo asume el admin.
--    * El revendedor solo puede extender códigos que él creó y que no estén
--      deshabilitados ni anulados.
--    * Sin usar: suma a la duración. Activo: suma al vencimiento.
--      Vencido: lo reactiva contando desde ahora.
--    * El admin sigue usando admin_extend_code (horas libres, gratis).

create or replace function public.extend_code(p_id uuid, p_months integer)
returns public.access_codes
language plpgsql volatile security definer set search_path = ''
as $$
declare
  r         public.access_codes;
  v_uid     uuid := auth.uid();
  v_admin   boolean := public.is_admin();
  v_plan    public.plans;
  v_hours   integer;
  v_cost    integer := 0;
  v_balance integer;
begin
  if not v_admin and not public.is_reseller() then
    raise exception 'No tienes permiso para extender códigos' using errcode = '42501';
  end if;

  select * into r from public.access_codes where id = p_id for update;
  if not found then raise exception 'Código no encontrado'; end if;
  if not v_admin and r.created_by is distinct from v_uid then
    raise exception 'No tienes permiso sobre este código' using errcode = '42501';
  end if;
  if r.voided_at is not null then raise exception 'Este código fue anulado y no se puede extender'; end if;
  if r.disabled then raise exception 'Este código está deshabilitado'; end if;

  select * into v_plan from public.plans where months = p_months;
  if not found or not v_plan.active then
    raise exception 'Ese plan no está disponible por ahora';
  end if;
  v_hours := (v_plan.months + v_plan.bonus_months) * 720;

  if not v_admin then
    v_cost := v_plan.months;
    select credits into v_balance from public.panel_users where user_id = v_uid for update;
    if v_balance < v_cost then
      raise exception 'Créditos insuficientes: necesitas %, tienes %', v_cost, v_balance;
    end if;
    update public.panel_users set credits = credits - v_cost where user_id = v_uid
    returning credits into v_balance;
    insert into public.credit_ledger (user_id, delta, balance_after, kind, code_id, note, actor)
    values (v_uid, -v_cost, v_balance, 'consumo', r.id,
            format('Extender %s · %s mes(es)%s', r.code, v_plan.months,
                   case when v_plan.bonus_months > 0 then ' + ' || v_plan.bonus_months || ' de regalo' else '' end),
            v_uid);
  end if;

  update public.access_codes c
     set duration_hours = case when c.activated_at is null then c.duration_hours + v_hours else c.duration_hours end,
         expires_at     = case when c.activated_at is null then null
                               else greatest(c.expires_at, now()) + make_interval(hours => v_hours) end,
         credits_cost   = c.credits_cost + v_cost,
         bonus_months   = c.bonus_months + v_plan.bonus_months
   where c.id = p_id
   returning * into r;
  return r;
end;
$$;

revoke all on function public.extend_code(uuid, integer) from public, anon;
grant execute on function public.extend_code(uuid, integer) to authenticated;
