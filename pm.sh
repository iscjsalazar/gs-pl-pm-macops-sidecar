#!/usr/bin/env bash
# Orquestador del data tier PM (SQL Server + Oracle) + API real para macOS.
# Verbos: run [--watch] | migrate | seed | api | api-down | e2e-backend (DEPRECADO) | e2e-backend-down (DEPRECADO) | test | test-clean | unit | format | format-check | down | nuke | ps | logs | port
# Target: PM_TARGET=local (colima/desktop) | intel (rsync + docker compose en la mac Intel via SSH)
#
#   ./pm.sh run                 # levanta el data tier + migra EF (crea BD/DDL) + seedea data-only (local)
#   ./pm.sh migrate             # aplica solo las migraciones EF (crea BD y DDL) contra la BD de producto
#   ./pm.sh seed                # re-seed data-only (loaders idempotentes; requiere la BD ya migrada)
#   ./pm.sh api                 # levanta la API real en ESTA mac (M1); salta si /health/live ya responde
#   ./pm.sh api-down            # detiene la API levantada por 'api'
#   # [DEPRECADO] Modo E2E (Opción C): lo sustituye la via por slots (make wt-up WT=<worktree>; guia §5).
#   [DEPRECADO] PM_TARGET=intel PM_REMOTE_SSH=macdata ./pm.sh e2e-backend       # tombstone: corta con aviso (exit 2)
#   [DEPRECADO] PM_TARGET=intel PM_REMOTE_SSH=macdata ./pm.sh e2e-backend-down  # tombstone: corta con aviso (exit 2)
#   ./pm.sh test                # asegura la API arriba y corre dotnet test (toda la suite) contra ella
#   WT=<worktree> ./pm.sh test-clean   # gate limpio POR SLOT: wt-up (slot API+BD+seed+Oracle) + migrate por puente + suite
#   PM_API_FORCE=1 ./pm.sh test # relanza la API (api-down+api) antes de testear; no reusa la que este arriba
#   PM_TEST_PROJECT=tests/PL.PM.IntegrationTests/PL.PM.IntegrationTests.csproj ./pm.sh test   # un proyecto
#   PM_TEST_FILTER='FullyQualifiedName~RtSync' ./pm.sh test                                    # un filtro
#   ./pm.sh unit                # unit tests puros (*.UnitTests): sin API, sin Docker, sin data tier; PM_TEST_FILTER acota
#   ./pm.sh down / nuke         # baja el data tier (conserva / borra volumenes)
#   # La confirmacion NUKE=1 vive en la capa make (make pm-nuke NUKE=1); la invocacion directa './pm.sh nuke' la salta.
#   # Data tier en la mac Intel + API en esta mac (el alias 'macdata' debe resolver como host p/ BD/AMQP: ver README):
#   PM_TARGET=intel PM_REMOTE_SSH=macdata PM_TEST_SQL_HOST=macdata ./pm.sh run
#   PM_TEST_SQL_HOST=macdata ./pm.sh test
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

VERB="${1:-}"; shift || true
WATCH=0
for a in "$@"; do [ "$a" = "--watch" ] && WATCH=1; done

load_env

prepare() {            # comun a run/seed: las vars van por entorno (load_env); si intel, rsync
  [ "$PM_TARGET" = "intel" ] && sync_to_intel || true
}

cmd_run() {
  prepare
  [ "$PM_TARGET" = "local" ] && guard_concurrency
  echo "[pm] up data tier (perfil=$PM_PROFILE) ..."
  with_up_lock compose up -d sqlserver $( [ "$PM_PROFILE" = full ] && echo oracle sbsqledge servicebus )
  cmd_migrate_inner   # EF crea la BD y el DDL ANTES del seed data-only (EF = dueno unico del DDL)
  cmd_seed_inner
  show_ports
  if [ "$WATCH" = "1" ]; then echo "[pm] --watch: logs (Ctrl-C corta)"; compose logs -f; fi
}

cmd_migrate_inner() {  # aplica las migraciones EF de la solucion contra la BD de producto del data tier
  pm_ef_migrate "$(pm_planning_connstr)"
}

cmd_migrate() { prepare; cmd_migrate_inner; }

