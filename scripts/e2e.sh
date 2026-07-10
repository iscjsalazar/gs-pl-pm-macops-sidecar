#!/usr/bin/env bash
# Orquestador E2E local del camino Programa Maestro (solicitud e2e-launch-orchestration).
# Compone los targets de tier ya existentes (wt-up, legacy-launch, e2e-net-check) y agrega el last-mile:
# inyeccion del wiring de aplicacion al backend .NET 10 en el deploy del legado, activacion del feature flag
# y un smoke funcional legacy-driven de la validacion de paridad (los WCF ejecutar/obtener_estado/obtener_reporte
# _paridad son REST sin auth). El intake flag-gated (OrdenesNuevasCargar_LN, load-async) es UI-driven -> navegador.
#
# Ruta: wt (backend por slot sobre el SQL compartido de nvoslabs). Ese SQL solo escucha en el loopback de
# macdata, asi que e2e-up levanta un PUENTE (socat) para que el guest Windows lo alcance por la pasarela NAT.
# La M1 es SOLO el orquestador: todo el runtime (backend wt, VM del legado, puente, data tier) vive en macdata,
# manejado por SSH. El disparo del smoke va macdata -> guest DIRECTO; el tunel del legado es solo para acceso
# humano a la UI, no lo usa el smoke. Idempotente.
#
# TODO es per-slot: backend (pm-wt<N>-api), BD (pm_planning_wt<N>), Oracle ControlPiso (pm-wt<N>-oracle-1),
# site IIS del legado (pm-wt<N>:8100+N) y tunel (18100+N). Dos sesiones con slots distintos corren en paralelo
# sin pisarse: por eso el camino con el feature flag OFF (PGE950RT escribe en ControlPiso) ya no contamina a
# las demas. Compartidos y administrados como singletons: SQL Server (motor), bus, puente 60211, pm_erpln106.
#
#   make e2e-up    WT=<folder> LEGACYSRC=<path>   # data tier + backend(slot) + Oracle(slot) + puente SQL + legacy(+inyeccion) + flag ON + smoke
#   make e2e-smoke WT=<folder>                    # solo el smoke funcional (asume e2e-up ya dejo todo arriba)
#   make e2e-down  WT=<folder>                    # baja tunel + site + API + Oracle del slot + puente (singletons intactos)
#   make e2e-down  WT=<folder> ... PM_E2E_KEEP_FRONT=1   # conserva el site del legado (re-usar con FORCE=1)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/worktrees.sh"
set +e   # common.sh fija 'set -e'; el driver reporta y decide, no aborta a mitad.
load_env
# El backend wt, el SQL compartido y el bus viven en macdata; fija el contexto docker remoto (colima-nlc3runner).
wt_require_intel || { printf 'ERROR [e2e]: requiere PM_TARGET=intel y REMOTE=macdata\n' >&2; exit 2; }

VERB="${1:-up}"

# --- inputs (el Makefile traduce las vars cortas a estas) ---
WT="${WT:-}"                                    # worktree de pl-programa-maestro (PL.PM.sln) -> slot del backend
LEGACY_SRC="${PM_E2E_LEGACY_SRC:-}"             # fuente del legado en develop (ProgramaMaestroPT.sln + el gateway)
PLANTA="${PM_E2E_PLANTA:-RES}"                  # etiqueta de planta del legado (RES -> RT en el backend)
LINEA="${PM_E2E_LINEA:-}"                       # lineaFab del disparo (solo lo usa el camino Oracle/OFF)
ANOF="${PM_E2E_ANOF:-0}"                        # anio fiscal del disparo (idem)
SEMF="${PM_E2E_SEMF:-0}"                        # semana fiscal del disparo (idem)
FLAG_FINAL="${PM_E2E_FLAG_FINAL:-on}"          # estado del flag al terminar e2e-up (on|off)
# Vacios = derivados del slot (tunel 18100+N, site 8100+N). Un valor explicito los sobreescribe.
TUNNEL="${PM_E2E_TUNNEL:-}"                     # tunel del legado para acceso humano a la UI (no lo usa el smoke)
SITEPORT="${PM_E2E_SITE_PORT:-}"                # puerto IIS del site del slot (el smoke dispara aqui via macdata)
FORCE="${PM_E2E_FORCE:-0}"                      # 1 = re-deploy del legado aunque health 200 (re-inyecta wiring)
SQL_PM_HOST_OVERRIDE="${PM_E2E_SQL_PM_HOST:-}"  # override del host,puerto del SQL del flag (vacio = puente)
BRIDGE_PORT="${PM_E2E_BRIDGE_PORT:-60211}"      # puerto host (bridge) del puente -> shared SQL
BRIDGE_NAME="pm-e2e-sqlbridge"
BRIDGE_IMAGE="${PM_E2E_BRIDGE_IMAGE:-alpine/socat}"
# El puente es un singleton administrado (como el bus): 'e2e-down' NO lo baja salvo peticion explicita, porque
# lo comparten todos los slots y un blip del 60211 hace que los demas frontends lean el flag como OFF.
BRIDGE_DOWN="${PM_E2E_BRIDGE_DOWN:-0}"
# 'e2e-down' desmonta el site del legado del slot por simetria con wt-down (que borra API y BD). 1 lo conserva.
KEEP_FRONT="${PM_E2E_KEEP_FRONT:-0}"

VDIR="ProgramaMaestroLN"
# Componentes WCF de la pantalla ValidacionParidad (260701-2323): disparo async + poll de estado + reporte.
SVC_PARITY_RUN="$VDIR/Services/WCFobtenerDatos.svc/ejecutar_validacion_paridad"
SVC_PARITY_STATUS="$VDIR/Services/WCFobtenerDatos.svc/obtener_estado_paridad"
SVC_PARITY_REPORT="$VDIR/Services/WCFobtenerDatos.svc/obtener_reporte_paridad"
# Slice del disparo de paridad (acotado): mismos parámetros que la pantalla; overridable por entorno.
PARITY_LINEA="${PM_E2E_PARITY_LINEA:-PE9}"
PARITY_ANOF="${PM_E2E_PARITY_ANOF:-2026}"
PARITY_SEMF="${PM_E2E_PARITY_SEMF:-23}"
PARITY_MODO="${PM_E2E_PARITY_MODO:-acotado}"
# Credenciales del login de solo-lectura pm_reader para ConStrJobsReader (seed planning/0301-jobs-reader-login.sql).
JOBS_READER_USER="${PM_E2E_SQL_READER_USER:-pm_reader}"
JOBS_READER_PASS="${PM_E2E_SQL_READER_PASS:-Pm_Reader_2026!}"

