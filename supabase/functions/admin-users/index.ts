// Función de servidor: crear usuarios y resetear contraseñas.
// Todas las reglas de "quién puede qué" viven en SQL (authorize_* / provision_user);
// aquí solo se identifica a quien llama y se usa la API de administración de Auth.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const ROLES = ["company_admin", "supervisor", "guard", "client"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const USERNAME = /^[a-z0-9._-]{3,30}$/;

class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

// deno-lint-ignore no-explicit-any
function dbError(e: any): HttpError {
  if (e?.code === "42501") return new HttpError(403, e.message);
  if (e?.code === "22023") return new HttpError(400, e.message);
  if (e?.code === "23505") return new HttpError(409, "Ya existe un usuario con ese correo o nombre de usuario");
  if (e?.code === "23514") return new HttpError(400, "Datos incompletos para ese rol");
  return new HttpError(500, "Error interno");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json(405, { error: "Método no permitido" });

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: who, error: authErr } = await admin.auth.getUser(token);
    if (authErr || !who?.user) throw new HttpError(401, "No autenticado");
    const caller = who.user.id;

    let body: Record<string, unknown>;
    try { body = await req.json(); } catch { throw new HttpError(400, "JSON inválido"); }

    if (body.action === "create_user") return json(200, await createUser(admin, caller, body));
    if (body.action === "reset_password") return json(200, await resetPassword(admin, caller, body));
    throw new HttpError(400, "Acción desconocida");
  } catch (e) {
    if (e instanceof HttpError) return json(e.status, { error: e.message });
    console.error(e);
    return json(500, { error: "Error interno" });
  }
});

// deno-lint-ignore no-explicit-any
async function createUser(admin: any, caller: string, b: Record<string, unknown>) {
  const role = String(b.role ?? "");
  const company = String(b.company_id ?? "");
  const client = b.client_id ? String(b.client_id) : null;
  const fullName = String(b.full_name ?? "").trim();
  const password = b.password ? String(b.password) : null;

  if (!ROLES.includes(role)) throw new HttpError(400, "Rol inválido");
  if (!UUID.test(company)) throw new HttpError(400, "Empresa inválida");
  if (client && !UUID.test(client)) throw new HttpError(400, "Cliente inválido");
  if (!fullName) throw new HttpError(400, "Nombre requerido");
  if (password && password.length < 8) throw new HttpError(400, "La contraseña debe tener al menos 8 caracteres");

  let email: string;
  let username: string | null = null;
  if (role === "guard") {
    // Los guardas entran con usuario + contraseña. Auth exige un correo, así que se
    // construye uno interno que nunca recibe mensajes: usuario@<empresa>.guardas.invalid
    username = String(b.username ?? "").trim().toLowerCase();
    if (!USERNAME.test(username)) throw new HttpError(400, "Usuario inválido (3 a 30 caracteres: letras, números, . _ -)");
    if (!password) throw new HttpError(400, "La contraseña es requerida para guardas");
    email = `${username}@${company}.guardas.invalid`;
  } else {
    email = String(b.email ?? "").trim().toLowerCase();
    if (!EMAIL.test(email)) throw new HttpError(400, "Correo inválido");
  }
  const profileEmail = role === "guard" ? null : email;

  // 1) ¿Está autorizado quien llama? (antes de crear nada)
  const auth = await admin.rpc("authorize_user_creation", {
    p_caller: caller, p_role: role, p_company: company, p_client: client,
  });
  if (auth.error) throw dbError(auth.error);

  // 2) Crear el usuario en Auth (correo confirmado: entra con Google si el correo coincide, o con contraseña)
  const created = await admin.auth.admin.createUser({
    email, password: password ?? undefined, email_confirm: true, user_metadata: { full_name: fullName },
  });
  if (created.error || !created.data?.user) {
    const msg = String(created.error?.message ?? "");
    if (/already|registered|exists/i.test(msg)) throw new HttpError(409, "Ya existe un usuario con ese correo o nombre de usuario");
    console.error("createUser", msg);
    throw new HttpError(400, "No se pudo crear el usuario");
  }
  const newId = created.data.user.id as string;

  // 3) Crear el perfil y la bitácora; si falla, deshacer el usuario de Auth
  const prov = await admin.rpc("provision_user", {
    p_caller: caller, p_new_id: newId, p_role: role, p_company: company, p_client: client,
    p_full_name: fullName, p_username: username, p_email: profileEmail,
  });
  if (prov.error) {
    await admin.auth.admin.deleteUser(newId);
    throw dbError(prov.error);
  }
  return { id: newId };
}

// deno-lint-ignore no-explicit-any
async function resetPassword(admin: any, caller: string, b: Record<string, unknown>) {
  const target = String(b.user_id ?? "");
  const password = String(b.password ?? "");
  if (!UUID.test(target)) throw new HttpError(400, "Usuario inválido");
  if (password.length < 8) throw new HttpError(400, "La contraseña debe tener al menos 8 caracteres");

  const auth = await admin.rpc("authorize_user_management", { p_caller: caller, p_target: target });
  if (auth.error) throw dbError(auth.error);

  const upd = await admin.auth.admin.updateUserById(target, { password });
  if (upd.error) throw new HttpError(400, "No se pudo cambiar la contraseña");

  const log = await admin.rpc("log_password_reset", { p_caller: caller, p_target: target });
  if (log.error) console.error("log_password_reset", log.error.message);
  return { ok: true };
}