cmd_seed_inner() {     # re-corre el seeder data-only (loaders idempotentes; el DDL ya lo creo EF)
  echo "[pm] seed SQL data-only (sqlseeder one-shot; requiere migraciones EF ya aplicadas) ..."
  compose up sqlseeder --abort-on-container-exit --no-log-prefix
  if [ "$PM_PROFILE" = "full" ]; then
    echo "[pm] NOTA: re-seed de Oracle (sin nuke) es el spike de D3 -> pendiente en F3;"
    echo "[pm]       fallback acordado: 'nuke' + 'run'."
  fi
}

cmd_seed() { prepare; cmd_seed_inner; }

cmd_api() {            # levanta la API real en ESTA mac (M1) apuntando al SQL del data tier (macdata)
  command -v dotnet >/dev/null 2>&1 || { echo "[pm] falta 'dotnet' en PATH" >&2; return 2; }
  local base; base="$(pm_api_base_url)"
  if [ "${PM_API_FORCE:-0}" = "1" ]; then
    # frescura (F3): mata la API vieja para no testear contra un binario obsoleto
    cmd_api_down >/dev/null 2>&1 || true
  elif curl -fsS -o /dev/null "$base/health/live" 2>/dev/null; then
    echo "[pm] api ya arriba en $base (skip)"; return 0
  fi
  local proj="$PM_SOLUTION_DIR/src/PL.PM.Bootstrapper.Api"
  local cs; cs="$(pm_planning_connstr)"
  local pidf="${TMPDIR:-/tmp}/pm-api-${PM_PROJECT}.pid"
  local logf="${TMPDIR:-/tmp}/pm-api-${PM_PROJECT}.log"
  # Con perfil full el bus emulador esta arriba: la API recibe su connection string por entorno (R10).
  local sbcs=""; [ "$PM_PROFILE" = "full" ] && sbcs="$(pm_servicebus_connstr)"
  # Paridad: la suite de integracion usa fixtures CSV (Parity__LegacySource=csv). Para una corrida
  # viva contra Oracle se relanza con PM_PARITY_LEGACY_SOURCE=oracle (requiere el perfil full).
  local ctrlcs=""; [ "$PM_PROFILE" = "full" ] && ctrlcs="$(pm_ctrlpiso_connstr)"
  echo "[pm] api: levantando en $base (entorno IntegrationTest, sql $PM_TEST_SQL_HOST:$PM_SQL_HOST_PORT/$PM_PLANNING_DB, bus ${sbcs:+$PM_SERVICEBUS_HOST:$PM_SB_HOST_PORT}) ..."
  # La solucion solo LEE ASPNETCORE_URLS / ConnectionStrings__* / ServiceBus__ConnectionString / Parity__* por entorno (frontera intacta).
  ASPNETCORE_ENVIRONMENT=IntegrationTest ASPNETCORE_URLS="$base" ConnectionStrings__Planning="$cs" \
    ConnectionStrings__Ln="$(pm_ln_connstr)" ServiceBus__ConnectionString="$sbcs" \
    Parity__LegacySource="${PM_PARITY_LEGACY_SOURCE:-csv}" ConnectionStrings__CtrlPiso="$ctrlcs" \
    nohup dotnet run --project "$proj" -c Debug > "$logf" 2>&1 &
  echo $! > "$pidf"
  local i; for i in $(seq 1 90); do
    curl -fsS -o /dev/null "$base/health/live" 2>/dev/null && { echo "[pm] api up (~${i}s)"; return 0; }
    sleep 1
  done
  echo "[pm] api no respondio /health/live; revisa $logf" >&2; return 1
}

cmd_api_down() {       # detiene la API levantada por cmd_api (pidfile + fallback por puerto)
  local pidf="${TMPDIR:-/tmp}/pm-api-${PM_PROJECT}.pid"
  [ -f "$pidf" ] && { kill "$(cat "$pidf")" 2>/dev/null || true; rm -f "$pidf"; }
  local pids; pids="$(lsof -ti "tcp:$PM_API_PORT" 2>/dev/null || true)"
  [ -n "$pids" ] && echo "$pids" | xargs kill 2>/dev/null || true
  echo "[pm] api detenida ($PM_API_HOST:$PM_API_PORT)"
}