elog(){ printf '== [e2e] %s\n' "$*"; }
ewarn(){ printf 'AVISO [e2e]: %s\n' "$*" >&2; }
edie(){ printf 'ERROR [e2e]: %s\n' "$*" >&2; exit 1; }

# --- resolucion de slot / backend ---

# Intento TOLERANTE de resolver el slot: 0 si lo resolvio, 1 si no. No aborta (cmd_down lo usa para degradar).
e2e_slot_try(){
  [ -n "$WT" ] || return 1
  E2E_SLOT="$(wt_slot_lookup "$WT")"
  [ -n "$E2E_SLOT" ] || return 1
  wt_derive "$E2E_SLOT"     # PM_PLANNING_DB=pm_planning_wt<N>, PM_PORT_OFFSET, WT_ORACLE_*, WT_SITE_*, etc.
  return 0
}

# Resuelve el slot del backend (asignado por wt-up) o aborta. Lo usan cmd_up y cmd_smoke.
e2e_slot(){
  [ -n "$WT" ] || edie "falta WT=<folder> (worktree de pl-programa-maestro con PL.PM.sln; la ruta wt levanta el backend por slot)"
  e2e_slot_try || edie "el worktree '$WT' no tiene slot asignado; corre 'make e2e-up' (invoca wt-up) antes de e2e-smoke/e2e-down"
}

# Puertos del frontend del slot. Un SITEPORT/TUNNEL explicito gana; si no, se derivan del slot. Sin slot
# resuelto (solo cmd_down degradado) caen a los defaults del singleton.
e2e_derive_front_ports(){
  if [ -n "${E2E_SLOT:-}" ]; then
    SITEPORT="${SITEPORT:-$WT_SITE_PORT}"
    TUNNEL="${TUNNEL:-$WT_TUNNEL_PORT}"
  else
    SITEPORT="${SITEPORT:-8080}"
    TUNNEL="${TUNNEL:-18080}"
  fi
}

# Puerto host REALMENTE publicado por el contenedor de la API del slot (fuente de verdad; evita asumir el
# offset de PM_API_PORT, que load_env fija una sola vez). Fallback: PM_API_PORT.
e2e_api_port(){
  local ctx p; ctx="$(remote_docker_ctx)"
  p="$(on_intel "docker $ctx port 'pm-wt${E2E_SLOT}-api' 8080/tcp 2>/dev/null" 2>/dev/null | head -1 | sed 's/.*://' | tr -d '\r')"
  printf '%s' "${p:-$PM_API_PORT}"
}

# Puerto host REALMENTE publicado por el Oracle del slot. Fallback: la base de load_env + slot (NUNCA una
# constante literal: PM_WT_ORACLE_PORT_BASE es configurable).
e2e_oracle_port(){
  local ctx p; ctx="$(remote_docker_ctx)"
  p="$(on_intel "docker $ctx port 'pm-wt${E2E_SLOT}-oracle-1' 1521/tcp 2>/dev/null" 2>/dev/null | head -1 | sed 's/.*://' | tr -d '\r')"
  printf '%s' "${p:-$(( PM_WT_ORACLE_PORT_BASE + E2E_SLOT ))}"
}

# Wiring REALMENTE desplegado en el site del slot (clave=valor). Fuente de verdad: el valor solo vive en el guest.
e2e_deployed_wiring(){
  ssh -o ConnectTimeout=15 "$PM_REMOTE_SSH" "WINHOST=$PM_GUEST_WINHOST SLOT=$E2E_SLOT bash ~/pm-host-windows/scripts/read-wiring.sh" 2>/dev/null
}

# ¿El site del slot esta cableado a SU backend, SU Oracle y SU catalogo? Los tres tienen que coincidir: un
# slot reciclado hereda el sitio anterior y el skip por health 200 conservaria su wiring en silencio.
e2e_wiring_matches(){  # uso: e2e_wiring_matches <salida-de-read-wiring>
  local w="$1" ok=0 dep_oracle dep_backend dep_pm dep_reader
  dep_oracle="$(printf '%s\n' "$w"  | sed -n 's/^oraclePort=//p' | head -1)"
  dep_backend="$(printf '%s\n' "$w" | sed -n 's/^backendBaseUrl=//p' | head -1)"
  dep_pm="$(printf '%s\n' "$w"      | sed -n 's/^ConStrPm=//p' | head -1)"
  dep_reader="$(printf '%s\n' "$w"  | sed -n 's/^ConStrJobsReader=//p' | head -1)"
  [ "$dep_oracle" = "$E2E_ORACLE_PORT" ] || { ewarn "      oraclePort desplegado='$dep_oracle' esperado='$E2E_ORACLE_PORT'"; ok=1; }
  [ "$dep_backend" = "$BACKEND_URL" ]    || { ewarn "      backendBaseUrl desplegado='$dep_backend' esperado='$BACKEND_URL'"; ok=1; }
  case "$dep_pm" in
    *"Initial Catalog=$PM_PLANNING_DB;"*) : ;;
    *) ewarn "      ConStrPm no apunta a 'Initial Catalog=$PM_PLANNING_DB' (desplegado: ${dep_pm:-<ausente>})"; ok=1 ;;
  esac
  case "$dep_reader" in
    *"Initial Catalog=$PM_PLANNING_DB;"*) : ;;
    *) ewarn "      ConStrJobsReader no apunta a 'Initial Catalog=$PM_PLANNING_DB' (desplegado: ${dep_reader:-<ausente>})"; ok=1 ;;
  esac
  return "$ok"
}

