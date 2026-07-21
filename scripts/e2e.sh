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
#   make e2e-playwright WT=<folder> LEGACYSRC=<path>  # focal tnuc02, OFF/ON, seed y teardown por slot
#   make e2e-url   WT=<folder>                    # reimprime el recuadro de acceso del slot (re-levanta el tunel si murio)
#   make e2e-down  WT=<folder>                    # baja tunel + site + API + Oracle del slot + puente (singletons intactos)
#   make e2e-down  WT=<folder> ... PM_E2E_KEEP_FRONT=1   # conserva el site del legado (re-usar con FORCE=1)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/worktrees.sh"
set +e   # common.sh fija 'set -e'; el driver reporta y decide, no aborta a mitad.
E2E_CONTRACT_SOURCE_ONLY=0
if [ "${PM_E2E_CONTRACT_SOURCE_ONLY:-0}" = 1 ] && [ "${BASH_SOURCE[0]}" != "$0" ]; then E2E_CONTRACT_SOURCE_ONLY=1; fi
VERB="${1:-up}"
if [ "$E2E_CONTRACT_SOURCE_ONLY" != 1 ]; then
  [ "$VERB" != down ] || PM_ALLOW_MISSING_WT_LEASE=1
  load_env
  # El backend wt, el SQL compartido y el bus viven en macdata; fija el contexto docker remoto.
  wt_require_intel || { printf 'ERROR [e2e]: requiere PM_TARGET=intel y REMOTE=macdata\n' >&2; exit 2; }
fi

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

# Runner focal de Nucleos. Se valida el contrato exacto antes de consultar el registro de slots o tocar red.
PW_SCENARIO="${PM_E2E_PW_SCENARIO:-tnuc02}"
PW_GREP="${PM_E2E_PW_GREP:-@nucleos-full}"
PW_PROJECT="${PM_E2E_PW_PROJECT:-plant-res}"
PW_FLAG_KEY="${PM_E2E_PW_FLAG_KEY:-subordinate-nucleos-backend}"
PW_STATE_ENV="${PM_E2E_PW_STATE_ENV:-PM_E2E_NUCLEOS_FLAG_STATE}"
PW_FLAG_FINAL="${PM_E2E_PW_FLAG_FINAL:-off}"
PW_CREDENTIALS_FILE="${PM_E2E_PW_CREDENTIALS_FILE:-}"
PW_NODE_BIN="${PM_E2E_PW_NODE_BIN:-}"
PW_INSTALL="${PM_E2E_PW_INSTALL:-0}"
PW_TIMEOUT="${PM_E2E_PW_TIMEOUT:-900}"
PW_RETRIES="${PM_E2E_PW_RETRIES:-0}"
PW_WARM="${PM_E2E_PW_WARM:-0}"
PW_DOTNET_IMAGE="${PM_E2E_PW_DOTNET_IMAGE:-mcr.microsoft.com/dotnet/sdk:10.0}"

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
  local wt_input="$WT" wt_abs wt_short
  E2E_SLOT="$(wt_slot_lookup "$wt_input")"
  if [ -n "$E2E_SLOT" ]; then wt_derive "$E2E_SLOT"; return 0; fi
  wt_abs="$(pm_resolve_worktree_dir "$WT" 2>/dev/null)" || return 1
  wt_short="$(basename "$wt_abs")"
  E2E_SLOT="$(wt_slot_lookup "$wt_abs")"; [ -n "$E2E_SLOT" ] && WT="$wt_abs"
  if [ -z "$E2E_SLOT" ]; then E2E_SLOT="$(wt_slot_lookup "$wt_short")"; [ -n "$E2E_SLOT" ] && WT="$wt_short"; fi
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
e2e_api_port(){ wt_api_port "$E2E_SLOT" || true; }

# Puerto host REALMENTE publicado por el Oracle del slot. Fallback: la base de load_env + slot (NUNCA una
# constante literal: PM_WT_ORACLE_PORT_BASE es configurable).
e2e_oracle_port(){
  local ctx p; ctx="$(remote_docker_ctx)"
  p="$(on_intel "docker $ctx port 'pm-wt${E2E_SLOT}-oracle-1' 1521/tcp 2>/dev/null" 2>/dev/null | head -1 | sed 's/.*://' | tr -d '\r')"
  printf '%s' "${p:-$(( PM_WT_ORACLE_PORT_BASE + E2E_SLOT ))}"
}

# Wiring REALMENTE desplegado en el site del slot (clave=valor). Fuente de verdad: el valor solo vive en el guest.
e2e_deployed_wiring(){
  ssh -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$PM_REMOTE_SSH" \
    "WINHOST=$PM_GUEST_WINHOST SLOT=$E2E_SLOT bash ~/pm-host-windows/scripts/read-wiring.sh" 2>/dev/null
}

e2e_conn_field(){
  local cs="$1" wanted="$2"
  printf '%s\n' "$cs" | awk -v wanted="$wanted" 'BEGIN { RS=";" }
    { p=index($0,"="); if (!p) next; k=substr($0,1,p-1); v=substr($0,p+1);
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v);
      if (tolower(k)==tolower(wanted)) { print v; exit } }'
}

