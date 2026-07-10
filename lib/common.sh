#!/usr/bin/env bash
# Librería común de los orquestadores del data tier PM.
# Compatible con bash 3.2 (el /bin/bash de macOS): sin arrays asociativos.
# La logica vive aqui; el Makefile y pm.sh son capas finas.
set -euo pipefail

# --- rutas ---
# BASE_DIR = raiz del checkout del sidecar (el central o un git worktree de gs-pl-pm-macops-sidecar).
# pwd -P (ruta fisica): casa con el toplevel que devuelve git (que resuelve symlinks) en la autodeteccion por CWD.
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# WRAPPER_DIR = raiz del arbol que aloja los repos hermanos (pl-programa-maestro, pl-pm-legacy) y el checkout
# central del sidecar. NO se deriva de "BASE_DIR/.." (eso asume el sidecar un nivel bajo la raiz y se rompe
# desde un git worktree del sidecar): se localiza subiendo hasta el primer ancestro con gs-pl-pm-macops-sidecar/.
# Override duro: PM_WRAPPER_DIR.
find_wrapper_dir() {
  local d="$1"
  while [ "$d" != "/" ]; do
    [ -d "$d/gs-pl-pm-macops-sidecar" ] && { printf '%s' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}
WRAPPER_DIR="${PM_WRAPPER_DIR:-$(find_wrapper_dir "$BASE_DIR" || true)}"
[ -n "$WRAPPER_DIR" ] && [ -d "$WRAPPER_DIR" ] || {
  echo "[pm] ERROR: no se localizo la raiz del proyecto (un ancestro con gs-pl-pm-macops-sidecar/); fija PM_WRAPPER_DIR." >&2
  exit 1
}
# Checkout central del sidecar (ruta oficial/estable): aloja el estado compartido (.env, registro de slots),
# que un git worktree del sidecar reusa en vez de fragmentar.
SIDECAR_CENTRAL_DIR="$WRAPPER_DIR/gs-pl-pm-macops-sidecar"
COMPOSE_FILE="docker-compose.yml"

# Resuelve la solucion (pl-programa-maestro) a construir/probar y deriva containers/compose. Prioridad:
# PM_SOLUTION_DIR explicito > WT=<folder> (worktree de codigo, validado por PL.PM.sln) > CWD dentro de un
# worktree de codigo > central. Cubre: solicitud sidecar standalone -> central; vinculada a un worktree -> ese.
resolve_solution_dir() {
  if [ -z "${PM_SOLUTION_DIR:-}" ]; then
    local cand="" top
    if [ -n "${WT:-}" ] && [ -f "$WRAPPER_DIR/worktrees/$WT/PL.PM.sln" ]; then
      cand="$WRAPPER_DIR/worktrees/$WT"
    else
      top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
      case "$top" in
        "$WRAPPER_DIR/worktrees/"*) [ -f "$top/PL.PM.sln" ] && cand="$top" ;;
      esac
    fi
    if [ -n "$cand" ]; then PM_SOLUTION_DIR="$cand"; else PM_SOLUTION_DIR="$WRAPPER_DIR/pl-programa-maestro"; fi
  fi
  PM_CONTAINERS_DIR="${PM_CONTAINERS_DIR:-$PM_SOLUTION_DIR/containers}"
  COMPOSE_DIR="$PM_CONTAINERS_DIR/compose"
}

