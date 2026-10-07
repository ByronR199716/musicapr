// Edge Function "panel-users": solo el administrador puede crear revendedores,
// cambiarles la contraseña y bloquearlos/desbloquearlos.
// Crear cuentas necesita la clave service_role, que nunca sale del servidor.
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

const URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BANNED = "876000h"; // ~100 años

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply({ error: "Método no permitido" }, 405);

  // 1. ¿Quién llama? Debe ser administrador.
  const caller = createClient(URL, ANON, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    auth: { persistSession: false },
  });
  const { data: isAdmin, error: adminErr } = await caller.rpc("is_admin");
  if (adminErr || isAdmin !== true) return reply({ error: "Solo el administrador puede hacer esto" }, 403);

  const admin = createClient(URL, SERVICE, { auth: { persistSession: false } });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return reply({ error: "Solicitud inválida" }, 400); }
  const action = String(body.action ?? "");

  try {
    if (action === "create") {
      const email = String(body.email ?? "").trim().toLowerCase();
      const password = String(body.password ?? "");
      const name = String(body.name ?? "").trim().slice(0, 60) || null;
      const credits = Math.max(0, Math.floor(Number(body.credits ?? 0)) || 0);
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return reply({ error: "Correo inválido" }, 400);
      if (password.length < 8) return reply({ error: "La contraseña debe tener al menos 8 caracteres" }, 400);

      const { data: created, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
      if (error || !created.user) {
        const msg = /already|registered|exists/i.test(error?.message ?? "") ? "Ya existe una cuenta con ese correo" : (error?.message ?? "No se pudo crear");
        return reply({ error: msg }, 400);
      }
      const id = created.user.id;
      const { error: insErr } = await admin.from("panel_users").insert({ user_id: id, email, display_name: name });
      if (insErr) {
        await admin.auth.admin.deleteUser(id);
        return reply({ error: insErr.message }, 400);
      }
      if (credits > 0) {
        // Se registra como recarga del admin (queda en el historial)
        const { error: cErr } = await caller.rpc("admin_add_credits", { p_user: id, p_delta: credits, p_note: "Saldo inicial" });
        if (cErr) return reply({ ok: true, user_id: id, warning: "Usuario creado, pero no se pudieron cargar los créditos: " + cErr.message });
      }
      return reply({ ok: true, user_id: id });
    }

    const userId = String(body.user_id ?? "");
    const { data: target } = await admin.from("panel_users").select("user_id").eq("user_id", userId).maybeSingle();
    if (!target) return reply({ error: "Usuario no encontrado" }, 404);

    if (action === "set_password") {
      const password = String(body.password ?? "");
      if (password.length < 8) return reply({ error: "La contraseña debe tener al menos 8 caracteres" }, 400);
      const { error } = await admin.auth.admin.updateUserById(userId, { password });
      if (error) return reply({ error: error.message }, 400);
      return reply({ ok: true });
    }

    if (action === "set_active") {
      const active = body.active === true;
      const { error } = await admin.auth.admin.updateUserById(userId, { ban_duration: active ? "none" : BANNED });
      if (error) return reply({ error: error.message }, 400);
      await admin.from("panel_users").update({ active }).eq("user_id", userId);
      return reply({ ok: true });
    }

    if (action === "delete") {
      const { error } = await admin.auth.admin.deleteUser(userId);
      if (error) return reply({ error: error.message }, 400);
      return reply({ ok: true });
    }

    return reply({ error: "Acción desconocida" }, 400);
  } catch (e) {
    return reply({ error: (e as Error).message }, 500);
  }
});