cmd_api_e2e() {        # Opción C (E2E): construye la imagen de la API y la corre en SU PROPIO contenedor en macdata,
                       # unido a la red del data tier; el guest la alcanza en GATEWAY:PORT
  [ "$PM_TARGET" = "intel" ] || { echo "[pm] e2e-backend requiere PM_TARGET=intel (REMOTE=macdata)" >&2; return 2; }
  [ -n "$PM_REMOTE_SSH" ] || { echo "[pm] falta PM_REMOTE_SSH (host de la Intel, p.ej. macdata)" >&2; return 2; }
  on_intel 'command -v docker >/dev/null 2>&1' || { echo "[pm] falta 'docker' en $PM_REMOTE_SSH" >&2; return 2; }
  local ctx; ctx="$(remote_docker_ctx)"
  local net="${PM_PROJECT}_default"          # red por defecto del data tier (docker compose -p $PM_PROJECT)
  local cname="${PM_PROJECT}-api"
  local img="pm-e2e-api:${PM_PROJECT}"
  local guest; guest="$(pm_api_guest_url)"
  local hl="http://127.0.0.1:$PM_API_PORT/health/live"   # puerto publicado en el host macdata
  if [ "${PM_API_FORCE:-0}" = "1" ]; then
    cmd_api_e2e_down >/dev/null 2>&1 || true
  elif on_intel "curl -fsS -o /dev/null '$hl'" 2>/dev/null; then
    echo "[pm] e2e-backend: API ya arriba en $PM_REMOTE_SSH:$PM_API_PORT (guest -> $guest) (skip)"; return 0
  fi
  # La red del data tier debe existir (la crea 'pm-run TARGET=intel'); el contenedor de la API se une a ella.
  on_intel "docker $ctx network inspect '$net' >/dev/null 2>&1" || { echo "[pm] e2e-backend: la red '$net' no existe; levanta el data tier (DATATIER=1, o 'make pm-run TARGET=intel REMOTE=$PM_REMOTE_SSH')" >&2; return 1; }
  sync_solution_to_intel
  # Connection strings vistas DESDE el contenedor: hosts = nombres de servicio del data tier, puertos INTERNOS.
  # Escapa comillas simples (' -> '\'') por si el password las contiene (asignación SIN comillas dobles: ver nota).
  PM_TEST_SQL_HOST=sqlserver; PM_SQL_HOST_PORT=1433
  PM_SERVICEBUS_HOST=servicebus; PM_SB_HOST_PORT=5672
  local cs ln sbcs=""
  cs="$(pm_planning_connstr)"; cs=${cs//\'/\'\\\'\'}
  ln="$(pm_ln_connstr)";       ln=${ln//\'/\'\\\'\'}
  if [ "$PM_PROFILE" = "full" ]; then sbcs="$(pm_servicebus_connstr)"; sbcs=${sbcs//\'/\'\\\'\'}; fi
  # Paridad en e2e: con perfil full la fuente viva apunta al 'oracle' del propio data tier (puerto
  # interno); sin oracle en la red se cae a snapshots CSV. PM_PARITY_LEGACY_SOURCE lo sobreescribe.
  local ctrlcs="" psrc
  if [ "$PM_PROFILE" = "full" ]; then
    psrc="${PM_PARITY_LEGACY_SOURCE:-oracle}"
    ctrlcs="$(pm_ctrlpiso_connstr oracle 1521)"; ctrlcs=${ctrlcs//\'/\'\\\'\'}
  else
    psrc="${PM_PARITY_LEGACY_SOURCE:-csv}"
  fi
  local dockerfile="$BASE_DIR/e2e/Dockerfile"
  echo "[pm] e2e-backend: build imagen $img (contexto $PM_REMOTE_SSH:$PM_REMOTE_SOLUTION_DIR; primera vez ~varios min) ..."
  on_intel "cd '$PM_REMOTE_SOLUTION_DIR' && docker $ctx build -t '$img' -f- ." < "$dockerfile" || { echo "[pm] e2e-backend: falló el build de la imagen" >&2; return 1; }
  # Retira las capas dangling que el rebuild del mismo tag deja huerfanas; evita que el disco del VM se sature.
  on_intel "docker $ctx image prune -f" || true
  echo "[pm] e2e-backend: run contenedor $cname (red $net; sql sqlserver:1433/$PM_PLANNING_DB${sbcs:+; bus servicebus:5672}; publica $PM_API_PORT->8080) ..."
  # La solución solo LEE ASPNETCORE_* / ConnectionStrings__* / ServiceBus__ConnectionString por entorno (frontera intacta).
  on_intel "docker $ctx rm -f '$cname' >/dev/null 2>&1; docker $ctx run -d --name '$cname' --network '$net' -p $PM_API_PORT:8080 -e ASPNETCORE_ENVIRONMENT=IntegrationTest -e ConnectionStrings__Planning='$cs' -e ConnectionStrings__Ln='$ln' -e ServiceBus__ConnectionString='$sbcs' -e Parity__LegacySource='$psrc' -e ConnectionStrings__CtrlPiso='$ctrlcs' $(pm_parity_env_flags) '$img'" || { echo "[pm] e2e-backend: falló el run del contenedor" >&2; return 1; }
  # Un solo ssh por iteracion: 0=API responde, 2=contenedor muerto (corte temprano), 1=aun arrancando.
  local i rc; for i in $(seq 1 150); do
    rc=0; on_intel "curl -fsS -o /dev/null '$hl' 2>/dev/null && exit 0; [ \"\$(docker $ctx inspect -f '{{.State.Running}}' '$cname' 2>/dev/null)\" = true ] && exit 1; exit 2" || rc=$?
    case "$rc" in
      0) echo "[pm] e2e-backend: API up en $PM_REMOTE_SSH (~${i}s)"
         echo "[pm]   guest  -> $guest/health/live"
         echo "[pm]   M1/LAN -> $(pm_api_lan_url)/health/live"; return 0 ;;
      2) echo "[pm] e2e-backend: el contenedor murió; logs: ssh $PM_REMOTE_SSH docker $ctx logs $cname" >&2; return 1 ;;
    esac
    sleep 1
  done
  echo "[pm] e2e-backend: la API no respondió /health/live; logs: ssh $PM_REMOTE_SSH docker $ctx logs $cname" >&2; return 1
}

cmd_api_e2e_down() {   # elimina el contenedor de la API E2E en macdata
  [ -n "$PM_REMOTE_SSH" ] || { echo "[pm] falta PM_REMOTE_SSH" >&2; return 2; }
  local ctx; ctx="$(remote_docker_ctx)"
  on_intel "docker $ctx rm -f '${PM_PROJECT}-api' >/dev/null 2>&1; true"
  echo "[pm] e2e-backend: contenedor ${PM_PROJECT}-api eliminado en $PM_REMOTE_SSH"
}

cmd_e2e_backend() {    # lanza el backend en modo E2E (Opción C): data tier (intel) + API en macdata, guest-alcanzable
  echo "[pm] e2e-backend: backend en modo E2E (Opción C) -> API en macdata; el guest la alcanza en $(pm_api_guest_url)"
  [ "${PM_E2E_DATATIER:-1}" = "1" ] && cmd_run
  cmd_api_e2e
}

cmd_test() {           # asegura la API real arriba (M1) y corre dotnet test contra ella + el SQL del data tier
  command -v dotnet >/dev/null 2>&1 || { echo "[pm] falta 'dotnet' en PATH" >&2; return 2; }
  [ "${PM_SKIP_API:-0}" = "1" ] || cmd_api || return 1
  local base; base="$(pm_api_base_url)"
  local cs; cs="$(pm_planning_connstr)"
  local target="${PM_TEST_PROJECT:-PL.PM.sln}"   # default: toda la suite
  echo "[pm] test: $target (filtro: ${PM_TEST_FILTER:-<todos>}) -> api $base"
  local args=(test "$PM_SOLUTION_DIR/$target")
  [ -n "${PM_TEST_FILTER:-}" ] && args+=(--filter "$PM_TEST_FILTER")
  local sbcs=""; [ "$PM_PROFILE" = "full" ] && sbcs="$(pm_servicebus_connstr)"
  # Con perfil full viaja tambien la connstring Oracle del data tier: habilita la prueba de
  # integracion de la fuente viva de paridad (sin ella esa prueba se salta).
  local ctrlcs=""; [ "$PM_PROFILE" = "full" ] && ctrlcs="$(pm_ctrlpiso_connstr)"
  # ServiceBus__SubscriptionPrefix aisla los topics/subscriptions del bus compartido por slot (wt<N>). En modo
  # slot (cmd_test_clean) lo fija wt_derive; en la via singleton (pm-test) va vacio = sin prefijo.
  PM_API_BASE_URL="$base" PM_TEST_SQL="$cs" ConnectionStrings__Planning="$cs" \
    ConnectionStrings__Ln="$(pm_ln_connstr)" ServiceBus__ConnectionString="$sbcs" \
    ServiceBus__SubscriptionPrefix="${WT_SB_PREFIX:-}" \
    ConnectionStrings__CtrlPiso="$ctrlcs" dotnet "${args[@]}" "$@"
}

cmd_test_clean() {     # gate "limpio" POR SLOT: aprovisiona el data tier del slot (API fresca + BD + seed +
                       # Oracle/bus), migra determinista por el puente y corre la suite contra la API del slot.
                       # El singleton pm-local queda DEPRECADO como ambiente de validacion (doc canonico §5) y el
                       # gate es slot-mandatorio: sin WT o sin slot asignado en el registro falla en seco (exit 2)
                       # pidiendo 'make wt-up WT=<worktree>'; el gate NO aprovisiona slots por si mismo.
  # Carga perezosa de la capa de worktrees SOLO para este verbo (aprovisionamiento del slot, puente SQL,
  # derivacion): asi el resto de verbos de pm.sh no heredan su trap INT/TERM ni su superficie.
  . "$(dirname "${BASH_SOURCE[0]}")/lib/worktrees.sh"
  # Guard slot-mandatorio: corta ANTES de cualquier aprovisionamiento, compose, SSH o build. La consulta del
  # registro es READ-ONLY (wt_slot_lookup: sin wt_registry_lock de escritura ni asignacion de slot nuevo).
  local gate_folder gate_slot
  if ! gate_folder="$(wt_resolve_folder 2>/dev/null)"; then
    echo "[pm] test-clean: falta WT: el gate corre SIEMPRE sobre el slot del worktree (process-e2e-local-slots.md). Usa: make pm-test-clean WT=<worktree> (aprovisiona antes con make wt-up WT=<worktree>)" >&2
    return 2
  fi
  gate_slot="$(wt_slot_lookup "$gate_folder")"
  if [ -z "$gate_slot" ]; then
    if [ ! -f "$WRAPPER_DIR/worktrees/$gate_folder/PL.PM.sln" ]; then
      echo "[pm] test-clean: el worktree '$gate_folder' no resuelve (no existe $WRAPPER_DIR/worktrees/$gate_folder con marcador PL.PM.sln); revisa WT=<worktree de pl-programa-maestro>" >&2
    else
      echo "[pm] test-clean: el worktree $gate_folder no tiene slot asignado: corre primero make wt-up WT=$gate_folder (el gate no aprovisiona slots por si mismo)" >&2
    fi
    return 2
  fi
  wt_require_intel || return 1
  # 1) Aprovisiona el slot: reusa el slot ya asignado (el guard de arriba garantiza que existe en el registro),
  #    recrea la API del slot (frescura = el analogo de APIFORCE) y siembra la BD. Deja en scope los globals del
  #    slot que fija wt_derive: PM_PLANNING_DB (pm_planning_wt<N>), PM_PORT_OFFSET, PM_API_PORT (5180+N*10),
  #    PM_ORACLE_HOST_PORT (15210+N), WT_SB_PREFIX.
  echo "[pm] test-clean: aprovisionando el data tier del slot (wt-up) ..."
  cmd_wt_up || return 1
  # 2) Host M1-resoluble hacia macdata: el mDNS del host Intel, NUNCA el alias 'macdata' (D36). Override por SQLHOST.
  local m1host="$PM_TEST_SQL_HOST"
  # Nota (D36): SQLHOST=macdata NO resuelve desde el M1 (es alias SSH, no un nombre DNS/mDNS); el nombre
  # M1-resoluble es macbook-pro-de-diana.local (mDNS del host Intel) o una entrada en /etc/hosts del M1.
  case "$m1host" in macdata) echo "[pm] nota: SQLHOST=macdata no resuelve desde el M1 (alias SSH); se usa macbook-pro-de-diana.local (mDNS) o una entrada en /etc/hosts (D36)." ;; esac
  case "$m1host" in ""|127.0.0.1|localhost|macdata) m1host="macbook-pro-de-diana.local" ;; esac
  # 3) Puente 60211 -> SQL compartido (idempotente, adopt-if-present, bajo wt_lock bridge; factorizado en lib/).
  local bport pw; bport="$(wt_bridge_port)"
  wt_bridge_up || return 1
  pw="$(wt_shared_sql_password)" || return 1
  # 4) Redirige los helpers de connstring/test hacia el slot: BD del slot por el puente, SA del SQL compartido,
  #    Oracle/bus/API del slot por el host M1-resoluble. PM_PLANNING_DB/PM_API_PORT/PM_ORACLE_HOST_PORT/WT_SB_PREFIX
  #    ya los fijo wt_derive dentro de cmd_wt_up.
  PM_TEST_SQL_HOST="$m1host"; PM_SQL_HOST_PORT="$bport"; PM_SQL_SA_PASSWORD="$pw"
  PM_SERVICEBUS_HOST="$m1host"; PM_SB_HOST_PORT="$PM_WT_BUS_HOST_PORT"; PM_API_HOST="$m1host"
  echo "[pm] test-clean: slot -> BD $PM_PLANNING_DB via puente $m1host:$bport | API $m1host:$PM_API_PORT | Oracle $m1host:$PM_ORACLE_HOST_PORT | bus $m1host:$PM_SB_HOST_PORT prefix ${WT_SB_PREFIX:-<none>}"
  # 5) Migraciones EF deterministas contra la BD del slot por el puente (pm_ef_migrate descubre los 7 contextos,
  #    incluye FeatureManagement -> absorbe el puente temporal e2e_ensure_flag_schema). Idempotente sobre lo que
  #    la API ya aplico al arrancar; garantiza el esquema completo antes de la suite.
  pm_ef_migrate "$(pm_planning_connstr)" || return 1
  # 6) Suite contra la API del slot (ya arriba: PM_SKIP_API=1 evita relanzar una API local). cmd_test arma la
  #    superficie de env del slot (PM_API_BASE_URL, ConnectionStrings__*, ServiceBus__* + SubscriptionPrefix).
  PM_SKIP_API=1 cmd_test "$@"
}

