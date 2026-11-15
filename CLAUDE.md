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
- APK: pesa más de 25 MiB (límite de Cloudflare Pages), así que el CI lo sube a GitHub Releases (etiqueta `apk`) y https://saas-dag.pages.dev/descargas/saas-dag.apk (y `saas-dag-32bits.apk`) redirige ahí. Si el repo pasa a privado, hay que mover el APK a otro lugar público.
- Mapas: OpenStreetMap con `flutter_map`. Plano 2D interactivo (3D queda para fase 3).
- Este repo es PÚBLICO: nunca guardar secretos, contraseñas ni datos reales aquí.
- El repo `SOUD26/Saas-DAG` es de otra app: no usar.

## Reglas que no se rompen
- Vocabulario en pantalla: lo que en código/BD se llama `flagged`/`flag_reason` se muestra como **Alerta**. No renombrar lo interno.
- Roles (nombres de Isaac): Nosotros = `super_admin`, Administradores = `company_admin`, Clientes = `client`, Usuarios = `resident`, más `supervisor` y `guard`.
- El `super_admin` NO tiene acceso a biometría (decisión de diseño, protege a Isaac legalmente).
- Las reglas de permisos viven en SQL (RLS y funciones), no solo en la app. Cambios de permisos = migración + prueba de aislamiento.
- Quitar acceso = `active=false`; nunca borrar. Todo cambio sensible va a `audit_log`.
- Guarda: usuario + contraseña + cara + GPS, sin prueba de vida (decisión de Isaac). Si falla cámara/luz, entra con contraseña + GPS y queda marcado como alerta naranja.
- Alertas en 3 niveles para toda la app (`alerts.severity`): red = actuar ya, orange = revisar hoy, yellow = revisar cuando se pueda. Nunca se bloquea el inicio de turno.
- Supervisor: cara 1:1 contra su propia plantilla (por construir).
- Panel de accesos: cada módulo nuevo que tenga funciones delegables debe insertar sus permisos en la tabla `permissions` (key, label, module, description, grantable_to) en su migración; aparecen solos en el panel. Nunca agregar un permiso que el SQL (RLS/funciones) no haga cumplir: una casilla que no hace nada da falsa seguridad.
- Cada módulo que recolecta datos personales debe registrarlos en el documento `registro-datos-legal` del Project de claude.ai.
- Datos de RR. HH. (DPI, nacimiento, dirección, contacto de emergencia) viven en `staff_records`; los vencimientos y escaneos en `documents`. Nunca en `profiles`. Los ven la persona, el admin de su empresa y el súper admin; el supervisor solo ve teléfono, foto y contacto de emergencia (`staff_emergency_contact`) y el estado de documentos (`document_alerts`) de sus guardas.
- El rol no se cambia nunca (no hay permiso de columna). El admin de empresa no activa/desactiva a otro admin ni a sí mismo (trigger en `profiles`).
- La bitácora anota qué columnas cambiaron en datos personales, nunca los valores.
- Visitantes: la foto del DPI/licencia se guarda (decisión de Isaac, asume el riesgo) en el bucket privado `visitor_docs`; el guarda la sube pero no la ve; solo el admin de la empresa y el súper admin la ven y la borran (borrado a `audit_log`). El guarda no ve el historial de visitas ni el número completo del documento (solo los últimos 4).
- App del guarda: todo registro lleva id creado en el teléfono y su hora (`p_happened_at`); se envía por la cola de `guard_store.dart`. Una función nueva que use el guarda debe ser idempotente por ese id.

## Cómo trabajar
- Rama de trabajo: `app-login`. Pendiente fusionar a `main`.
- Antes de subir cambios: `flutter analyze`. Los *warnings* (imports/variables sin usar) rompen el CI; los *infos* no.
- Si Flutter no se puede instalar en el entorno, compilar vía GitHub Actions y leer el resultado con `gh run list --branch app-login` y `gh run view <id> --log | grep "error •"`.
- Cada migración SQL se aplica en Supabase y se guarda también en `supabase/migrations`.
- Nunca imprimir tokens en logs (el repo es público). El workflow ya oculta `cfut_…` y `Bearer …`.
- El CI usa bash con `pipefail`; el registro completo de cada build queda en la rama `ci-logs` (`git fetch origin ci-logs`, `git show FETCH_HEAD:logs/04-build-apk.txt`). Un plugin nativo nuevo puede romper solo el APK: reglas de R8 en `android/app/proguard-rules.pro` (las regenera `ci/patch_android.py`).
- Desde la terminal no se llega a `*.supabase.co`: probar almacenamiento por SQL (insertar en `storage.objects` como cada rol).
- Datos de demostración (empresa "Seguridad Demo", sitios `Demo · …`) deben borrarse antes del lanzamiento.