# --- carga de .env (orquestador) ---
# Orden: $PM_ENV_FILE > gs-pl-pm-macops-sidecar/.env > containers/.env.example (solo defaults).
load_env() {
  resolve_solution_dir
  local f
  # .env del orquestador (estado compartido): el del checkout central primero, para que un git worktree del
  # sidecar herede credenciales/config sin recrearlas. Orden: PM_ENV_FILE > central/.env > este checkout/.env.
  for f in "${PM_ENV_FILE:-}" "$SIDECAR_CENTRAL_DIR/.env" "$BASE_DIR/.env" "$PM_CONTAINERS_DIR/.env"; do
    if [ -n "$f" ] && [ -f "$f" ]; then
      # shellcheck disable=SC1090
      set -a; . "$f"; set +a
      echo "[pm] env cargado: $f" >&2
      break
    fi
  done
  # defaults
  PM_TARGET="${PM_TARGET:-local}"                 # local | intel
  PM_PROJECT="${PM_PROJECT:-pm-local}"            # UNICO por agente/solicitud
  PM_PROFILE="${PM_PROFILE:-sql}"                 # sql | full (full = +oracle)
  if [ "$PM_PROFILE" = "full" ]; then PROFILE_FLAG="--profile full"; else PROFILE_FLAG=""; fi
  PM_PORT_MODE="${PM_PORT_MODE:-offset}"          # offset | ephemeral
  PM_PORT_OFFSET="${PM_PORT_OFFSET:-0}"
  PM_MAX_CONCURRENT_STACKS="${PM_MAX_CONCURRENT_STACKS:-2}"
  PM_DOCKER_CONTEXT="${PM_DOCKER_CONTEXT:-colima}"
  PM_SQL_SA_PASSWORD="${PM_SQL_SA_PASSWORD:-Pm_Local_2026!}"
  PM_ORACLE_PASSWORD="${PM_ORACLE_PASSWORD:-Pm_Oracle_2026!}"
  PM_REMOTE_SSH="${PM_REMOTE_SSH:-}"
  PM_REMOTE_DIR="${PM_REMOTE_DIR:-pm-containers}"
  # contexto docker EN la Intel (p.ej. colima-pm-data); vacio = usa el contexto activo del remoto.
  PM_REMOTE_DOCKER_CONTEXT="${PM_REMOTE_DOCKER_CONTEXT:-}"
  # integration tests del backend: host/BD del SQL a apuntar (contenedores en macdata).
  PM_TEST_SQL_HOST="${PM_TEST_SQL_HOST:-127.0.0.1}"   # intel: IP/host LAN de macdata
  PM_PLANNING_DB="${PM_PLANNING_DB:-pm_planning}"      # BD de producto (la crean las migraciones EF)
  # Service Bus (emulador, contenedor amd64 junto al data tier): host por defecto el mismo del SQL.
  PM_SERVICEBUS_HOST="${PM_SERVICEBUS_HOST:-$PM_TEST_SQL_HOST}"
  PM_SB_SA_PASSWORD="${PM_SB_SA_PASSWORD:-Sb_Local_2026!}"
  # API real (verb 'api'/'test'): corre en ESTA mac (M1). Puerto con offset por agente.
  PM_API_HOST="${PM_API_HOST:-127.0.0.1}"
  # Override explicito del puerto host de la API: PM_API_PORT ya trae el valor efectivo tras sourcear .env
  # (env directo, o via make APIPORT -> PM_API_PORT, o pinneado en .env, honrado como cualquier otra clave).
  # Se captura para que compute_ports lo distinga del valor derivado por slot; vacio => compute_ports deriva
  # 5180 + PM_PORT_OFFSET (patron de los otros *_HOST_PORT). No se deriva aqui: en load_env el offset aun es 0;
  # wt_derive fija el offset real del slot y re-llama compute_ports.
  PM_API_PORT_OVERRIDE="${PM_API_PORT:-}"
  # --- API en macdata (verbo 'e2e-backend', Opcion C): la API corre en su PROPIO contenedor en la Intel,
  # unido a la red del data tier (resuelve sqlserver/oracle/servicebus por nombre) y publicando el puerto E2E ---
  # Dir donde se rsyncea la solucion en la Intel: sirve de CONTEXTO de build de la imagen de la API.
  PM_REMOTE_SOLUTION_DIR="${PM_REMOTE_SOLUTION_DIR:-pm-solution}"
  # Direccion de la Intel (macdata) vista DESDE el guest: pasarela NAT/bridge de VMware. El guest ya la usa
  # para Oracle (ver scripts/deploy-app.sh). Es la URL del backend que el guest alcanza.
  PM_GUEST_GATEWAY="${PM_GUEST_GATEWAY:-172.16.128.1}"
  # Acceso al guest Windows desde la Intel (reusa el patron del legado): IP NAT + llave SSH (residen en macdata).
  PM_GUEST_WINHOST="${PM_GUEST_WINHOST:-172.16.128.129}"
  PM_GUEST_KEY="${PM_GUEST_KEY:-~/pm-host-windows/artifacts/ssh/id_pmwin}"
  # 'e2e-backend' levanta el data tier (intel) antes de la API; 0 lo omite (asume data tier ya provisto).
  PM_E2E_DATATIER="${PM_E2E_DATATIER:-1}"

  # --- Paridad: directorios del snapshot CSV y del store SQLite del resultado ---
  # El backend por defecto usa el temp del proceso (Path.GetTempPath()); en las rutas contenerizadas (API
  # e2e y slots wt) esos temp no coinciden con el host, asi que se fijan explicitos y overridables para
  # estabilizarlos e inspeccionarlos. En modo vivo (oracle) el trigger genera el snapshotId; Default solo
  # aplica a escenarios CSV. La ruta de red viva Oracle en slots wt queda diferida (R2 de 260702-1732).
  PM_PARITY_SNAPSHOT_DIR="${PM_PARITY_SNAPSHOT_DIR:-/tmp/pl-pm-parity-snapshots}"
  PM_PARITY_STORE_DIR="${PM_PARITY_STORE_DIR:-/tmp/pl-pm-parity}"
  PM_PARITY_DEFAULT_SNAPSHOT_ID="${PM_PARITY_DEFAULT_SNAPSHOT_ID:-}"

  # --- Aprovisionamiento por worktree (verbos wt-*) ---
  # Un slot (0..N-1) es la unica perilla por worktree; de el se derivan proyecto/offset/BD/prefijo de bus,
  # y ademas site IIS, tunel y Oracle del legado (ver README, tabla canonica por slot).
  PM_WT_SLOTS="${PM_WT_SLOTS:-8}"                       # N de slots disponibles
  # Oracle ControlPiso por slot (fase 2, lazy): solo se aprovisiona con PM_WT_ORACLE=1 (la via e2e-up lo enciende).
  PM_WT_ORACLE="${PM_WT_ORACLE:-0}"                     # 1 = aprovisiona pm-wt<N>-oracle-1 y cablea la API a el
  # Base dedicada del puerto host del Oracle per-slot. NO se usa 1521+offset (ver compute_ports).
  PM_WT_ORACLE_PORT_BASE="${PM_WT_ORACLE_PORT_BASE:-15210}"
  # Readiness del Oracle del slot: el init completo midio ~91 s en maquina descargada; 300 s cubre contencion.
  PM_WT_ORACLE_READY_TIMEOUT="${PM_WT_ORACLE_READY_TIMEOUT:-300}"
  # Frontend legado por slot: site IIS 8100+N en el guest, tunel 18100+N en la M1. Bloques dedicados: 8080+N
  # chocaria con el singleton 'pm':8080 y 8080+N*10 con 'pmpub':8090.
  PM_WT_SITE_PORT_BASE="${PM_WT_SITE_PORT_BASE:-8100}"
  PM_WT_TUNNEL_PORT_BASE="${PM_WT_TUNNEL_PORT_BASE:-18100}"
  PM_WT_REGISTRY="${PM_WT_REGISTRY:-$SIDECAR_CENTRAL_DIR/.worktrees/slots.tsv}"   # registro compartido (checkout central); gitignored folder->slot
  # SQL compartido (reuso del de nvoslabs): la API y el seeder lo alcanzan uniendose a su red externa
  # (idiomatico, igual que los labs de nvoslabs) o, en su defecto, por el puerto publicado en loopback.
  PM_SHARED_SQL_NETWORK="${PM_SHARED_SQL_NETWORK:-nvoslabsc3-sharedsql-dt}"   # red externa del SQL compartido
  PM_SHARED_SQL_HOST="${PM_SHARED_SQL_HOST:-sqlserver}"        # alias del SQL dentro de esa red
  PM_SHARED_SQL_PORT="${PM_SHARED_SQL_PORT:-1433}"            # puerto interno del SQL compartido
  PM_SHARED_SQL_PUBLISHED="${PM_SHARED_SQL_PUBLISHED:-60201}"  # puerto publicado en loopback de macdata (fallback)
  PM_SHARED_SQL_CONTAINER="${PM_SHARED_SQL_CONTAINER:-nvoslabsc3-sharedsql-sqlserver}"  # contenedor (autodiscovery del SA)
  PM_SHARED_SQL_PASSWORD="${PM_SHARED_SQL_PASSWORD:-}"        # vacio -> autodiscovery (printenv en el contenedor)
  # Referencia LN PROPIA de PM en el SQL compartido (NO el erpln106 de nvoslabs, que es de otra solucion):
  # singleton sembrado una vez (guarded seed-once), compartido read-only por todos los worktrees.
  PM_WT_LN_DB="${PM_WT_LN_DB:-pm_erpln106}"
  # Bus PM-owned compartido entre worktrees (proyecto compose dedicado): el aislamiento lo da el prefijo
  # de instancia ServiceBus__SubscriptionPrefix=wt<N> (la API auto-provisiona topics+subscriptions prefijados).
  PM_WT_BUS_PROJECT="${PM_WT_BUS_PROJECT:-pm-shared}"
  # Puerto host del bus compartido: solo para debug desde la M1; la API lo alcanza por la red interna
  # (servicebus:5672). Default alto para no chocar con un bus pm-local en 5672.
  PM_WT_BUS_HOST_PORT="${PM_WT_BUS_HOST_PORT:-15672}"
  # Imagen del contenedor de herramientas SQL (sqlcmd tools18 + bcp): no existe imagen standalone de
  # mssql-tools18 en MCR, asi que se reusa la del motor (la trae en /opt/mssql-tools18/bin), pero como
  # contenedor de tools aparte (no como motor). Tambien sirve contra un motor remoto/gestionado.
  PM_SQLTOOLS_IMAGE="${PM_SQLTOOLS_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}"
  compute_ports
}