# Conteos de las tablas que muta el camino con el flag OFF (PGE950RT: DELETE ordenes_nuevas_pm_t, UPDATE
# ordenes, INSERT tipge951, DELETE/INSERT resumen_carga_pm). Formato: ordenes|tipge951|ordenes_nuevas_pm_t|resumen_carga_pm
e2e_oracle_counts(){  # uso: e2e_oracle_counts <contenedor-oracle>
  local cont="$1" ctx; ctx="$(remote_docker_ctx)"
  printf 'set head off feed off pages 0;\nselect (select count(*) from ordenes)||%s||(select count(*) from tipge951)||%s||(select count(*) from ordenes_nuevas_pm_t)||%s||(select count(*) from resumen_carga_pm) from dual;\n' "chr(124)" "chr(124)" "chr(124)" \
    | on_intel "docker $ctx exec -i -e ORACLE_HOME='${PM_WT_ORACLE_HOME}' '$cont' bash -c 'export PATH=\$ORACLE_HOME/bin:\$PATH; exec sqlplus -S ${PM_WT_ORACLE_USER}/${PM_WT_ORACLE_PASS}@localhost:1521/XE'" 2>/dev/null \
    | tr -d '[:blank:]\r' | grep -E '^[0-9]+\|' | tail -1
}

# Filas de menu de work-centers / manufacturing-lines (evidencia del seed 9003).
e2e_oracle_menu_rows(){  # uso: e2e_oracle_menu_rows <contenedor-oracle>
  local cont="$1" ctx; ctx="$(remote_docker_ctx)"
  printf "set head off feed off pages 0;\nselect count(*) from menu_contenido where pagina in ('CentroTrabajo.aspx','LineaFabricacion.aspx');\n" \
    | on_intel "docker $ctx exec -i -e ORACLE_HOME='${PM_WT_ORACLE_HOME}' '$cont' bash -c 'export PATH=\$ORACLE_HOME/bin:\$PATH; exec sqlplus -S ${PM_WT_ORACLE_USER}/${PM_WT_ORACLE_PASS}@localhost:1521/XE'" 2>/dev/null \
    | tr -d '[:blank:]\r' | grep -E '^[0-9]+$' | tail -1
}

# Verbo de evidencia: fotografia de los dos Oracle (el del slot y el singleton compartido). Es el instrumento
# de ac3 -- se corre ANTES y DESPUES de una carga con el flag OFF: el del slot cambia, el singleton NO.
# Tambien reporta las filas de menu (ac11) de ambos.
cmd_oracle_counts(){
  e2e_slot
  local ctx slot_c="pm-wt${E2E_SLOT}-oracle-1" single_c="${PM_E2E_SINGLETON_ORACLE:-pm-local-oracle-1}"
  ctx="$(remote_docker_ctx)"
  printf '%-24s %-40s %s\n' 'CONTENEDOR' 'ordenes|tipge951|ord_nuevas|resumen' 'menu(CT+LF)'
  local c m
  if on_intel "[ \"\$(docker $ctx inspect -f '{{.State.Running}}' '$slot_c' 2>/dev/null)\" = true ]" 2>/dev/null; then
    c="$(e2e_oracle_counts "$slot_c")"; m="$(e2e_oracle_menu_rows "$slot_c")"
    printf '%-24s %-40s %s\n' "$slot_c" "${c:-<sin respuesta>}" "${m:-?}"
  else
    printf '%-24s %s\n' "$slot_c" '<no corre; make wt-up WT=... ORACLE=1>'
  fi
  if on_intel "[ \"\$(docker $ctx inspect -f '{{.State.Running}}' '$single_c' 2>/dev/null)\" = true ]" 2>/dev/null; then
    c="$(e2e_oracle_counts "$single_c")"; m="$(e2e_oracle_menu_rows "$single_c")"
    printf '%-24s %-40s %s\n' "$single_c" "${c:-<sin respuesta>}" "${m:-?}"
  else
    printf '%-24s %s\n' "$single_c" '<no corre>'
  fi
}

# --- puente SQL (socat) para que el guest alcance el SQL compartido (loopback de macdata) ---

# Un contenedor socat unido a la red del SQL compartido publica 0.0.0.0:BRIDGE_PORT -> sqlserver:1433, asi el
# guest lo ve por la pasarela NAT (172.16.128.1:BRIDGE_PORT). Idempotente.
#
# El puente es COMPARTIDO por todos los slots. El 'docker rm -f' incondicional que hacia esta funcion mataba el
# puente recien creado por otra sesion (blip del 60211 -> los demas frontends leen el flag como OFF en
# silencio). Ahora: se crea SOLO si esta ausente, bajo lock, y ante 'name already in use' se adopta el ajeno.
_e2e_bridge_up_locked(){
  local ctx; ctx="$(remote_docker_ctx)"
  if on_intel "[ \"\$(docker $ctx inspect -f '{{.State.Running}}' '$BRIDGE_NAME' 2>/dev/null)\" = true ]" 2>/dev/null; then
    elog "puente SQL ya arriba ($BRIDGE_NAME en :$BRIDGE_PORT)"; return 0
  fi
  # Existe pero no corre (o quedo a medias): recrearlo es seguro, nadie lo esta usando.
  on_intel "docker $ctx inspect '$BRIDGE_NAME' >/dev/null 2>&1 && docker $ctx rm -f '$BRIDGE_NAME' >/dev/null 2>&1; true"
  elog "puente SQL: asegurando imagen $BRIDGE_IMAGE ..."
  on_intel "docker $ctx image inspect '$BRIDGE_IMAGE' >/dev/null 2>&1 || docker $ctx pull '$BRIDGE_IMAGE'" \
    || edie "no se pudo obtener la imagen del puente ($BRIDGE_IMAGE); macdata sin internet? fija PM_E2E_BRIDGE_IMAGE a una imagen socat presente"
  elog "puente SQL: $BRIDGE_NAME (red $PM_SHARED_SQL_NETWORK; publica $BRIDGE_PORT -> $PM_SHARED_SQL_HOST:$PM_SHARED_SQL_PORT) ..."
  if ! on_intel "docker $ctx run -d --name '$BRIDGE_NAME' --network '$PM_SHARED_SQL_NETWORK' -p '$BRIDGE_PORT:1433' --restart unless-stopped '$BRIDGE_IMAGE' TCP-LISTEN:1433,fork,reuseaddr TCP:$PM_SHARED_SQL_HOST:$PM_SHARED_SQL_PORT >/dev/null"; then
    # Carrera con otra sesion: si el suyo quedo corriendo, se adopta en vez de fallar.
    if on_intel "[ \"\$(docker $ctx inspect -f '{{.State.Running}}' '$BRIDGE_NAME' 2>/dev/null)\" = true ]" 2>/dev/null; then
      elog "puente SQL lo creo otra sesion en paralelo; se adopta ($BRIDGE_NAME)"
      return 0
    fi
    edie "fallo al levantar el puente SQL ($BRIDGE_NAME)"
  fi
}
e2e_bridge_up(){ wt_lock bridge _e2e_bridge_up_locked; }