cmd_unit() {           # unit tests puros (*.UnitTests): 100% locales en esta mac, sin API, sin Docker y sin
                       # data tier (contrato: gs-pl-pm-guidelines/testing.md). Anti-molde vs cmd_test: NO asegura
                       # la API ni exporta variables de conexion (nada de PM_API_BASE_URL / ConnectionStrings__* /
                       # ServiceBus__* / PM_TEST_SQL*): la suite queda verde con el data tier apagado.
  command -v dotnet >/dev/null 2>&1 || { echo "[pm] falta 'dotnet' en PATH" >&2; return 2; }
  # Descubrimiento por convencion: tests/*.UnitTests/*.csproj bajo la raiz de la solucion (resolve_solution_dir,
  # via load_env: PM_SOLUTION_DIR explicito > WT=<worktree> > CWD en un worktree de codigo > checkout central).
  local projects=() p
  while IFS= read -r p; do projects+=("$p"); done \
    < <(find "$PM_SOLUTION_DIR/tests" -maxdepth 2 -name '*.UnitTests.csproj' 2>/dev/null | sort)
  if [ "${#projects[@]}" -eq 0 ]; then
    echo "[pm] unit: ningun *.UnitTests.csproj bajo $PM_SOLUTION_DIR/tests; la raiz resuelta no parece la solucion pl-programa-maestro (revisa WT=<worktree> / PM_SOLUTION_DIR)" >&2
    return 2
  fi
  local args=(); [ -n "${PM_TEST_FILTER:-}" ] && args+=(--filter "$PM_TEST_FILTER")
  echo "[pm] unit: ${#projects[@]} proyectos *.UnitTests bajo $PM_SOLUTION_DIR/tests (filtro: ${PM_TEST_FILTER:-<todos>})"
  # Corre TODOS los proyectos aunque alguno falle (reporte completo); exit !=0 si CUALQUIERA fallo.
  local run=0 green=0 red=0 failed=""
  for p in "${projects[@]}"; do
    run=$((run+1))
    echo "[pm] unit: dotnet test ${p#"$PM_SOLUTION_DIR/"} ..."
    if dotnet test "$p" -v minimal ${args[@]+"${args[@]}"}; then
      green=$((green+1))
    else
      red=$((red+1)); failed="$failed ${p#"$PM_SOLUTION_DIR/"}"
    fi
  done
  echo "[pm] unit: proyectos corridos=$run verdes=$green rojos=$red${failed:+ (fallaron:$failed)}"
  [ "$red" -eq 0 ] || return 1
}

