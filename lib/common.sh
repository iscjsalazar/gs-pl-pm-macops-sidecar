#!/usr/bin/env bash
# Librería común de los orquestadores del data tier PM.
# Compatible con bash 3.2 (el /bin/bash de macOS): sin arrays asociativos.
# La logica vive aqui; el Makefile y pm.sh son capas finas.
set -euo pipefail

# --- rutas ---
# BASE_DIR = .../gs-pl-pm-macops-sidecar ; CONTAINERS_DIR = .../pl-programa-maestro/containers
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER_DIR="$(cd "$BASE_DIR/.." && pwd)"
PM_CONTAINERS_DIR="${PM_CONTAINERS_DIR:-$WRAPPER_DIR/pl-programa-maestro/containers}"
PM_SOLUTION_DIR="${PM_SOLUTION_DIR:-$(cd "$PM_CONTAINERS_DIR/.." && pwd)}"   # raiz de pl-programa-maestro
COMPOSE_DIR="$PM_CONTAINERS_DIR/compose"
COMPOSE_FILE="docker-compose.yml"

# --- carga de .env (orquestador) ---
# Orden: $PM_ENV_FILE > gs-pl-pm-macops-sidecar/.env > containers/.env.example (solo defaults).
load_env() {
  local f
  for f in "${PM_ENV_FILE:-}" "$BASE_DIR/.env" "$PM_CONTAINERS_DIR/.env"; do
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
  PM_API_PORT="${PM_API_PORT:-$(( 5180 + PM_PORT_OFFSET ))}"
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
    PM_ORACLE_HOST_PORT=$(( 1521 + PM_PORT_OFFSET ))
    PM_SB_HOST_PORT=$(( 5672 + PM_PORT_OFFSET ))
  fi
  export PM_SQL_HOST_PORT PM_ORACLE_HOST_PORT PM_SB_HOST_PORT PM_SQL_SA_PASSWORD PM_ORACLE_PASSWORD PM_SB_SA_PASSWORD
}

# Connection string al Service Bus emulador (UseDevelopmentEmulator); la consume api/test por entorno.
pm_servicebus_connstr() {
  printf 'Endpoint=sb://%s:%s;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;' \
    "$PM_SERVICEBUS_HOST" "$PM_SB_HOST_PORT"
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
    ssh "$PM_REMOTE_SSH" "export PATH=/usr/local/bin:\$PATH PM_SQL_SA_PASSWORD='$PM_SQL_SA_PASSWORD' PM_SQL_HOST_PORT='$PM_SQL_HOST_PORT' PM_ORACLE_HOST_PORT='$PM_ORACLE_HOST_PORT' PM_SB_SA_PASSWORD='$PM_SB_SA_PASSWORD' PM_SB_HOST_PORT='$PM_SB_HOST_PORT'; cd '$PM_REMOTE_DIR/compose' && docker $ctx compose -p '$PM_PROJECT' -f '$COMPOSE_FILE' ${PROFILE_FLAG:-} $*"
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