# Opt-in: por default el puente queda arriba como singleton administrado (mismo trato que el bus). Bajarlo
# desde un e2e-down cortaria la lectura del flag de TODOS los demas slots.
e2e_bridge_down(){
  if [ "$BRIDGE_DOWN" != "1" ]; then
    elog "puente SQL conservado ($BRIDGE_NAME; singleton compartido). PM_E2E_BRIDGE_DOWN=1 para bajarlo."
    return 0
  fi
  local ctx; ctx="$(remote_docker_ctx)"
  on_intel "docker $ctx rm -f '$BRIDGE_NAME' >/dev/null 2>&1; true" && elog "puente SQL bajado ($BRIDGE_NAME)"
}

# Prueba TCP desde el guest hacia un host:puerto de macdata (pasarela NAT). Aborta si no conecta.
e2e_check_guest_tcp(){  # uso: e2e_check_guest_tcp <host> <puerto> <etiqueta>
  local host="$1" port="$2" label="$3" ok
  ok="$(ssh -o ConnectTimeout=10 "$PM_REMOTE_SSH" \
    "ssh -i $PM_GUEST_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12 Administrator@$PM_GUEST_WINHOST \"powershell -NoProfile -Command '(Test-NetConnection -ComputerName $host -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded'\"" 2>/dev/null | tr -d ' \r\n')"
  case "$ok" in
    *[Tt]rue*) elog "guest -> $label ($host:$port) OK" ;;
    *) edie "el guest NO alcanza $label ($host:$port). Revisa el contenedor que publica ese puerto y el firewall de macdata" ;;
  esac
}

# Verifica que el guest alcance el SQL del flag. Falla rapido: sin esto el legado cae a OFF silencioso (atrapa
# la excepcion del flag-read y usa Oracle), y el caso ON del smoke nunca pasaria.
e2e_check_guest_sql(){
  local host="${SQL_PM_HOST%%,*}" port="${SQL_PM_HOST##*,}" ok
  ok="$(ssh -o ConnectTimeout=10 "$PM_REMOTE_SSH" \
    "ssh -i $PM_GUEST_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12 Administrator@$PM_GUEST_WINHOST \"powershell -NoProfile -Command '(Test-NetConnection -ComputerName $host -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded'\"" 2>/dev/null | tr -d ' \r\n')"
  case "$ok" in
    *[Tt]rue*) elog "guest -> SQL del flag ($host:$port) OK" ;;
    *) edie "el guest NO alcanza el SQL del flag ($host:$port): el legado caeria a OFF silencioso. Revisa el puente ($BRIDGE_NAME) y el firewall de macdata sobre :$port" ;;
  esac
}

# Lanza el legado EN EL SLOT. SLOT/SITEPORT/TUNNEL/ORACLEPORT/DBHOST viajan como VARIABLES DE MAKE: LEGACY_ENV
# las expande como prefijo de la linea de comando de la receta, asi que un valor pasado por entorno se pisaria
# en silencio (todos los frontends acabarian apuntando al Oracle singleton :1521).
e2e_legacy_launch(){  # uso: e2e_legacy_launch [force]
  local force="${1:-$FORCE}"
  PM_LEGACY_BACKEND_URL="$BACKEND_URL" \
  PM_LEGACY_SQL_PM_HOST="$SQL_PM_HOST" \
  PM_LEGACY_SQL_PM_DB="$PM_PLANNING_DB" \
  PM_LEGACY_SQL_PM_USER="sa" \
  PM_LEGACY_SQL_PM_PASS="$E2E_SQL_PW" \
  PM_LEGACY_SQL_READER_USER="$JOBS_READER_USER" \
  PM_LEGACY_SQL_READER_PASS="$JOBS_READER_PASS" \
  make -C "$BASE_DIR" legacy-launch SOLUTION="$LEGACY_SRC" \
    SLOT="$E2E_SLOT" SITEPORT="$SITEPORT" TUNNEL="$TUNNEL" \
    ORACLEPORT="$E2E_ORACLE_PORT" DBHOST="$PM_GUEST_GATEWAY" FORCE="$force"
}

# --- feature flag y ordenes (contra el SQL compartido, BD del slot) ---