# Connection string al SQL del data tier para la BD de producto (pm_planning).
# La consume el verb 'test' por entorno; la solucion NO conoce al wrapper (solo lee la variable).
pm_planning_connstr() {
  printf 'Server=%s,%s;Database=%s;User Id=sa;Password=%s;TrustServerCertificate=True' \
    "$PM_TEST_SQL_HOST" "$PM_SQL_HOST_PORT" "$PM_PLANNING_DB" "$PM_SQL_SA_PASSWORD"
}

# Connection string al proxy LN (erpln106) del mismo SQL del data tier; la consume la ACL real.
pm_ln_connstr() {
  printf 'Server=%s,%s;Database=%s;User Id=sa;Password=%s;TrustServerCertificate=True' \
    "$PM_TEST_SQL_HOST" "$PM_SQL_HOST_PORT" "${PM_LN_DB:-erpln106}" "$PM_SQL_SA_PASSWORD"
}

# Connection string al Oracle del data tier (pge_ctrlpiso, perfil full); la consumen la fuente viva de
# paridad (ConnectionStrings__CtrlPiso) y su prueba de integracion. Mismo formato que usa el legado.
# Args opcionales: host y puerto (para contenedores en la red del data tier: 'oracle' 1521).
pm_ctrlpiso_connstr() {
  printf 'data source=(description=(address=(protocol=tcp)(host=%s)(port=%s))(connect_data=(sid=XE)));user id=pge_ctrlpiso;password=ctrlpiso;' \
    "${1:-$PM_TEST_SQL_HOST}" "${2:-$PM_ORACLE_HOST_PORT}"
}