# ¿El site del slot esta cableado a SU backend, SU Oracle y SU catalogo? Los tres tienen que coincidir: un
# slot reciclado hereda el sitio anterior y el skip por health 200 conservaria su wiring en silencio.
e2e_wiring_matches(){  # uso: e2e_wiring_matches <salida-de-read-wiring>
  local w="$1" ok=0 dep_oracle dep_oracle_host dep_backend dep_pm dep_reader dep_pm_server dep_reader_server
  dep_oracle="$(printf '%s\n' "$w"  | sed -n 's/^oraclePort=//p' | head -1)"
  dep_oracle_host="$(printf '%s\n' "$w" | sed -n 's/^oracleHost=//p' | head -1)"
  dep_backend="$(printf '%s\n' "$w" | sed -n 's/^backendBaseUrl=//p' | head -1)"
  dep_pm="$(printf '%s\n' "$w"      | sed -n 's/^ConStrPm=//p' | head -1)"
  dep_reader="$(printf '%s\n' "$w"  | sed -n 's/^ConStrJobsReader=//p' | head -1)"
  dep_pm_server="$(e2e_conn_field "$dep_pm" Server)"
  dep_reader_server="$(e2e_conn_field "$dep_reader" Server)"
  [ "$dep_oracle" = "$E2E_ORACLE_PORT" ] || { ewarn "      oraclePort desplegado='$dep_oracle' esperado='$E2E_ORACLE_PORT'"; ok=1; }
  [ "$dep_oracle_host" = "$PM_GUEST_GATEWAY" ] || { ewarn "      oracleHost desplegado='$dep_oracle_host' esperado='$PM_GUEST_GATEWAY'"; ok=1; }
  [ "$dep_backend" = "$BACKEND_URL" ]    || { ewarn "      backendBaseUrl desplegado='$dep_backend' esperado='$BACKEND_URL'"; ok=1; }
  [ "$dep_pm_server" = "$SQL_PM_HOST" ] || { ewarn "      ConStrPm Server desplegado='$dep_pm_server' esperado='$SQL_PM_HOST'"; ok=1; }
  [ "$dep_reader_server" = "$SQL_PM_HOST" ] || { ewarn "      ConStrJobsReader Server desplegado='$dep_reader_server' esperado='$SQL_PM_HOST'"; ok=1; }
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

# El puente SQL vive factorizado en lib/worktrees.sh (wt_bridge_up/_down): lo comparten esta via e2e y el gate
# por slot (pm.sh test-clean). Estos shims preservan los nombres/call-sites de este driver; la config (nombre,
# puerto, imagen, PM_E2E_BRIDGE_DOWN) sigue viajando por las mismas variables PM_E2E_BRIDGE_* que lee la lib.
# wt_bridge_up usa wt_die (return); este driver aborta el flujo si el puente no queda arriba (paridad con el
# 'edie' original), porque sin puente el legado leeria el flag como OFF en silencio.
e2e_bridge_up(){ wt_bridge_up || edie "no se pudo asegurar el puente SQL ($BRIDGE_NAME)"; }
e2e_bridge_down(){ wt_bridge_down; }

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
    return 1
  fi
  return 0
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
    return 1
  fi
  return 0
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

# Lectura VIVA del flag: imprime el IsEnabled real (0/1) de carga-backend/$PLANTA en la BD del slot; vacio si no
# se pudo leer (sin SA o BD sin respuesta). Via wt_shared_scalar (escalar trimmeado). Nombre de tabla de 3 partes
# (molde de e2e_orders_count) en vez de USE [...]: el mensaje "Changed database context to ..." de USE contaminaria
# el escalar. El banner mapea el valor a on/off en vez de imprimir el estado DESEADO ($FLAG_FINAL).
e2e_read_flag(){
  local pw; pw="$(wt_shared_sql_password)" || return 1
  wt_shared_scalar "$pw" "SET NOCOUNT ON; SELECT IsEnabled FROM [$PM_PLANNING_DB].FeatureManagement.FeatureFlags WHERE [Key]='carga-backend' AND Plant='$PLANTA';"
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
  # I6-3/I7-A: PM_E2E_SKIP_WTUP=1 omite este wt-up interno cuando el backend+Oracle del slot ya los levanto una
  # fase previa (colapso goldenslice: la fase 2 ya corrio 'make wt-up ORACLE=1'). Re-invocarlo aqui recrea el API
  # una 2a vez de forma redundante. Es seguro omitirlo: e2e_slot lee el registro (wt_slot_lookup) y e2e_api_port
  # lee el puerto publicado del contenedor YA VIVO; ninguno exige que wt-up acabe de correr. Inerte por default
  # (PM_E2E_SKIP_WTUP ausente => 0 => rama else => wt-up identico al baseline).
  if [ "${PM_E2E_SKIP_WTUP:-0}" = 1 ]; then
    elog "[1/7] wt-up OMITIDO (PM_E2E_SKIP_WTUP=1): reusa el backend+Oracle ya vivos del slot"
  else
    elog "[1/7] backend + Oracle por slot (wt-up WT=$WT ORACLE=1) ..."
    make -C "$BASE_DIR" wt-up WT="$WT" ORACLE=1 || edie "fallo wt-up"
  fi
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

  # I7-B: PM_E2E_SKIP_SMOKE=1 omite el smoke de paridad, que puede colgarse hasta 180 s (poll con timeout en
  # cmd_smoke). En el colapso goldenslice el objetivo es dejar el ambiente ARRIBA con URLs; el smoke sigue
  # disponible aparte como 'make e2e-smoke'. Omitido => smoke_rc=0 (e2e-up no aborta por el). Inerte por default
  # (PM_E2E_SKIP_SMOKE ausente => 0 => corre el smoke como en el baseline).
  local smoke_rc
  if [ "${PM_E2E_SKIP_SMOKE:-0}" = 1 ]; then
    elog "[7/7] smoke E2E OMITIDO (PM_E2E_SKIP_SMOKE=1): el ambiente queda arriba; corre 'make e2e-smoke' aparte"
    smoke_rc=0
  else
    elog "[7/7] smoke E2E funcional (legacy-driven) ..."
    cmd_smoke; smoke_rc=$?
  fi

  case "$FLAG_FINAL" in on|1|ON) e2e_set_flag 1 ;; off|0|OFF) e2e_set_flag 0 ;; esac
  e2e_summary "$api_port"
  return $smoke_rc
}