cmd_down() { echo "[pm] down (conserva volumenes y VM) ..."; compose down; }
cmd_nuke() { echo "[pm] nuke (borra contenedores+volumenes; NO la VM colima) ..."; compose down --volumes --remove-orphans; }
cmd_ps()   { compose ps; }
cmd_logs() { compose logs -f; }
cmd_port() {
  echo "SQL  -> $(compose port sqlserver 1433 2>/dev/null || echo 'n/d')"
  [ "$PM_PROFILE" = full ] && echo "ORA  -> $(compose port oracle 1521 2>/dev/null || echo 'n/d')" || true
  [ "$PM_PROFILE" = full ] && echo "BUS  -> $(compose port servicebus 5672 2>/dev/null || echo 'n/d')" || true
}

# Passthrough fino al formateo de la solucion: la logica vive en pl-programa-maestro/scripts/format*.sh
# (changed-vs-develop, self-contained). Esta capa no la duplica; solo delega en PM_SOLUTION_DIR.
cmd_format() {
  command -v dotnet >/dev/null 2>&1 || { echo "[pm] falta 'dotnet' en PATH" >&2; return 2; }
  ( cd "$PM_SOLUTION_DIR" && ./scripts/format.sh "$@" )
}
cmd_format_check() {
  command -v dotnet >/dev/null 2>&1 || { echo "[pm] falta 'dotnet' en PATH" >&2; return 2; }
  ( cd "$PM_SOLUTION_DIR" && ./scripts/format-check.sh "$@" )
}