# Asegura el esquema del feature flag (FeatureManagement) en la BD del backend. PUENTE TEMPORAL: el seed de
# wt-up y el arranque de la API no aplican la migracion InitialFeatureManagement (PR 1762 feat(pm): feature
# flags store), asi que la tabla/vista del flag faltan en pm_planning_wt<N> y el legado leeria OFF. Esto refleja
# esa migracion (idempotente; solo crea lo ausente). Follow-up (scope pm): incluir FeatureManagement en el seed
# del backend o aplicar migraciones EF en wt-up; cuando eso ocurra, esta funcion queda como no-op.
e2e_ensure_flag_schema(){
  local pw; pw="$(wt_shared_sql_password)" || { ewarn "sin SA del SQL compartido: no se asegura el esquema del flag"; return 1; }
  local sql="SET NOCOUNT ON; USE [$PM_PLANNING_DB];
IF SCHEMA_ID(N'FeatureManagement') IS NULL EXEC('CREATE SCHEMA [FeatureManagement]');
IF OBJECT_ID(N'FeatureManagement.FeatureFlags') IS NULL CREATE TABLE [FeatureManagement].[FeatureFlags]([Key] nvarchar(128) NOT NULL,[Plant] nvarchar(16) NOT NULL,[IsEnabled] bit NOT NULL,[Description] nvarchar(512) NULL,[UpdatedAt] datetime2 NOT NULL,CONSTRAINT [PK_FeatureFlags] PRIMARY KEY ([Key],[Plant]));
IF OBJECT_ID(N'FeatureManagement.vwFeatureFlags') IS NULL EXEC('CREATE VIEW [FeatureManagement].[vwFeatureFlags] AS SELECT [Key],[Plant],[IsEnabled],[Description],[UpdatedAt] FROM [FeatureManagement].[FeatureFlags]');
IF NOT EXISTS (SELECT 1 FROM [FeatureManagement].[FeatureFlags] WHERE [Key]='carga-backend' AND [Plant]='$PLANTA') INSERT INTO [FeatureManagement].[FeatureFlags]([Key],[Plant],[IsEnabled],[Description],[UpdatedAt]) VALUES (N'carga-backend',N'$PLANTA',0,N'Deriva la carga del Programa Maestro al backend .NET 10 (planta RES/RT) en vez del SP Oracle PGE950RT.',SYSUTCDATETIME());
IF NOT EXISTS (SELECT 1 FROM [FeatureManagement].[FeatureFlags] WHERE [Key]='login-skip-password' AND [Plant]='$PLANTA') INSERT INTO [FeatureManagement].[FeatureFlags]([Key],[Plant],[IsEnabled],[Description],[UpdatedAt]) VALUES (N'login-skip-password',N'$PLANTA',1,N'PRUEBAS: permite login con contrasena vacia para agilizar la validacion viva. NUNCA se habilita en dev/prod.',SYSUTCDATETIME());
ELSE UPDATE [FeatureManagement].[FeatureFlags] SET IsEnabled=1,UpdatedAt=SYSUTCDATETIME() WHERE [Key]='login-skip-password' AND [Plant]='$PLANTA';"
  if wt_shared_exec "$pw" "$sql" >/dev/null 2>&1; then
    elog "esquema del feature flag asegurado en $PM_PLANNING_DB (carga-backend + login-skip-password=ON [solo pruebas])"
  else
    ewarn "no se pudo asegurar el esquema del flag en $PM_PLANNING_DB"
  fi
}

# Asegura el login de solo-lectura pm_reader + GRANT SELECT sobre el schema Jobs en la BD del slot, para que el
# legado lea el estado de jobs via ConStrJobsReader. Refleja containers/sql/init/planning/0301-jobs-reader-login.sql
# (idempotente). El schema Jobs lo crea la migracion EF del backend al arrancar (wt-up); el GRANT a nivel de
# schema cubre las vistas vwBacklogLoadStatus/vwJobStatus creadas luego.
e2e_ensure_jobs_reader(){
  local pw; pw="$(wt_shared_sql_password)" || { ewarn "sin SA del SQL compartido: no se asegura pm_reader"; return 1; }
  local sql="SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name=N'$JOBS_READER_USER') CREATE LOGIN [$JOBS_READER_USER] WITH PASSWORD=N'$(wt_esc "$JOBS_READER_PASS")', CHECK_POLICY=OFF;
USE [$PM_PLANNING_DB];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name=N'$JOBS_READER_USER') CREATE USER [$JOBS_READER_USER] FOR LOGIN [$JOBS_READER_USER];
IF SCHEMA_ID(N'Jobs') IS NOT NULL GRANT SELECT ON SCHEMA::[Jobs] TO [$JOBS_READER_USER];"
  if wt_shared_exec "$pw" "$sql" >/dev/null 2>&1; then
    elog "login lector $JOBS_READER_USER asegurado + GRANT SELECT en schema Jobs ($PM_PLANNING_DB)"
  else
    ewarn "no se pudo asegurar $JOBS_READER_USER/GRANT en $PM_PLANNING_DB (¿schema Jobs aun no creado por la migracion?)"
  fi
}

e2e_set_flag(){  # uso: e2e_set_flag <0|1>
  local v="$1" pw; pw="$(wt_shared_sql_password)" || { ewarn "sin SA del SQL compartido: no se fijo el flag"; return 1; }
  local sql="SET NOCOUNT ON; USE [$PM_PLANNING_DB]; UPDATE FeatureManagement.FeatureFlags SET IsEnabled=$v, UpdatedAt=SYSUTCDATETIME() WHERE [Key]='carga-backend' AND Plant='$PLANTA';"
  if wt_shared_exec "$pw" "$sql" >/dev/null 2>&1; then
    elog "feature flag carga-backend/$PLANTA -> IsEnabled=$v (BD $PM_PLANNING_DB)"
  else
    ewarn "no se pudo fijar el flag (IsEnabled=$v) en $PM_PLANNING_DB (¿migraciones del backend aplicadas?)"
  fi
}

# Conteo de ordenes en la BD del backend. El backend almacena la planta BASE (BasePlantCode mapea RT->RES),
# no la etiqueta RT, asi que el conteo filtra Plant='RES'. -1 ante error de consulta.
e2e_orders_count(){
  local pw n; pw="$(wt_shared_sql_password)" || { printf '%s' "-1"; return; }
  n="$(wt_shared_scalar "$pw" "SET NOCOUNT ON; SELECT COUNT(*) FROM [$PM_PLANNING_DB].Demand.Orders WHERE Plant='RES';")"
  case "$n" in ''|*[!0-9]*) printf '%s' "-1" ;; *) printf '%s' "$n" ;; esac
}

# --- smoke funcional ---

# --- smoke de paridad (componentes WCF de la pantalla ValidacionParidad, 260701-2323) ---