# Flags '-e Parity__*' para 'docker run': directorios de snapshot/store (y DefaultSnapshotId si esta fijado).
# Los consumen las rutas contenerizadas (API e2e y slots wt) para fijar donde el backend usaria el temp del
# proceso. La solucion NO conoce al wrapper (solo lee Parity__* por entorno).
pm_parity_env_flags() {
  # Valores entre comillas simples (como los ConnectionStrings__* hermanos): el shell remoto de on_intel
  # hace el word-splitting que separa los multiples '-e', asi que un directorio con espacios se protege aqui.
  printf -- "-e Parity__SnapshotDirectory='%s' -e Parity__StoreDirectory='%s'" \
    "$PM_PARITY_SNAPSHOT_DIR" "$PM_PARITY_STORE_DIR"
  [ -n "${PM_PARITY_DEFAULT_SNAPSHOT_ID:-}" ] && printf -- " -e Parity__DefaultSnapshotId='%s'" "$PM_PARITY_DEFAULT_SNAPSHOT_ID"
  printf '\n'
}

# URL base de la API real (la M1). Único punto de verdad del puerto de API.
pm_api_base_url() { printf 'http://%s:%s' "$PM_API_HOST" "$PM_API_PORT"; }

# URL de la API E2E (Opción C) vista por el guest: el host del bridge NAT de macdata.
pm_api_guest_url() { printf 'http://%s:%s' "$PM_GUEST_GATEWAY" "$PM_API_PORT"; }
# URL de la API E2E vista por el M1 (LAN): requiere 'macdata' resoluble en /etc/hosts del M1 (ver README).
pm_api_lan_url() { printf 'http://%s:%s' "${PM_REMOTE_SSH:-macdata}" "$PM_API_PORT"; }