## Estado y pendientes
- Módulo 1 (autenticación y roles): terminado y probado. Cara = módulo aparte.
- Módulo 2 (sitios y personal): hecho y compilando, falta que Isaac lo pruebe en pantalla: pestaña Personal (crear usuario, cuenta activa, funciones extra, cambiar contraseña), Turnos con bitácora del guarda, selector de empresa para el súper admin.
- Fichas (2026-11-14): base de datos lista y probada (empresa + suscripción, cliente, ficha de personal, documentos con vencimiento, buckets privados `avatars`/`logos`/`documents`, bitácora de fichas y de turnos). Pruebas en `supabase/tests/modulo2_fichas_permisos.sql`.
- Formulario de alta y ficha (`lib/screens/admin/staff_form.dart`, datos en `staff_file.dart`): cuenta + foto + ficha + documentos; interruptores porta arma / conduce moto / conduce vehículo vuelven obligatoria la licencia; guardado con `staff_precheck` → cuenta → `save_staff_file` → foto. Tarjeta y lista de documentos en el Panel. Falta: subir escaneos, fichas de empresa y cliente en pantalla.
- Súper admin (`lib/screens/super/`): entra a "Panel general" con sus empresas; crea/edita empresas (datos, NIT, licencia DIGESSP, suscripción), las activa/suspende, crea administradores y usuarios con rol y abre el panel de cada empresa. Nadie se mueve de empresa ni cambia de rol desde la app (a propósito).
- Módulo del guarda, parte A (2026-11-15, plan y decisiones en el documento `plan-guardas` del Project): sitios con aprobación (el supervisor propone con `save_site`, el admin aprueba con `approve_site` o devuelve con `return_site`), puestos (`site_posts`) con consignas e inventario (`site_implements`), catálogo `implement_types` con color de alerta, relevo a ciegas (`submit_handover`, `post_checklist`) y bandeja única `alerts` de 3 niveles (red/orange/yellow). App en `lib/screens/sites/`, `lib/screens/supervisor/` y `lib/screens/admin/alert_views.dart`. Pruebas en `supabase/tests/guardas_sitios_relevo.sql`. La app ya no escribe `sites` directo (solo `active`).
- Módulo del guarda, parte B (2026-11-15): pantalla del guarda en `lib/screens/guard/` (turno con GPS, consignas, recibir/entregar puesto, ingresos con lector de placa y DPI en el teléfono, salidas, bitácora, supervisor con foto y llamada) que funciona sin señal (cola en el teléfono; el login aún necesita señal). `companies.face_required` (por defecto no). Admin: empresas que visitan, fotos de documentos, actividad del sitio e **historial de visitas** (`search_visits`, también para el supervisor). Pruebas: `guardas_turno_ingresos.sql`, `guardas_fotos_documento.sql`, `guardas_historial_visitas.sql`.
- Siguiente: Isaac prueba el guarda en el APK; aviso de privacidad en la garita; vincular teléfono↔sitio con QR; prueba de cara en teléfono real; "el relevo no llegó" y borrado automático de fotos viejas (requieren tarea programada). Propuestas sin aprobar: visitante frecuente y lista de "no permitir ingreso". Después: pantalla del supervisor completa; ficha del cliente; entrada única con cara configurable por empresa.
- Después: rondas con QR, alertas y pánico, portal del cliente.
- Antes del lanzamiento: decidir repo público/privado, llave de firma propia del APK, proveedor de mapas, plan Pro de Supabase, borrar datos demo.

La fuente completa de decisiones está en el Project "Saas-DAG" de claude.ai (`decisiones-base`).