# Dispara ejecutar_validacion_paridad en el legado DESDE macdata hacia el guest (sin tunel M1: el runtime
# vive en macdata). Datos = jobId a pollear. Imprime "<body>\n<http_code>".
e2e_parity_trigger(){
  local url="http://${PM_GUEST_WINHOST}:${SITEPORT}/$SVC_PARITY_RUN" body
  body="$(printf '{"planta":"%s","lineaFab":"%s","anof":%s,"semf":%s,"modo":"%s"}' \
    "$PLANTA" "$PARITY_LINEA" "${PARITY_ANOF:-0}" "${PARITY_SEMF:-0}" "$PARITY_MODO")"
  ssh -o ConnectTimeout=12 "$PM_REMOTE_SSH" "curl -s -m 60 -w '\n%{http_code}' -H 'Content-Type: application/json' -X POST --data '$(wt_esc "$body")' '$url'" 2>/dev/null
}

# Extrae un campo escalar de <wrapper>Result del JSON WCF (python3 si existe; fallback grep).
e2e_wcf_scalar(){  # uso: e2e_wcf_scalar <json> <wrapperResult> <campo>
  local json="$1" wrap="$2" field="$3"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c "import sys,json
try:
  d=json.load(sys.stdin); r=d.get('$wrap',d) if isinstance(d,dict) else {}
  v=r.get('$field','') if isinstance(r,dict) else ''
  sys.stdout.write('' if v is None else str(v))
except Exception:
  pass" 2>/dev/null
  else
    # Acepta valor comillado ("EXITO") o numerico sin comillas ("Estatus":1): el enum WCF (Estatus) serializa
    # como numero (DataContractJsonSerializer sin EnumMember), no como string.
    printf '%s' "$json" | sed -n "s/.*\"$field\":\"\\{0,1\\}\\([^\",}]*\\).*/\\1/p" | head -1
  fi
}

# Consulta obtener_estado_paridad y extrae Datos.<campo> del run (CurrentStatus / Verdict). Valida de paso la
# lectura por ConStrJobsReader (pm_reader -> Jobs.vwParityCheckRunStatus). Vacio si no hay respuesta.
e2e_parity_status_field(){  # uso: e2e_parity_status_field <jobId> <campo>
  local url="http://${PM_GUEST_WINHOST}:${SITEPORT}/$SVC_PARITY_STATUS" field="$2" body resp
  body="$(printf '{"jobId":"%s"}' "$1")"
  resp="$(ssh -o ConnectTimeout=12 "$PM_REMOTE_SSH" "curl -s -m 30 -H 'Content-Type: application/json' -X POST --data '$(wt_esc "$body")' '$url'" 2>/dev/null)"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$resp" | python3 -c "import sys,json
try:
  d=json.load(sys.stdin); r=d.get('obtener_estado_paridadResult',d) if isinstance(d,dict) else {}
  dd=(r.get('Datos') if isinstance(r,dict) else None) or {}
  sys.stdout.write(str(dd.get('$field') or ''))
except Exception:
  pass" 2>/dev/null
  else
    printf '%s' "$resp" | sed -n "s/.*\"$field\":\"\\([^\"]*\\)\".*/\\1/p" | head -1
  fi
}

# Pollea obtener_estado_paridad hasta un estado terminal (Completed/Failed/TimedOut) o timeout. Imprime el final.
e2e_parity_poll(){  # uso: e2e_parity_poll <jobId> <timeout_s>
  local jobid="$1" deadline="${2:-120}" waited=0 st=""
  while [ "$waited" -lt "$deadline" ]; do
    st="$(e2e_parity_status_field "$jobid" CurrentStatus)"
    case "$st" in Completed|Failed|TimedOut) printf '%s' "$st"; return 0 ;; esac
    sleep 3; waited=$((waited+3))
  done
  printf '%s' "${st:-<sin-respuesta>}"
}

# Lee obtener_reporte_paridad (una lectura del ReportJson de la vista estable). Imprime "<body>\n<http_code>".
e2e_parity_report(){  # uso: e2e_parity_report <jobId>
  local url="http://${PM_GUEST_WINHOST}:${SITEPORT}/$SVC_PARITY_REPORT" body
  body="$(printf '{"jobId":"%s"}' "$1")"
  ssh -o ConnectTimeout=12 "$PM_REMOTE_SSH" "curl -s -m 30 -w '\n%{http_code}' -H 'Content-Type: application/json' -X POST --data '$(wt_esc "$body")' '$url'" 2>/dev/null
}

e2e_estatus_ok(){ [ "$1" = "1" ] || [ "$1" = "EXITO" ]; }

