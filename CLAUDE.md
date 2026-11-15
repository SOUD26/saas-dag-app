# SaaS-DAG — contexto para Claude

## Quién es el usuario
Isaac es el arquitecto del producto. No programa, pero entiende la lógica completa. Habla solo español.
Claude es el experto técnico. Respuestas directas, en español, con UNA recomendación clara y su razón.
Si ves un camino mejor que el que propone Isaac, dilo y defiéndelo. Si algo tiene fallas, dilo primero.

## Producto
SaaS para empresas de seguridad (Guatemala): monitorear guardias y sitios, y ofrecer a sus clientes
(condominios, residenciales, ofibodegas) control de ingreso de visitantes y vehículos (módulo de pago aparte).

## Stack
- App Android + Web: Flutter (código en `lib/`).
- Base de datos y auth: Supabase, proyecto `tkjgavqmiyinhnvvckvo`. Migraciones en `supabase/migrations`, función `supabase/functions/admin-users`.
- CI y despliegue: `.github/workflows/build.yml`. Web en https://saas-dag.pages.dev (Cloudflare Pages), se actualiza al subir a la rama `app-login`.
- Mapas: OpenStreetMap con `flutter_map`. Plano 2D interactivo (3D queda para fase 3).
- Este repo es PÚBLICO: nunca guardar secretos, contraseñas ni datos reales aquí.
- El repo `SOUD26/Saas-DAG` es de otra app: no usar.

## Reglas que no se rompen
- Vocabulario en pantalla: lo que en código/BD se llama `flagged`/`flag_reason` se muestra como **Alerta**. No renombrar lo interno.
- Roles (nombres de Isaac): Nosotros = `super_admin`, Administradores = `company_admin`, Clientes = `client`, Usuarios = `resident`, más `supervisor` y `guard`.
- El `super_admin` NO tiene acceso a biometría (decisión de diseño, protege a Isaac legalmente).
- Las reglas de permisos viven en SQL (RLS y funciones), no solo en la app. Cambios de permisos = migración + prueba de aislamiento.
- Quitar acceso = `active=false`; nunca borrar. Todo cambio sensible va a `audit_log`.
- Guarda: usuario + contraseña + cara + GPS, sin prueba de vida (decisión de Isaac). Si falla cámara/luz, entra con contraseña + GPS y queda marcado como alerta.
- Supervisor: cara 1:1 contra su propia plantilla (por construir).
- Panel de accesos: cada módulo nuevo que tenga funciones delegables debe insertar sus permisos en la tabla `permissions` (key, label, module, description, grantable_to) en su migración; aparecen solos en el panel. Nunca agregar un permiso que el SQL (RLS/funciones) no haga cumplir: una casilla que no hace nada da falsa seguridad.
- Cada módulo que recolecta datos personales debe registrarlos en el documento `registro-datos-legal` del Project de claude.ai.

## Cómo trabajar
- Rama de trabajo: `app-login`. Pendiente fusionar a `main`.
- Antes de subir cambios: `flutter analyze`. Los *warnings* (imports/variables sin usar) rompen el CI; los *infos* no.
- Si Flutter no se puede instalar en el entorno, compilar vía GitHub Actions y leer el resultado con `gh run list --branch app-login` y `gh run view <id> --log | grep "error •"`.
- Cada migración SQL se aplica en Supabase y se guarda también en `supabase/migrations`.
- Nunca imprimir tokens en logs (el repo es público). El workflow ya oculta `cfut_…` y `Bearer …`.
- Datos de demostración (empresa "Seguridad Demo", sitios `Demo · …`) deben borrarse antes del lanzamiento.

## Estado y pendientes
- Módulo 1 (autenticación y roles): terminado y probado. Cara = módulo aparte.
- Módulo 2 (sitios y personal): hecho y compilando, falta que Isaac lo pruebe en pantalla: pestaña Personal (crear usuario, cuenta activa, funciones extra, cambiar contraseña), Turnos con bitácora del guarda, selector de empresa para el súper admin.
- Siguiente: pantalla del supervisor; asignar guardas a sitios; ubicación del sitio en el mapa; emparejar teléfono↔sitio (QR); entrada única con cara configurable por empresa; reconocimiento facial; auditoría de turnos.
- Después: rondas con QR, alertas y pánico, portal del cliente.
- Antes del lanzamiento: decidir repo público/privado, llave de firma propia del APK, proveedor de mapas, plan Pro de Supabase, borrar datos demo.

La fuente completa de decisiones está en el Project "Saas-DAG" de claude.ai (`decisiones-base`).