case "$VERB" in
  # Warning (no bloquea) SOLO en el camino directo de pm-run/pm-watch: la via wt fija PM_PROJECT/PM_PORT_OFFSET
  # via wt_derive y entra por otros verbos (test-clean) o por wt.sh, nunca por 'run'.
  run)      if [ "$PM_PROJECT" != "pm-local" ] || [ "${PM_PORT_OFFSET:-0}" != "0" ]; then
              echo "[pm] [DEPRECADO como ambiente de trabajo] PROJECT/OFFSET solo vale para el data tier singleton pm-local; para trabajar usa make wt-up WT=<worktree> (guia §5)" >&2
            fi
            cmd_run ;;
  migrate)  cmd_migrate ;;
  seed)     cmd_seed ;;
  api)      cmd_api ;;
  api-down) cmd_api_down ;;
  # Tombstones (deprecacion activa): cortan ANTES de cualquier accion; cmd_e2e_backend/cmd_api_e2e_down permanecen hasta el follow-up de retiro.
  e2e-backend)      echo "[pm] [DEPRECADO] e2e-backend esta deprecado (process-e2e-local-slots.md §5: no aisla nada; la via por slots la sustituye). Usa: make wt-up WT=<worktree>. Retiro del codigo: follow-up." >&2; exit 2 ;;
  e2e-backend-down) echo "[pm] [DEPRECADO] e2e-backend-down esta deprecado. El analogo por slot es: make wt-down WT=<worktree>." >&2; exit 2 ;;
  test)       cmd_test "$@" ;;
  test-clean) cmd_test_clean "$@" ;;
  unit)       cmd_unit ;;
  format)       cmd_format "$@" ;;
  format-check) cmd_format_check "$@" ;;
  down)     cmd_down ;;
  nuke)     cmd_nuke ;;
  ps)       cmd_ps ;;
  logs)     cmd_logs ;;
  port)     cmd_port ;;
  *) echo "uso: $0 {run [--watch]|migrate|seed|api|api-down|e2e-backend (DEPRECADO)|e2e-backend-down (DEPRECADO)|test|test-clean|unit|format|format-check|down|nuke|ps|logs|port}"; exit 2 ;;
esac