cmd_smoke(){
  e2e_slot
  e2e_derive_front_ports   # el disparo va contra el site del slot (8100+N), no contra el singleton :8080
  local pass=0 fail=0 resp code estatus jobid pst verdict rbody rcode rest

  elog "smoke del slot $E2E_SLOT (site $WT_SITE_NAME :$SITEPORT, BD $PM_PLANNING_DB, Oracle $WT_ORACLE_CONTAINER)"
  elog "smoke paridad (ValidacionParidad por componentes): ejecutar -> poll estado -> reporte; slice $PLANTA/$PARITY_LINEA/$PARITY_ANOF/$PARITY_SEMF ($PARITY_MODO)"

  # 1) Disparo: ejecutar_validacion_paridad -> Datos = jobId (GUID); Estatus EXITO/INFORMACION segun el gateway.
  resp="$(e2e_parity_trigger)"; code="${resp##*$'\n'}"; resp="${resp%$'\n'*}"
  estatus="$(e2e_wcf_scalar "$resp" ejecutar_validacion_paridadResult Estatus)"
  jobid="$(e2e_wcf_scalar "$resp" ejecutar_validacion_paridadResult Datos)"
  if [ "$code" = "200" ] && printf '%s' "$jobid" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    elog "  [PASS] ejecutar_validacion_paridad aceptado (Estatus=$estatus jobId=$jobid)"
    pass=$((pass+1))

    # 2) Poll: obtener_estado_paridad hasta terminal (valida ConStrJobsReader -> Jobs.vwParityCheckRunStatus).
    pst="$(e2e_parity_poll "$jobid" 180)"
    verdict="$(e2e_parity_status_field "$jobid" Verdict)"
    elog "  estado final del run=$pst   veredicto=${verdict:-<n/d>}"
    if [ "$pst" = "Completed" ]; then
      elog "  [PASS] obtener_estado_paridad: Completed (lectura por ConStrJobsReader OK)"
      pass=$((pass+1))

      # 3) Reporte: obtener_reporte_paridad -> Estatus EXITO + reporte presente. En modo vivo contra un data
      #    tier local sin corrida de MPSRT el veredicto puede ser DIFF (correcto, es dato): NO se asevera MATCH.
      resp="$(e2e_parity_report "$jobid")"; rcode="${resp##*$'\n'}"; rbody="${resp%$'\n'*}"
      rest="$(e2e_wcf_scalar "$rbody" obtener_reporte_paridadResult Estatus)"
      if [ "$rcode" = "200" ] && e2e_estatus_ok "$rest"; then
        elog "  [PASS] obtener_reporte_paridad: reporte recuperado (Estatus=$rest, veredicto=${verdict:-<n/d>})"
        pass=$((pass+1))
      else
        ewarn "  [FAIL] obtener_reporte_paridad: sin reporte (HTTP=$rcode Estatus=$rest)."
        fail=$((fail+1))
      fi
    else
      ewarn "  [FAIL] obtener_estado_paridad: el run no llego a Completed (estado=$pst). Revisa la API, el worker de paridad y ConStrJobsReader."
      fail=$((fail+1))
    fi
  else
    ewarn "  [FAIL] ejecutar_validacion_paridad: sin jobId GUID (HTTP=$code Estatus=$estatus Datos='${jobid:-}'). Revisa backendBaseUrl, salud de la API y ParityBackendGateway."
    fail=$((fail+1))
  fi

  # Intake (carga-backend): el cutover 260701-2259 movio el gate del flag a OrdenesNuevasCargar_LN (camino
  # load-async), que es un postback de la pantalla + poll JS, SIN endpoint WCF REST directo; su smoke ON
  # (flag ON -> load-async set-based) y OFF (flag OFF -> Oracle intacto, sin delta en Demand.Orders) se
  # ejercita con navegador (validacion e2e de la solicitud), no headless. generar_programa quedo revertido a
  # Oracle puro y ya no ejercita el flag, por lo que su antiguo smoke ON/OFF se retiro de aqui.
  elog "intake carga-backend: flag-gated en OrdenesNuevasCargar_LN (load-async, UI-driven) -> cubierto por el smoke con navegador; no headless"

  echo ""
  elog "smoke E2E (paridad): $pass PASS / $fail FAIL"
  [ "$fail" -eq 0 ]
}

# --- verbos ---

cmd_up(){
  [ -n "$WT" ] || edie "falta WT=<folder> (worktree de pl-programa-maestro, ruta wt)"
  [ -n "$LEGACY_SRC" ] || edie "falta LEGACYSRC=<path> (fuente del legado en develop: ProgramaMaestroPT.sln + BL/CargaBackendGateway.cs)"
  [ -f "$LEGACY_SRC/ProgramaMaestroPT.sln" ] || edie "LEGACYSRC '$LEGACY_SRC' no es la solucion legado (falta ProgramaMaestroPT.sln)"
  # Guard: la fuente del legado debe traer el wiring de Fase 1 (1903). El main LOCAL del legado NO lo tiene.
  [ -f "$LEGACY_SRC/BL/CargaBackendGateway.cs" ] || edie "LEGACYSRC '$LEGACY_SRC' no trae el gateway de Fase 1 (BL/CargaBackendGateway.cs): apunta a un checkout en develop, no al main local"

  # La via E2E SIEMPRE enciende el Oracle del slot: el camino con flag OFF (PGE950RT) escribe en ControlPiso y
  # un Oracle compartido contaminaria a las demas sesiones.
  elog "[1/7] backend + Oracle por slot (wt-up WT=$WT ORACLE=1) ..."
  make -C "$BASE_DIR" wt-up WT="$WT" ORACLE=1 || edie "fallo wt-up"
  e2e_slot
  e2e_derive_front_ports
  E2E_ORACLE_PORT="$(e2e_oracle_port)"
  elog "      slot $E2E_SLOT -> BD $PM_PLANNING_DB, Oracle :$E2E_ORACLE_PORT, site $WT_SITE_NAME :$SITEPORT, tunel :$TUNNEL"

  elog "[2/7] puente SQL (el shared SQL solo escucha en loopback de macdata) ..."
  if [ -n "$SQL_PM_HOST_OVERRIDE" ]; then
    SQL_PM_HOST="$SQL_PM_HOST_OVERRIDE"; elog "      host SQL por override: $SQL_PM_HOST (sin puente)"
  else
    e2e_bridge_up
    SQL_PM_HOST="${PM_GUEST_GATEWAY},${BRIDGE_PORT}"
  fi

  local api_port
  api_port="$(e2e_api_port)"
  E2E_SQL_PW="$(wt_shared_sql_password)" || edie "no se obtuvo el SA del SQL compartido"
  BACKEND_URL="http://${PM_GUEST_GATEWAY}:${api_port}"

  elog "[3/7] legacy-launch del slot $E2E_SLOT + inyeccion (backendBaseUrl=$BACKEND_URL; ConStrPm=$SQL_PM_HOST/$PM_PLANNING_DB; oracle $PM_GUEST_GATEWAY:$E2E_ORACLE_PORT) ..."
  e2e_legacy_launch || edie "fallo legacy-launch"

  # El skip por health 200 conserva el wiring del deploy anterior. Si el site del slot quedo apuntando a otro
  # Oracle o a otro backend (slot reciclado, KEEP_FRONT), se re-despliega forzado en vez de correr el smoke
  # sobre datos ajenos.
  elog "[3b/7] verificando el wiring REALMENTE desplegado en el guest ..."
  local wiring
  wiring="$(e2e_deployed_wiring)"
  if ! e2e_wiring_matches "$wiring"; then
    ewarn "      wiring desplegado divergente: re-deploy forzado"
    e2e_legacy_launch 1 || edie "fallo el re-deploy forzado del legado"
    wiring="$(e2e_deployed_wiring)"
    e2e_wiring_matches "$wiring" || edie "el site del slot sigue con un wiring que no es el suyo (ver avisos de arriba)"
  fi
  elog "      wiring OK: oraclePort=$E2E_ORACLE_PORT backendBaseUrl=$BACKEND_URL catalogo=$PM_PLANNING_DB"

  elog "[4/7] validando guest -> SQL del flag y guest -> Oracle del slot (fail-fast) ..."
  e2e_check_guest_sql
  e2e_check_guest_tcp "$PM_GUEST_GATEWAY" "$E2E_ORACLE_PORT" "Oracle del slot"

  elog "[5/7] activando feature flag carga-backend/$PLANTA = ON + login lector de jobs (pm_reader) ..."
  e2e_ensure_flag_schema
  e2e_ensure_jobs_reader
  e2e_set_flag 1

  elog "[6/7] precondicion de red (e2e-net-check) ..."
  PM_API_PORT="$api_port" "$BASE_DIR/scripts/e2e-net-check.sh" || ewarn "net-check con FAIL (continuo; revisa arriba)"

  elog "[7/7] smoke E2E funcional (legacy-driven) ..."
  cmd_smoke; local smoke_rc=$?

  case "$FLAG_FINAL" in on|1|ON) e2e_set_flag 1 ;; off|0|OFF) e2e_set_flag 0 ;; esac
  e2e_summary "$api_port"
  return $smoke_rc
}