compute_ports() {
  if [ "$PM_PORT_MODE" = "ephemeral" ]; then
    PM_SQL_HOST_PORT=0
    PM_ORACLE_HOST_PORT=0
    PM_SB_HOST_PORT=0
  else
    PM_SQL_HOST_PORT=$(( 1433 + PM_PORT_OFFSET ))
    # ATENCION: esta formula sirve a los stacks compose manuales (pm-run PROJECT=... OFFSET=...), NO al Oracle
    # per-slot de wt-up. Con el offset de un slot chocaria con contenedores vivos: slot 0 -> 1521 es
    # pm-local-oracle-1 y slot 5 (offset 50) -> 1571 es pm-arts-rt-oracle-1. El Oracle del slot usa una base
    # dedicada, PM_WT_ORACLE_PORT_BASE (15210) + slot; ver wt_derive en lib/worktrees.sh.
    PM_ORACLE_HOST_PORT=$(( 1521 + PM_PORT_OFFSET ))
    PM_SB_HOST_PORT=$(( 5672 + PM_PORT_OFFSET ))
  fi
  # Puerto host de la API: override explicito del usuario (APIPORT/PM_API_PORT) o derivado del offset del slot
  # (5180 + offset), recalculado aqui —no una sola vez en load_env— para reflejar el offset real que fija
  # wt_derive por slot. Fuera de la rama ephemeral: la API siempre publica un puerto conocido (wt-up cura
  # /health/live por el).
  if [ -n "${PM_API_PORT_OVERRIDE:-}" ]; then
    PM_API_PORT="$PM_API_PORT_OVERRIDE"
  else
    PM_API_PORT=$(( 5180 + PM_PORT_OFFSET ))
  fi
  export PM_SQL_HOST_PORT PM_ORACLE_HOST_PORT PM_SB_HOST_PORT PM_SQL_SA_PASSWORD PM_ORACLE_PASSWORD PM_SB_SA_PASSWORD PM_SQLTOOLS_IMAGE
}

