# saas-dag-app
Administración de empresas de seguridad (SaaS).

Stack: Flutter (Android + Web), Supabase (base de datos y autenticación), Cloudflare Pages (web).

## Estructura
- `supabase/migrations/`: la base de datos, en orden. Cada archivo ya está aplicado en el proyecto de Supabase.
- `supabase/functions/admin-users/`: función de servidor para crear usuarios y resetear contraseñas.

## Roles
| Rol | Quién es | Cómo entra |
|---|---|---|
| `super_admin` | Dueño de la plataforma | Google |
| `company_admin` | Empresa de seguridad (cliente de la plataforma) | Google o correo + contraseña |
| `supervisor` | Supervisor de la empresa | Correo + contraseña |
| `guard` | Guarda | Usuario + contraseña + cara + GPS (en el teléfono del sitio) |
| `client` | Condominio u ofibodega (cliente de la empresa) | Google o correo + contraseña |

## Quién crea a quién (lo hace cumplir la base de datos)
- El `super_admin` puede crear usuarios de cualquier empresa, menos otro `super_admin` (ese se crea a mano con SQL).
- El `company_admin` crea `company_admin`, `supervisor`, `guard` y `client` solo en su empresa.
- Nadie se registra solo: el registro público de Supabase Auth debe estar **desactivado**.
- Un usuario de Google entra solo si un administrador ya creó su perfil con **ese mismo correo**. Si no, queda autenticado pero sin acceso a nada.

## Entrada de los guardas
Auth exige un correo, así que cada guarda tiene uno interno que nunca recibe mensajes:
`<usuario>@<id-de-la-empresa>.guardas.invalid`. El teléfono vinculado al sitio conoce el id de la empresa; el guarda solo escribe su usuario y contraseña.

## Llamar a la función de servidor
`POST https://<proyecto>.supabase.co/functions/v1/admin-users` con el token de quien llama en `Authorization: Bearer ...`.
- Crear usuario: `{"action":"create_user","role":"guard","company_id":"...","full_name":"...","username":"...","password":"..."}`
  (para roles con correo: `email` en lugar de `username`; `client_id` solo para el rol `client`; `password` opcional si entrará con Google).
- Resetear contraseña: `{"action":"reset_password","user_id":"...","password":"..."}`

## Pendiente de verificar con la primera prueba real
- Que Auth acepte los correos internos `.invalid` de los guardas.
- Que un usuario creado sin contraseña se enlace con su cuenta de Google al entrar por primera vez.