# Orden canonico: e2e-down ANTES de wt-down. El slot se resuelve al INICIO (antes de que wt-down lo libere)
# y de forma TOLERANTE: si ya no hay slot (orden invertido), se degrada con warn y se ejecuta la limpieza
# posible en vez de abortar. Rescate manual: make legacy-site-down SLOT=<N>.
cmd_down(){
  elog "bajando E2E ..."
  local have_slot=0
  if e2e_slot_try; then have_slot=1; fi

  if [ "$have_slot" = "1" ]; then
    e2e_derive_front_ports
    # 1) tunel + site del legado del slot (simetria con wt-down, que borra API y BD).
    make -C "$BASE_DIR" legacy-down SLOT="$E2E_SLOT" SITEPORT="$SITEPORT" TUNNEL="$TUNNEL" >/dev/null 2>&1 \
      && elog "tunel del slot cerrado (localhost:$TUNNEL)" || ewarn "no se cerro el tunel del slot"
    if [ "$KEEP_FRONT" = "1" ]; then
      elog "site $WT_SITE_NAME conservado (PM_E2E_KEEP_FRONT=1); re-usarlo exige FORCE=1 en el proximo e2e-up"
    else
      make -C "$BASE_DIR" legacy-site-down SLOT="$E2E_SLOT" || ewarn "no se desmonto el site del slot $E2E_SLOT"
    fi
  else
    # Sin slot (orden invertido: wt-down corrio antes) NO se derivan puertos: los defaults del singleton
    # (8080/18080) matarian el tunel y el site de la sesion que este usando la via legada. Se degrada a avisar.
    ewarn "no se resolvio el slot de '${WT:-<sin WT>}' (¿'wt-down' corrio antes que 'e2e-down'?)."
    ewarn "NO se toca ningun tunel ni site: los defaults del singleton (8080/18080) pertenecen a otra sesion."
    ewarn "Rescate: 'make legacy-site-down SLOT=<N>' y 'make legacy-down SLOT=<N>' con el slot que tenia este worktree."
    ewarn "Orden canonico: 'make e2e-down WT=<folder>' ANTES de 'make wt-down WT=<folder>'."
  fi

  # 2) API + Oracle + BD del slot; libera el slot.
  if [ -n "$WT" ]; then make -C "$BASE_DIR" wt-down WT="$WT" || ewarn "wt-down con aviso"
  else ewarn "sin WT=<folder>: no se baja la API ni el Oracle del slot (pasa WT para bajarlos)"; fi

  # 3) el puente queda arriba salvo peticion explicita (lo comparten los demas slots).
  e2e_bridge_down
  elog "E2E abajo (data tier, SQL compartido, bus y puente singletons intactos)"
}

e2e_summary(){  # uso: e2e_summary <api_port>
  local api_port="$1"
  printf '\n'
  printf '  +----------------------------------------------------------------+\n'
  printf '  |  E2E Programa Maestro -- arriba                                |\n'
  printf '  +----------------------------------------------------------------+\n'
  printf '   Slot:                %s   (make wt-info WT=%s para la derivacion completa)\n' "$E2E_SLOT" "$WT"
  printf '   Backend (slot %s):   http://%s:%s   (BD %s)\n' "$E2E_SLOT" "$PM_GUEST_GATEWAY" "$api_port" "$PM_PLANNING_DB"
  printf '   Oracle (slot %s):    %s   (%s:%s)\n' "$E2E_SLOT" "$WT_ORACLE_CONTAINER" "$PM_GUEST_GATEWAY" "$E2E_ORACLE_PORT"
  printf '   Site IIS (slot %s):  %s   (guest %s:%s)\n' "$E2E_SLOT" "$WT_SITE_NAME" "$PM_GUEST_WINHOST" "$SITEPORT"
  printf '   SQL del flag:        %s  (puente %s, compartido)\n' "$SQL_PM_HOST" "$BRIDGE_NAME"
  printf '   Legacy (login):      http://localhost:%s/%s/Login.aspx\n' "$TUNNEL" "$VDIR"
  printf '   Feature flag:        carga-backend/%s = %s\n' "$PLANTA" "$FLAG_FINAL"
  printf '   Smoke / cierre:      make e2e-smoke WT=%s   |   make e2e-down WT=%s\n' "$WT" "$WT"
  printf '\n'
}

case "$VERB" in
  up)            cmd_up ;;
  smoke)         cmd_smoke ;;
  down)          cmd_down ;;
  oracle-counts) cmd_oracle_counts ;;
  *) echo "uso: $0 {up|smoke|down|oracle-counts}  (WT=<folder> LEGACYSRC=<path>)"; exit 2 ;;
esac