# Connection string al Service Bus emulador (UseDevelopmentEmulator); la consume api/test por entorno.
pm_servicebus_connstr() {
  printf 'Endpoint=sb://%s:%s;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;' \
    "$PM_SERVICEBUS_HOST" "$PM_SB_HOST_PORT"
}

# Espera a que el SQL del data tier acepte conexiones TCP (host/puerto de pm_planning_connstr) antes de
# aplicar las migraciones EF. Sin sqlcmd local: prueba el socket con /dev/tcp del bash.
pm_wait_sql() {
  local host="$PM_TEST_SQL_HOST" port="$PM_SQL_HOST_PORT" i
  echo "[pm] esperando a SQL en $host:$port ..." >&2
  for i in $(seq 1 60); do
    if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
      exec 3>&- 3<&- 2>/dev/null || true
      echo "[pm] SQL acepta conexiones (~$((i * 2))s)" >&2
      return 0
    fi
    sleep 2
  done
  echo "[pm] timeout esperando SQL en $host:$port" >&2
  return 1
}

# Aplica las migraciones EF de la solucion ANTES del seed data-only: crean la BD de producto y el DDL de
# todos los schemas (EF es el dueno unico del DDL). Build una vez y luego --no-build por contexto; la
# connstring se pasa por --connection (sobreescribe la del factory de diseno) -> apunta a la BD destino
# (local o por host remoto). Requiere dotnet + el tool dotnet-ef (manifest .config/dotnet-tools.json de la
# solucion). Mismo comando que usa la pista de despliegue contra Azure SQL.
pm_ef_migrate() {  # uso: pm_ef_migrate <connstr>
  local cs="$1"
  command -v dotnet >/dev/null 2>&1 || { echo "[pm] falta 'dotnet' en PATH (migraciones EF)" >&2; return 2; }
  local sln="$PM_SOLUTION_DIR" api="src/PL.PM.Bootstrapper.Api" spec ctx proj attempt
  pm_wait_sql || return 1
  echo "[pm] EF migrate: aplicando migraciones (crea BD y DDL) antes del seed data-only ..." >&2
  ( cd "$sln" && dotnet tool restore >/dev/null && dotnet build "$sln/PL.PM.sln" -c Debug --nologo -v q ) || {
    echo "[pm] EF migrate: fallo el restore/build de la solucion" >&2; return 1; }
  # El primer contexto crea la BD y prueba el login: reintenta para absorber la ventana entre "puerto
  # abierto" (pm_wait_sql) y "login listo" del motor recien arrancado.
  echo "[pm]   ef database update: PlanningDbContext (crea BD; espera login)" >&2
  for attempt in 1 2 3 4 5 6; do
    if ( cd "$sln" && dotnet ef database update --no-build \
          --project "$sln/src/Modules/Planning/03.Infrastructure" --startup-project "$sln/$api" \
          --context PlanningDbContext --connection "$cs" ); then
      break
    fi
    [ "$attempt" = 6 ] && { echo "[pm] EF migrate: el motor no acepto la conexion/login tras varios intentos" >&2; return 1; }
    echo "[pm]   SQL aun no acepta login (intento $attempt); reintenta en 5s ..." >&2
    sleep 5
  done
  # Resto de contextos: la BD ya existe y el login funciona; un fallo aqui es genuino (falla rapido).
  for spec in Demand Catalogs LoadSummary Jobs FeatureManagement; do
    ctx="${spec}DbContext"; proj="src/Modules/${spec}/03.Infrastructure"
    echo "[pm]   ef database update: $ctx" >&2
    ( cd "$sln" && dotnet ef database update --no-build \
        --project "$sln/$proj" --startup-project "$sln/$api" \
        --context "$ctx" --connection "$cs" ) || {
      echo "[pm] EF migrate: fallo 'dotnet ef database update' en $ctx" >&2; return 1; }
  done
}