# --- runner focal Playwright por slot (I13; assets en I12, corrida fisica en I14) ---

PW_SEED_PROJECT='seed-data/Pl.Pm.Legacy.E2E.SeedData/Pl.Pm.Legacy.E2E.SeedData.csproj'
PW_CLEANUP_ARMED=0
PW_CLEANUP_RUNNING=0
PW_SEED_ATTEMPTED=0
PW_FLAG_TOUCHED=0

e2e_playwright_validate_inputs(){
  local wt_abs specs spec_count expected_project credentials_abs suite_abs public_value
  [ -n "$WT" ] || edie "e2e-playwright exige WT=<worktree-pm>"
  wt_abs="$(pm_resolve_worktree_dir "$WT")" || edie "WT invalido: '$WT'"
  [ -n "$LEGACY_SRC" ] || edie "e2e-playwright exige LEGACYSRC=<ruta-absoluta-worktree-legacy>"
  case "$LEGACY_SRC" in /*) : ;; *) edie "LEGACYSRC debe ser ruta absoluta: '$LEGACY_SRC'" ;; esac
  [ -f "$LEGACY_SRC/ProgramaMaestroPT.sln" ] || edie "LEGACYSRC '$LEGACY_SRC' no contiene ProgramaMaestroPT.sln"
  [ -f "$LEGACY_SRC/tests/e2e/package-lock.json" ] || edie "LEGACYSRC no contiene tests/e2e/package-lock.json"
  [ -f "$LEGACY_SRC/tests/e2e/playwright.config.ts" ] || edie "LEGACYSRC no contiene tests/e2e/playwright.config.ts"
  [ -f "$LEGACY_SRC/tests/e2e/$PW_SEED_PROJECT" ] || edie "LEGACYSRC no contiene el seeder $PW_SEED_PROJECT"

  # I13 publica un runner focal: cualquier override divergente falla antes de lease/red y no ensancha I14.
  [ "$PW_SCENARIO" = tnuc02 ] || edie "PWSCENARIO debe ser tnuc02"
  [ "$PW_GREP" = @nucleos-full ] || edie "PWGREP debe ser @nucleos-full"
  [ "$PW_PROJECT" = plant-res ] || edie "PWPROJECT debe ser plant-res"
  [ "$PW_FLAG_KEY" = subordinate-nucleos-backend ] || edie "PWFLAGKEY debe ser subordinate-nucleos-backend"
  [ "$PW_STATE_ENV" = PM_E2E_NUCLEOS_FLAG_STATE ] || edie "PWSTATEENV debe ser PM_E2E_NUCLEOS_FLAG_STATE"
  case "$PLANTA" in RES) : ;; *) edie "PLANTA invalida: '$PLANTA' (I13 exige RES)" ;; esac
  expected_project="plant-$(printf '%s' "$PLANTA" | tr '[:upper:]' '[:lower:]')"
  [ "$PW_PROJECT" = "$expected_project" ] || edie "PWPROJECT '$PW_PROJECT' diverge de PLANTA=$PLANTA"
  case "$PW_FLAG_FINAL" in off|on) : ;; *) edie "PWFLAGFINAL debe ser off|on" ;; esac
  case "$PW_INSTALL" in 0|1) : ;; *) edie "PWINSTALL debe ser 0|1" ;; esac
  case "$PW_WARM" in 0|1) : ;; *) edie "WARM debe ser 0|1 para e2e-playwright" ;; esac
  case "$PW_TIMEOUT" in ''|*[!0-9]*) edie "PWTIMEOUT debe ser entero positivo" ;; esac
  [ "$PW_TIMEOUT" -gt 0 ] || edie "PWTIMEOUT debe ser entero positivo mayor que cero"
  case "$PW_RETRIES" in ''|*[!0-9]*) edie "PWRETRIES debe ser entero >=0" ;; esac
  for public_value in "$PW_NODE_BIN" "$PM_REMOTE_DOCKER_CONTEXT" "$PW_DOTNET_IMAGE"; do
    case "$public_value" in
      *"'"*|*$'\n'*|*$'\r'*) edie "PWNODEBIN/contexto/imagen no admiten comilla simple ni saltos de linea" ;;
    esac
  done

  [ -f "$LEGACY_SRC/tests/e2e/seed-data/data/tnuc02.json" ] || edie "no existe seed-data/data/tnuc02.json (I12 pendiente)"
  [ -f "$LEGACY_SRC/tests/e2e/seed-data/scenarios.manifest.json" ] || edie "falta scenarios.manifest.json"
  grep -Fq '"tnuc02"' "$LEGACY_SRC/tests/e2e/seed-data/scenarios.manifest.json" \
    || edie "tnuc02 no esta activo en scenarios.manifest.json"
  specs="$(find "$LEGACY_SRC/tests/e2e/features" -path '*/specs/tnuc02.spec.ts' -type f -print 2>/dev/null)"
  spec_count="$(printf '%s\n' "$specs" | grep -c .)"
  [ "$spec_count" -eq 1 ] || edie "se esperaba un unico tnuc02.spec.ts y se encontraron $spec_count"
  PW_SPEC_REL="${specs#$LEGACY_SRC/tests/e2e/}"

  if [ -n "$PW_CREDENTIALS_FILE" ]; then
    [ -f "$PW_CREDENTIALS_FILE" ] || edie "PWCREDENTIALS no existe: '$PW_CREDENTIALS_FILE'"
    credentials_abs="$(cd "$(dirname "$PW_CREDENTIALS_FILE")" && pwd -P)/$(basename "$PW_CREDENTIALS_FILE")"
    suite_abs="$(cd "$LEGACY_SRC/tests/e2e" && pwd -P)"
    case "$credentials_abs" in "$suite_abs"/*) edie "PWCREDENTIALS no puede vivir dentro del arbol stageado" ;; esac
  fi
}

e2e_playwright_unquote(){
  local value="$1"
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s' "$value"
}

e2e_playwright_credentials(){
  local user_set=0 pass_set=0 file line key value perms perm_value
  PW_TEST_USER=''; PW_TEST_PASSWORD=''
  if [ "${PM_E2E_TEST_USER+x}" = x ]; then PW_TEST_USER="$PM_E2E_TEST_USER"; user_set=1; fi
  if [ "${PM_E2E_TEST_PASSWORD+x}" = x ]; then PW_TEST_PASSWORD="$PM_E2E_TEST_PASSWORD"; pass_set=1; fi
  file="$PW_CREDENTIALS_FILE"
  [ -n "$file" ] || file="$WRAPPER_DIR/pl-pm-legacy/tests/e2e/.env"
  if { [ "$user_set" -eq 0 ] || [ "$pass_set" -eq 0 ]; } && [ -f "$file" ]; then
    perms="$(stat -f '%Lp' "$file" 2>/dev/null || true)"
    case "$perms" in
      ''|*[!0-7]*) ewarn "no se verificaron permisos de '$file'" ;;
      *)
        perm_value=$((8#$perms))
        [ $((perm_value & 022)) -eq 0 ] || edie "PWCREDENTIALS permite escritura de grupo/otros (modo $perms)"
        [ $((perm_value & 077)) -eq 0 ] || ewarn "PWCREDENTIALS es legible por grupo/otros (modo $perms; recomendado 600)"
        ;;
    esac
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in ''|'#'*) continue ;; esac
      key="${line%%=*}"; value="${line#*=}"; key="${key#export }"
      case "$key" in
        PM_E2E_TEST_USER) [ "$user_set" -eq 1 ] || { PW_TEST_USER="$(e2e_playwright_unquote "$value")"; user_set=1; } ;;
        PM_E2E_TEST_PASSWORD) [ "$pass_set" -eq 1 ] || { PW_TEST_PASSWORD="$(e2e_playwright_unquote "$value")"; pass_set=1; } ;;
      esac
    done < "$file"
  fi
  [ "$user_set" -eq 1 ] && [ -n "$PW_TEST_USER" ] || edie "falta PM_E2E_TEST_USER"
  [ "$pass_set" -eq 1 ] || edie "falta PM_E2E_TEST_PASSWORD (puede definirse vacio para el slot local)"
}

e2e_playwright_set_flag(){
  make -C "$BASE_DIR" wt-flag WT="$WT" KEY="$PW_FLAG_KEY" STATE="$1" PLANT="$PLANTA"
}

e2e_playwright_quote(){ printf "'%s'" "$(wt_esc "$1")"; }

e2e_playwright_remote(){
  local mode="$1" phase="$2" cmd arg runner; shift 2
  runner="$PW_REMOTE_ROOT/.runner/e2e-playwright-remote.sh"
  for arg in "$runner" "$mode" "$PW_REMOTE_ROOT" "$PW_REMOTE_RESULT" "$PW_NODE_BIN" "$phase" \
    "$PM_REMOTE_DOCKER_CONTEXT" "$PW_DOTNET_IMAGE" "$@"; do
    case "$arg" in
      *"'"*|*$'\n'*|*$'\r'*) ewarn "argumento remoto contiene comilla simple o salto de linea; se rechaza antes de SSH"; return 2 ;;
    esac
  done
  cmd="bash $(e2e_playwright_quote "$runner") $(e2e_playwright_quote "$mode") $(e2e_playwright_quote "$PW_REMOTE_ROOT") $(e2e_playwright_quote "$PW_REMOTE_RESULT") $(e2e_playwright_quote "$PW_NODE_BIN") $(e2e_playwright_quote "$phase") $(e2e_playwright_quote "$PM_REMOTE_DOCKER_CONTEXT") $(e2e_playwright_quote "$PW_DOTNET_IMAGE")"
  for arg in "$@"; do cmd="$cmd $(e2e_playwright_quote "$arg")"; done
  case "$mode" in
    preflight|prepare) ssh -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$PM_REMOTE_SSH" "$cmd" </dev/null ;;
    seed|teardown)
      printf '%s\0%s\0' "$PW_PLANNING_CS" "$PW_CTRLPISO_CS" | ssh -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$PM_REMOTE_SSH" "$cmd"
      ;;
    test)
      printf '%s\0%s\0' "$PW_TEST_USER" "$PW_TEST_PASSWORD" | ssh -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$PM_REMOTE_SSH" "$cmd"
      ;;
    *) ewarn "modo remoto desconocido: '$mode'"; return 2 ;;
  esac
}

e2e_playwright_stage(){
  elog "stage per-slot sin .env: $LEGACY_SRC/tests/e2e -> $PM_REMOTE_SSH:$PW_REMOTE_ROOT"
  on_intel "mkdir -p '$PW_REMOTE_ROOT/.runner' '$PW_REMOTE_RESULT'" || return 1
  rsync -az --delete --include '.env.example' --exclude '.env*' --exclude '.npmrc' --exclude 'credentials*' \
    --exclude '*.pem' --exclude '*.key' \
    --exclude 'node_modules/' --exclude 'bin/' --exclude 'obj/' --exclude '.git/' \
    --exclude 'test-results/' --exclude 'playwright-report/' --exclude '.runner/' --exclude '.results/' \
    "$LEGACY_SRC/tests/e2e/" "$PM_REMOTE_SSH:$PW_REMOTE_ROOT/" || return 1
  rsync -az "$BASE_DIR/scripts/e2e-playwright-remote.sh" "$PM_REMOTE_SSH:$PW_REMOTE_ROOT/.runner/" || return 1
  e2e_playwright_remote preflight preflight || return 1
  e2e_playwright_remote prepare prepare "$PW_TIMEOUT" "$PW_INSTALL" "$PW_SEED_PROJECT"
}

e2e_playwright_collect(){
  mkdir -p "$PW_LOCAL_RESULT_DIR"; chmod 700 "$PW_LOCAL_RESULT_DIR"
  rsync -az "$PM_REMOTE_SSH:$PW_REMOTE_RESULT/" "$PW_LOCAL_RESULT_DIR/"
}

e2e_playwright_cleanup(){
  [ "$PW_CLEANUP_ARMED" = 1 ] || return 0
  [ "$PW_CLEANUP_RUNNING" = 0 ] || return 1
  PW_CLEANUP_RUNNING=1
  local rc=0
  if [ "$PW_SEED_ATTEMPTED" = 1 ]; then
    e2e_playwright_remote teardown teardown "$PW_TIMEOUT" "$PW_SCENARIO" "$PW_SEED_PROJECT" \
      || { ewarn "fallo el teardown del seed"; rc=1; }
  fi
  if [ "$PW_FLAG_TOUCHED" = 1 ]; then
    e2e_playwright_set_flag "$PW_FLAG_FINAL" || { ewarn "fallo la restauracion del flag"; rc=1; }
  fi
  wt_registry_lock wt_slot_touch "$WT" || rc=1
  e2e_playwright_collect || { ewarn "fallo la descarga de evidencia"; rc=1; }
  PW_CLEANUP_ARMED=0; PW_CLEANUP_RUNNING=0
  return "$rc"
}

e2e_playwright_exit_cleanup(){
  [ "$PW_CLEANUP_ARMED" = 1 ] || return 0
  ewarn "salida inesperada: cleanup best-effort"
  e2e_playwright_cleanup || true
}

e2e_playwright_signal(){
  ewarn "senal recibida: teardown/restauracion best-effort"
  e2e_playwright_cleanup || true
  wt_lock_release_all
  exit 130
}

e2e_playwright_bind_slot(){
  local requested_site="$SITEPORT" requested_tunnel="$TUNNEL" expected_sql db_exists api_port
  e2e_slot
  [ -z "$requested_site" ] || [ "$requested_site" = "$WT_SITE_PORT" ] || { ewarn "SITEPORT no pertenece al slot"; return 1; }
  [ -z "$requested_tunnel" ] || [ "$requested_tunnel" = "$WT_TUNNEL_PORT" ] || { ewarn "TUNNEL no pertenece al slot"; return 1; }
  SITEPORT="$WT_SITE_PORT"; TUNNEL="$WT_TUNNEL_PORT"
  wt_registry_lock wt_slot_touch "$WT" || return 1
  E2E_ORACLE_PORT="$(e2e_oracle_port)"; api_port="$(e2e_api_port)"
  BACKEND_URL="http://${PM_GUEST_GATEWAY}:${api_port}"
  expected_sql="${PM_GUEST_GATEWAY},${BRIDGE_PORT}"
  [ -z "$SQL_PM_HOST_OVERRIDE" ] || [ "$SQL_PM_HOST_OVERRIDE" = "$expected_sql" ] || { ewarn "SQLPMHOST diverge del puente canonico"; return 1; }
  e2e_bridge_up; SQL_PM_HOST="$expected_sql"
  E2E_SQL_PW="$(wt_shared_sql_password)" || return 1
  wt_shared_sql_check || return 1
  db_exists="$(wt_shared_scalar "$E2E_SQL_PW" "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'$PM_PLANNING_DB') IS NULL THEN 0 ELSE 1 END;")"
  [ "$db_exists" = 1 ] || { ewarn "no existe la BD exacta $PM_PLANNING_DB"; return 1; }
  wt_oracle_running && wt_oracle_ready || return 1
  on_intel "curl -fsS -o /dev/null --max-time 8 'http://127.0.0.1:$api_port/health/live'" || return 1
  PW_PLANNING_CS="$(PM_TEST_SQL_HOST=127.0.0.1 PM_SQL_HOST_PORT="$PM_SHARED_SQL_PUBLISHED" PM_SQL_SA_PASSWORD="$E2E_SQL_PW" pm_planning_connstr)"
  PW_CTRLPISO_CS="$(pm_ctrlpiso_connstr 127.0.0.1 "$E2E_ORACLE_PORT")"
  PW_BASE_URL="http://${PM_GUEST_WINHOST}:${SITEPORT}/$VDIR/"
  PW_API_URL="http://127.0.0.1:${api_port}/"
  PW_REMOTE_ROOT="pm-e2e-suite/wt${E2E_SLOT}"
  PW_REMOTE_RESULT="$PW_REMOTE_ROOT/.results/$PW_RUN_ID"
}

e2e_playwright_prepare_front(){
  local wiring
  e2e_ensure_flag_schema || return 1
  e2e_ensure_jobs_reader || return 1
  if [ "$PW_WARM" = 1 ]; then
    ewarn "WARM=1: recompila/despliega LEGACYSRC al IIS local del slot bajo guest-lock; no es deploy Prolec dev"
    e2e_legacy_launch 1 || return 1
  fi
  wiring="$(e2e_deployed_wiring)"
  e2e_wiring_matches "$wiring" || { ewarn "wiring divergente"; return 1; }
  e2e_check_guest_sql
  e2e_check_guest_tcp "$PM_GUEST_GATEWAY" "$E2E_ORACLE_PORT" "Oracle del slot"
}

_cmd_playwright_locked(){
  local rc=0 state_rc=0 cleanup_rc=0 state
  e2e_playwright_bind_slot || return 1
  e2e_playwright_stage || return 1
  e2e_playwright_prepare_front || return 1
  PW_CLEANUP_ARMED=1
  trap 'e2e_playwright_exit_cleanup' EXIT
  trap 'e2e_playwright_signal' INT TERM

  # Orden contractual: OFF -> seed -> test OFF -> ON -> test ON -> teardown -> flag final.
  PW_FLAG_TOUCHED=1
  e2e_playwright_set_flag off || return 1
  PW_SEED_ATTEMPTED=1
  if ! e2e_playwright_remote seed seed "$PW_TIMEOUT" "$PW_SCENARIO" "$PW_SEED_PROJECT"; then
    ewarn "fallo el seed; no se ejecuta navegador y se entra a cleanup"
    rc=1
  else
    for state in off on; do
      if [ "$state" = on ] && ! e2e_playwright_set_flag on; then ewarn "no se fijo on"; rc=1; continue; fi
      state_rc=0
      e2e_playwright_remote test "$state" "$state" "$PW_STATE_ENV" "$PW_PROJECT" "$PW_GREP" "$PW_SPEC_REL" \
        "$PW_BASE_URL" "$PW_API_URL" "$PLANTA" "$PW_TIMEOUT" "$PW_RETRIES" || state_rc=$?
      if [ "$state_rc" -ne 0 ]; then ewarn "sub-run $state fallo (exit=$state_rc); se continua"; rc=1; fi
    done
  fi
  e2e_playwright_cleanup || cleanup_rc=$?
  [ "$cleanup_rc" -eq 0 ] || rc=1
  trap - EXIT
  trap 'wt_lock_release_all' INT TERM
  return "$rc"
}

cmd_playwright(){
  umask 077
  e2e_playwright_validate_inputs
  e2e_playwright_credentials
  e2e_slot
  PW_RUN_ID="playwright-$(date -u +%Y%m%dT%H%M%SZ)-wt${E2E_SLOT}-$$"
  PW_LOCAL_RESULT_DIR="$BASE_DIR/artifacts/playwright/$PW_RUN_ID"
  mkdir -p "$PW_LOCAL_RESULT_DIR"
  local logf="$PW_LOCAL_RESULT_DIR/orchestrator.log" rcf="$PW_LOCAL_RESULT_DIR/result.rc" rc=0
  printf 'running\n' > "$rcf"
  wt_lock "playwright-wt${E2E_SLOT}" _cmd_playwright_locked 2>&1 | tee "$logf"
  rc="${PIPESTATUS[0]}"
  printf '%s\n' "$rc" > "$rcf"
  printf 'scenario=%s\nspec=%s\nproject=%s\ngrep=%s\nflag=%s/%s\nexit=%s\n' \
    "$PW_SCENARIO" "$PW_SPEC_REL" "$PW_PROJECT" "$PW_GREP" "$PW_FLAG_KEY" "$PLANTA" "$rc" > "$PW_LOCAL_RESULT_DIR/summary.txt"
  elog "e2e-playwright EXIT=$rc evidencia=$PW_LOCAL_RESULT_DIR"
  return "$rc"
}

# Orden canonico: e2e-down ANTES de wt-down. El slot se resuelve al INICIO (antes de que wt-down lo libere)
# y de forma TOLERANTE: si ya no hay slot (orden invertido), se degrada con warn y se ejecuta la limpieza
# posible en vez de abortar. Rescate manual: make legacy-site-down SLOT=<N>.
cmd_down(){
  elog "bajando E2E ..."
  local have_slot=0 rc=0 step_rc=0
  if e2e_slot_try; then have_slot=1; fi

  if [ "$have_slot" = "1" ]; then
    e2e_derive_front_ports
    # 1) tunel + site del legado del slot (simetria con wt-down, que borra API y BD).
    make -C "$BASE_DIR" legacy-down SLOT="$E2E_SLOT" SITEPORT="$SITEPORT" TUNNEL="$TUNNEL" >/dev/null 2>&1
    step_rc=$?
    if [ "$step_rc" -eq 0 ]; then elog "tunel del slot cerrado (localhost:$TUNNEL)"; else ewarn "no se cerro el tunel del slot"; rc="$step_rc"; fi
    if [ "$KEEP_FRONT" = "1" ]; then
      elog "site $WT_SITE_NAME conservado (PM_E2E_KEEP_FRONT=1); re-usarlo exige FORCE=1 en el proximo e2e-up"
    else
      make -C "$BASE_DIR" legacy-site-down SLOT="$E2E_SLOT"
      step_rc=$?
      if [ "$step_rc" -ne 0 ]; then ewarn "no se desmonto el site del slot $E2E_SLOT"; [ "$rc" -ne 0 ] || rc="$step_rc"; fi
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
  if [ -n "$WT" ]; then
    PM_ALLOW_MISSING_WT_LEASE=1 make -C "$BASE_DIR" wt-down WT="$WT"
    step_rc=$?
    if [ "$step_rc" -ne 0 ]; then ewarn "wt-down con aviso"; [ "$rc" -ne 0 ] || rc="$step_rc"; fi
  else ewarn "sin WT=<folder>: no se baja la API ni el Oracle del slot (pasa WT para bajarlos)"; fi

  # 3) el puente queda arriba salvo peticion explicita (lo comparten los demas slots).
  e2e_bridge_down
  step_rc=$?
  if [ "$step_rc" -ne 0 ]; then ewarn "no se completo el cleanup solicitado del puente"; [ "$rc" -ne 0 ] || rc="$step_rc"; fi
  elog "E2E abajo (data tier, SQL compartido, bus y puente singletons intactos)"
  return "$rc"
}

# Reimprime el recuadro de acceso de un ambiente E2E YA arriba, sin re-orquestar nada (gotcha del tunel
# flaky, D17 de 260709-1305). Solo lee estado y re-levanta el tunel del slot si murio; NO toca sitios IIS,
# contenedores, BD, flags ni bus.
cmd_url(){
  [ -n "$WT" ] || edie "falta WT=<folder>; uso: make e2e-url WT=<wt-pm> (reimprime la URL de acceso de un ambiente E2E ya arriba)"
  e2e_slot_try || edie "el worktree '$WT' no tiene slot: el ambiente no esta arriba; levantalo con make e2e-up WT=<wt-pm> LEGACYSRC=<path>"
  e2e_derive_front_ports
  E2E_ORACLE_PORT="$(e2e_oracle_port)"
  # Mismo patron idempotente de tunnel_up (legacy.sh): pgrep del ssh -L del tunel del slot (18100+N -> guest).
  if pgrep -f "$TUNNEL:$PM_GUEST_WINHOST:$SITEPORT" >/dev/null 2>&1; then
    elog "tunel del slot vivo (localhost:$TUNNEL -> $PM_GUEST_WINHOST:$SITEPORT)"
  else
    elog "tunel del slot caido: re-levantando via make legacy-tunnel (localhost:$TUNNEL -> $PM_GUEST_WINHOST:$SITEPORT)"
    make -C "$BASE_DIR" legacy-tunnel SLOT="$E2E_SLOT" SITEPORT="$SITEPORT" TUNNEL="$TUNNEL" \
      || edie "no se pudo re-levantar el tunel del slot (localhost:$TUNNEL)"
  fi
  # e2e_summary espera SQL_PM_HOST, que solo cmd_up fija: se re-deriva igual que alla (override o puente).
  SQL_PM_HOST="${SQL_PM_HOST_OVERRIDE:-${PM_GUEST_GATEWAY},${BRIDGE_PORT}}"
  e2e_summary "$(e2e_api_port)"
}

# Health-check LIGERO de las tres patas del ambiente, best-effort (timeouts cortos, nunca aborta). La API y el
# puente se prueban por SSH a macdata contra 127.0.0.1 (molde e2e-net-check.sh:54): 'macdata' es un alias SSH, no
# resuelve como hostname en el M1, asi que un curl/nc M1-directo a "$PM_REMOTE_SSH:puerto" daria DOWN espurio. El
# site IIS del slot va por el tunel local (localhost:$TUNNEL -> guest:$SITEPORT), que si es M1-local. Fija
# HEALTH_API/HEALTH_SITE/HEALTH_BRIDGE en OK/DOWN para que el banner refleje el estado real, no solo el proceso del tunel.
e2e_health_check(){  # uso: e2e_health_check <api_port>
  local api_port="$1"
  if ssh -o ConnectTimeout=8 "$PM_REMOTE_SSH" "curl -fsS -o /dev/null --max-time 6 http://127.0.0.1:$api_port/health/live" >/dev/null 2>&1; then
    HEALTH_API=OK; else HEALTH_API=DOWN; fi
  if curl -fsS -o /dev/null --max-time 6 "http://localhost:$TUNNEL/$VDIR/Login.aspx" >/dev/null 2>&1; then
    HEALTH_SITE=OK; else HEALTH_SITE=DOWN; fi
  if ssh -o ConnectTimeout=8 "$PM_REMOTE_SSH" "nc -z -G 6 127.0.0.1 $BRIDGE_PORT" >/dev/null 2>&1; then
    HEALTH_BRIDGE=OK; else HEALTH_BRIDGE=DOWN; fi
}

e2e_summary(){  # uso: e2e_summary <api_port>
  local api_port="$1"
  # Health-check ligero de API/site/puente; la cabecera solo declara "arriba" si las tres patas responden.
  e2e_health_check "$api_port"
  local head_state='arriba'
  case "${HEALTH_API}/${HEALTH_SITE}/${HEALTH_BRIDGE}" in OK/OK/OK) : ;; *) head_state='degradado' ;; esac
  # Lectura VIVA del flag desde la BD del slot (best-effort): mapea 1->on, 0->off; marcador claro si no se leyo.
  local flag_live; flag_live="$(e2e_read_flag)"
  case "$flag_live" in
    1) flag_live=on ;;
    0) flag_live=off ;;
    *) flag_live="?(sin lectura: ${flag_live:-vacio})" ;;
  esac
  printf '\n'
  printf '  +----------------------------------------------------------------+\n'
  printf '  |%-66s|\n' "  E2E Programa Maestro -- $head_state"
  printf '  +----------------------------------------------------------------+\n'
  printf '   Slot:                %s   (make wt-info WT=%s para la derivacion completa)\n' "$E2E_SLOT" "$WT"
  printf '   Backend (slot %s):   http://%s:%s   (BD %s)\n' "$E2E_SLOT" "$PM_GUEST_GATEWAY" "$api_port" "$PM_PLANNING_DB"
  printf '   Oracle (slot %s):    %s   (%s:%s)\n' "$E2E_SLOT" "$WT_ORACLE_CONTAINER" "$PM_GUEST_GATEWAY" "$E2E_ORACLE_PORT"
  printf '   Site IIS (slot %s):  %s   (guest %s:%s)\n' "$E2E_SLOT" "$WT_SITE_NAME" "$PM_GUEST_WINHOST" "$SITEPORT"
  printf '   SQL del flag:        %s  (puente %s, compartido)\n' "$SQL_PM_HOST" "$BRIDGE_NAME"
  printf '   Legacy (login):      http://localhost:%s/%s/Login.aspx\n' "$TUNNEL" "$VDIR"
  printf '   Feature flag:        carga-backend/%s = %s  (leido de %s)\n' "$PLANTA" "$flag_live" "$PM_PLANNING_DB"
  printf '   Health:              API=%s  site=%s  puente=%s\n' "$HEALTH_API" "$HEALTH_SITE" "$HEALTH_BRIDGE"
  printf '   Smoke / cierre:      make e2e-smoke WT=%s   |   make e2e-down WT=%s\n' "$WT" "$WT"
  printf '\n'
}

if [ "$E2E_CONTRACT_SOURCE_ONLY" = 1 ]; then return 0; fi

case "$VERB" in
  up)            cmd_up ;;
  smoke)         cmd_smoke ;;
  playwright)    cmd_playwright ;;
  url)           cmd_url ;;
  down)          cmd_down ;;
  oracle-counts) cmd_oracle_counts ;;
  *) echo "uso: $0 {up|smoke|playwright|url|down|oracle-counts}  (WT=<folder> LEGACYSRC=<path>)"; exit 2 ;;
esac