# NOTA (frontera wrapper/solucion): el orquestador NO escribe dentro de la solucion.
# docker compose interpola ${VAR} desde el ENTORNO del proceso -> compute_ports ya exporta las vars
# (local), y la rama 'intel' de compose() las pasa inline por SSH. No se genera compose/.env.

# --- guard de concurrencia (limite real = CPU/RAM) ---
# Cuenta proyectos compose "pm-*" con contenedores corriendo (excluye el propio).
guard_concurrency() {
  local running
  # '|| true' evita que un grep sin coincidencias (exit 1) aborte por set -e/pipefail.
  running=$( { docker --context "$PM_DOCKER_CONTEXT" ps \
      --filter "label=com.docker.compose.project" \
      --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null \
      | sort -u | grep -E '^pm-' | grep -v -x "$PM_PROJECT"; true; } | wc -l | tr -d ' ')
  running=${running:-0}
  if [ "$running" -ge "$PM_MAX_CONCURRENT_STACKS" ]; then
    echo "[pm] ABORTO: ya hay $running stack(s) pm-* corriendo (max=$PM_MAX_CONCURRENT_STACKS)." >&2
    echo "[pm] sube PM_MAX_CONCURRENT_STACKS o baja otro stack; o usa la mac Intel para mas paralelismo." >&2
    return 1
  fi
}

# --- lock de arranque (serializa el 'up' para no saturar la VM) ---
LOCKDIR="${TMPDIR:-/tmp}/pm-stack-up.lock"
with_up_lock() {  # uso: with_up_lock <cmd...>
  local i=0
  until mkdir "$LOCKDIR" 2>/dev/null; do
    i=$((i+1)); [ "$i" -gt 90 ] && { echo "[pm] timeout esperando lock de arranque" >&2; return 1; }
    sleep 1
  done
  trap 'rmdir "$LOCKDIR" 2>/dev/null || true' RETURN
  "$@"
}

# --- ejecutor de docker compose: local (contexto) o intel (ssh) ---
compose() {  # uso: compose <subcomando de docker compose...>
  if [ "$PM_TARGET" = "intel" ]; then
    [ -n "$PM_REMOTE_SSH" ] || { echo "[pm] falta PM_REMOTE_SSH (host de la Intel)" >&2; return 2; }
    # SSH no interactivo trae PATH minimo (sin /usr/local/bin) -> forzar PATH para hallar docker.
    # --context apunta al colima dedicado (p.ej. colima-pm-data) y no al activo de otro proyecto.
    local ctx=""; [ -n "$PM_REMOTE_DOCKER_CONTEXT" ] && ctx="--context $PM_REMOTE_DOCKER_CONTEXT"
    # vars por entorno (no .env en la solucion); PATH minimo en SSH no interactivo -> forzar /usr/local/bin.
    # shellcheck disable=SC2029
    ssh "$PM_REMOTE_SSH" "export PATH=/usr/local/bin:\$PATH PM_SQL_SA_PASSWORD='$PM_SQL_SA_PASSWORD' PM_SQL_HOST_PORT='$PM_SQL_HOST_PORT' PM_ORACLE_HOST_PORT='$PM_ORACLE_HOST_PORT' PM_SB_SA_PASSWORD='$PM_SB_SA_PASSWORD' PM_SB_HOST_PORT='$PM_SB_HOST_PORT' PM_SQLTOOLS_IMAGE='$PM_SQLTOOLS_IMAGE'; cd '$PM_REMOTE_DIR/compose' && docker $ctx compose -p '$PM_PROJECT' -f '$COMPOSE_FILE' ${PROFILE_FLAG:-} $*"
  else
    ( cd "$COMPOSE_DIR" && docker --context "$PM_DOCKER_CONTEXT" compose -p "$PM_PROJECT" -f "$COMPOSE_FILE" ${PROFILE_FLAG:-} "$@" )
  fi
}

# --- rsync containers/ -> Intel (bind-mounts no cruzan a un daemon remoto: corremos compose ALLA) ---
sync_to_intel() {
  [ -n "$PM_REMOTE_SSH" ] || { echo "[pm] falta PM_REMOTE_SSH" >&2; return 2; }
  echo "[pm] rsync containers/ -> $PM_REMOTE_SSH:$PM_REMOTE_DIR/" >&2
  ssh "$PM_REMOTE_SSH" "mkdir -p '$PM_REMOTE_DIR'"
  # Los CSV (seed, gitignored) SI cruzan; rsync -z ya comprime en el cable. Solo excluir git/.env/._*.
  rsync -az --delete \
    --exclude '.git' --exclude '.env' --exclude '._*' \
    "$PM_CONTAINERS_DIR/" "$PM_REMOTE_SSH:$PM_REMOTE_DIR/"
}

# --- API en la Intel (Opción C E2E): ejecutar comandos, rsync de la solución y contexto docker ---
# Ejecuta un comando en la Intel (macdata) con PATH ampliado: el SSH no interactivo trae PATH mínimo
# (sin /usr/local/bin donde vive docker). Espejo del PATH forzado en compose(). Pasa stdin al comando remoto.
on_intel() {  # uso: on_intel "<comando>"   (acepta stdin: p.ej. docker build -f- < Dockerfile)
  [ -n "$PM_REMOTE_SSH" ] || { echo "[pm] falta PM_REMOTE_SSH (host de la Intel, p.ej. macdata)" >&2; return 2; }
  # shellcheck disable=SC2029
  ssh "$PM_REMOTE_SSH" "export PATH=/usr/local/share/dotnet:/usr/local/bin:\$HOME/.dotnet:\$PATH DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1; $1"
}

# Flag --context para docker EN la Intel (mismo criterio que compose()): vacío = contexto activo del remoto.
# if/fi (no '&& printf'): con la var vacía debe retornar 0, o 'ctx=$(...)' abortaría bajo set -e.
remote_docker_ctx() { if [ -n "$PM_REMOTE_DOCKER_CONTEXT" ]; then printf -- "--context %s" "$PM_REMOTE_DOCKER_CONTEXT"; fi; }

# rsync de la SOLUCIÓN (pl-programa-maestro) -> Intel, como CONTEXTO de build de la imagen de la API.
# Excluye git/.env/bin/obj y containers/ (el data tier lo rsyncea sync_to_intel; la imagen no lo necesita).
# No escribe artefactos del wrapper dentro de la solución: es una copia de solo lectura para construir.
sync_solution_to_intel() {
  [ -n "$PM_REMOTE_SSH" ] || { echo "[pm] falta PM_REMOTE_SSH" >&2; return 2; }
  echo "[pm] rsync solución -> $PM_REMOTE_SSH:$PM_REMOTE_SOLUTION_DIR/ (contexto de build; excluye bin/obj/.git/containers)" >&2
  ssh "$PM_REMOTE_SSH" "mkdir -p '$PM_REMOTE_SOLUTION_DIR'"
  rsync -az --delete \
    --exclude '.git' --exclude '.env' --exclude '._*' \
    --exclude 'bin/' --exclude 'obj/' --exclude 'containers/' \
    "$PM_SOLUTION_DIR/" "$PM_REMOTE_SSH:$PM_REMOTE_SOLUTION_DIR/"
}

# perfiles de compose -> flags
profile_args() {
  if [ "$PM_PROFILE" = "full" ]; then printf -- "--profile full"; fi
}

show_ports() {
  echo "[pm] puertos publicados (proyecto $PM_PROJECT, target $PM_TARGET):"
  compose ps --format 'table {{.Service}}\t{{.Ports}}' 2>/dev/null || compose ps
}
