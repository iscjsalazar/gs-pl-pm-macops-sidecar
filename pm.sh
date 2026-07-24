#!/usr/bin/env bash
# Orquestador del data tier PM (SQL Server + Oracle) + API real para macOS.
# Verbos: run [--watch] | migrate | seed | api | api-down | e2e-backend (DEPRECADO) | e2e-backend-down (DEPRECADO) | test | test-clean | unit | gate | gate-manifest-regen | format | format-check | down | nuke | ps | logs | port
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
#   WT=<worktree> ./pm.sh unit  # unit+architecture en macdata (14 proyectos, receta durable T-008); WT obligatorio
#   WT=<worktree> ./pm.sh gate  # cierre canonico: unit macdata -> fail-fast -> wt-up ORACLE=1 -> IntegrationTests
#   WT=<worktree> ./pm.sh gate-manifest-regen  # manifiesto DE RAMA con los conteos reales (artifacts/, nunca config/)
#   PM_UNIT_MANIFEST_REL=<ruta> WT=<worktree> ./pm.sh gate  # corre el gate contra un manifiesto de rama
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
  # Guard Oracle nivel 0 + allowlist para el destino XE del data tier (solo perfil full, que cablea CtrlPiso):
  # enciende el kill-switch y habilita el guard host/SID contra el host/sid que pm_ctrlpiso_connstr (sin args)
  # usa ($PM_TEST_SQL_HOST / XE). Sin full quedan OFF/vacias (no hay Oracle). Camino singleton DEPRECADO; la via
  # canonica es el slot (wt_up_api).
  local wg_dml="false" wg_host="" wg_db=""
  [ "$PM_PROFILE" = "full" ] && { wg_dml="true"; wg_host="$PM_TEST_SQL_HOST"; wg_db="XE"; }
  echo "[pm] api: levantando en $base (entorno IntegrationTest, sql $PM_TEST_SQL_HOST:$PM_SQL_HOST_PORT/$PM_PLANNING_DB, bus ${sbcs:+$PM_SERVICEBUS_HOST:$PM_SB_HOST_PORT}) ..."
  # La solucion solo LEE ASPNETCORE_URLS / ConnectionStrings__* / ServiceBus__ConnectionString / Parity__* / Oracle__WriteGuard__* por entorno (frontera intacta).
  ASPNETCORE_ENVIRONMENT=IntegrationTest ASPNETCORE_URLS="$base" ConnectionStrings__Planning="$cs" \
    ConnectionStrings__Ln="$(pm_ln_connstr)" ServiceBus__ConnectionString="$sbcs" \
    Parity__LegacySource="${PM_PARITY_LEGACY_SOURCE:-csv}" ConnectionStrings__CtrlPiso="$ctrlcs" \
    Oracle__WriteGuard__DmlEnabled="$wg_dml" Oracle__WriteGuard__AllowedHosts__0="$wg_host" Oracle__WriteGuard__AllowedDbNames__0="$wg_db" \
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

cmd_test() {           # asegura la API real arriba (M1) y corre dotnet test contra ella + el SQL del data tier
  command -v dotnet >/dev/null 2>&1 || { echo "[pm] falta 'dotnet' en PATH" >&2; return 2; }
  [ "${PM_SKIP_API:-0}" = "1" ] || cmd_api || return 1
  local base; base="$(pm_api_base_url)"
  local cs; cs="$(pm_planning_connstr)"
  local target="${PM_TEST_PROJECT:-PL.PM.sln}"   # default: toda la suite
  echo "[pm] test: $target (filtro: ${PM_TEST_FILTER:-<todos>}) -> api $base"
  local args=(test "$PM_SOLUTION_DIR/$target")
  # Guard warn-only (I6): un FILTER sin operador vstest (~ = ! ( & |) casa 0 pruebas y sale EXIT=0 -> falso verde
  # de "0 tests corridos". No bloquea (podria haber un caso legitimo); solo avisa para no leerlo como evidencia.
  case "${PM_TEST_FILTER:-}" in
    ''|*'~'*|*'='*|*'!'*|*'('*|*'&'*|*'|'*) : ;;
    *) echo "[pm] AVISO: FILTER='$PM_TEST_FILTER' sin operador vstest: puede casar 0 pruebas y dar verde vacuo. Usa FullyQualifiedName~$PM_TEST_FILTER (o Name~...). La corrida de EVIDENCIA de cierre va SIN FILTER." >&2 ;;
  esac
  [ -n "${PM_TEST_FILTER:-}" ] && args+=(--filter "$PM_TEST_FILTER")
  local sbcs=""; [ "$PM_PROFILE" = "full" ] && sbcs="$(pm_servicebus_connstr)"
  # Con perfil full viaja tambien la connstring Oracle del data tier: habilita la prueba de
  # integracion de la fuente viva de paridad (sin ella esa prueba se salta).
  local ctrlcs=""; [ "$PM_PROFILE" = "full" ] && ctrlcs="$(pm_ctrlpiso_connstr)"
  # Guard Oracle nivel 0 + allowlist para el destino XE (solo full): consistente con cmd_api. Las pruebas de
  # integracion componen su propio writer guardado (OracleSlotWriter, DmlEnabled=true en codigo); estas vars
  # cubren cualquier camino que lea la config del proceso. Sin full quedan OFF/vacias (no hay Oracle).
  local wg_dml="false" wg_host="" wg_db=""
  [ "$PM_PROFILE" = "full" ] && { wg_dml="true"; wg_host="$PM_TEST_SQL_HOST"; wg_db="XE"; }
  # ServiceBus__SubscriptionPrefix aisla los topics/subscriptions del bus compartido por slot (wt<N>). En modo
  # slot (cmd_test_clean) lo fija wt_derive; en la via singleton (pm-test) va vacio = sin prefijo.
  # Log completo por corrida a disco (artifacts/, gitignored). Si el gate suministra PM_TEST_LOG_SINK, se
  # escribe ahi (log unico del cierre) en vez de crear un test-*.log paralelo.
  local logdir="$BASE_DIR/artifacts/test-logs"; mkdir -p "$logdir"
  local logf rcf
  if [ -n "${PM_TEST_LOG_SINK:-}" ]; then
    logf="$PM_TEST_LOG_SINK"
    rcf="${PM_UNIT_EVIDENCE_DIR:-$logdir}/integration.rc"
  else
    logf="$logdir/test-$(date -u +%Y%m%dT%H%M%SZ)-${PM_PROJECT}.log"
    rcf="${logf%.log}.rc"
  fi
  echo "[pm] test: log completo -> $logf (fallos: grep -E 'Failed|Con error PL' \"$logf\")"
  local rc=0
  # Veredicto persistido de forma robusta: un sidecar .rc (maquina-legible) y una linea EXIT= al final del log. Un
  # trap de SIGTERM/INT deja rastro si el background muere a media corrida (el harness lo mata tras compilar/migrar
  # pero antes de terminar): asi el veredicto se lee del ARCHIVO, no del status del background. 'running' hasta fin.
  echo running > "$rcf"
  # shellcheck disable=SC2064
  trap 'echo "[pm] test: EXIT=143 (killed)" >> "'"$logf"'"; echo 143 > "'"$rcf"'"; type wt_lock_release_all >/dev/null 2>&1 && wt_lock_release_all; exit 143' TERM INT
  if PM_API_BASE_URL="$base" PM_TEST_SQL="$cs" ConnectionStrings__Planning="$cs" \
       ConnectionStrings__Ln="$(pm_ln_connstr)" ServiceBus__ConnectionString="$sbcs" \
       ServiceBus__SubscriptionPrefix="${WT_SB_PREFIX:-}" \
       Oracle__WriteGuard__DmlEnabled="$wg_dml" Oracle__WriteGuard__AllowedHosts__0="$wg_host" Oracle__WriteGuard__AllowedDbNames__0="$wg_db" \
       ConnectionStrings__CtrlPiso="$ctrlcs" dotnet "${args[@]}" "$@" 2>&1 | tee -a "$logf"; then
    rc=0
  else
    rc=$?
  fi
  # Restaura el trap (a wt_lock_release_all si worktrees.sh esta sourced, si no al default) y sella el veredicto.
  if type wt_lock_release_all >/dev/null 2>&1; then trap 'wt_lock_release_all' TERM INT; else trap - TERM INT; fi
  echo "$rc" > "$rcf"
  echo "[pm] test: EXIT=$rc | log -> $logf | rc -> $rcf" | tee -a "$logf"
  return "$rc"
}

cmd_test_clean() {     # Alias de compatibilidad hacia el cierre canonico `gate` (T-008).
                       # Ya no ejecuta PL.PM.sln ni repite unitarias: la cadena es unit-macdata ->
                       # fail-fast -> wt-up ORACLE=1 -> PL.PM.IntegrationTests una vez.
  cmd_gate "$@"
}

cmd_unit() {           # Unitarias + arquitectura en macdata (receta durable T-008).
                       # WT obligatorio. Sin FILTER/TESTPROJECT. Host fijo macdata. Cero fallback M1.
  # shellcheck disable=SC1090
  . "$(dirname "${BASH_SOURCE[0]}")/lib/unit-macdata.sh"
  local run_id="${UNIT_RUN_ID:-}"
  pm_unit_macdata_run unit "$run_id"
}

cmd_gate() {           # Cierre canonico: unit macdata PRIMERO; rojo unitario corta ANTES de wt-up;
                       # verde unitario -> slot_setup + IntegrationTests una vez (no PL.PM.sln).
  # shellcheck disable=SC1090
  . "$(dirname "${BASH_SOURCE[0]}")/lib/unit-macdata.sh"
  # worktrees se carga perezosa dentro del gate cuando hace falta wt-up
  pm_gate_macdata_run
}

cmd_gate_manifest_regen() {  # Manifiesto DE RAMA con los conteos reales de la rama (artifacts/,
                             # nunca config/). Corrida de observacion o derivacion de evidencia.
  # shellcheck disable=SC1090
  . "$(dirname "${BASH_SOURCE[0]}")/lib/unit-macdata.sh"
  pm_gate_manifest_regen_run
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

# Espera el veredicto del gate leyendo el ARCHIVO .rc canonico (running -> codigo), la UNICA lectura correcta:
# nunca por '| tail', 'ps', ${PIPESTATUS[0]} (vacio en zsh) ni el status del background, que mienten en los huecos
# entre suites o al capturar el rc de un pipe. Resuelve el .rc: LOG=<ruta.log> -> ${LOG%.log}.rc (misma transformacion
# que cmd_test); por default, el test-*.rc mas reciente en artifacts/test-logs. Imprime EXIT=<codigo> y retorna ese
# codigo (0 = gate verde). Corta con codigo 3 si tras PM_GATE_WAIT_MAX s el rc sigue 'running' (proceso SIGKILL sin trap).
cmd_wait_gate() {
  local logdir="$BASE_DIR/artifacts/test-logs" rcf v waited=0 max="${PM_GATE_WAIT_MAX:-5400}"
  if [ -n "${LOG:-}" ]; then
    rcf="${LOG%.log}.rc"
  else
    rcf="$(ls -t "$logdir"/test-*.rc 2>/dev/null | head -1)"
  fi
  [ -n "$rcf" ] && [ -e "$rcf" ] || { echo "[pm] wait-gate: no hay .rc en $logdir (corrio un gate?); o pasa LOG=<ruta.log>" >&2; return 2; }
  echo "[pm] wait-gate: esperando veredicto en $rcf ..." >&2
  until [ -s "$rcf" ] && v="$(cat "$rcf" 2>/dev/null)" && [ "$v" != running ]; do
    [ "$waited" -ge "$max" ] && { echo "[pm] wait-gate: timeout ${max}s (rc sigue 'running'; proceso SIGKILL sin trap?)" >&2; return 3; }
    sleep 2; waited=$((waited+2))
  done
  echo "[pm] wait-gate: EXIT=$v (rc -> $rcf)"
  [ "$v" = 0 ]
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
  # Tombstones (guard permanente): cortan ANTES de cualquier accion; las funciones de la via e2e-backend se retiraron en el follow-up 260711-1901.
  e2e-backend)      echo "[pm] [DEPRECADO] e2e-backend esta deprecado (process-e2e-local-slots.md §5: no aisla nada; la via por slots la sustituye). Usa: make wt-up WT=<worktree>." >&2; exit 2 ;;
  e2e-backend-down) echo "[pm] [DEPRECADO] e2e-backend-down esta deprecado. El analogo por slot es: make wt-down WT=<worktree>." >&2; exit 2 ;;
  test)       cmd_test "$@" ;;
  test-clean) cmd_test_clean "$@" ;;
  unit)       cmd_unit ;;
  gate)       cmd_gate ;;
  gate-manifest-regen) cmd_gate_manifest_regen ;;
  wait-gate)  cmd_wait_gate "$@" ;;
  format)       cmd_format "$@" ;;
  format-check) cmd_format_check "$@" ;;
  down)     cmd_down ;;
  nuke)     cmd_nuke ;;
  ps)       cmd_ps ;;
  logs)     cmd_logs ;;
  port)     cmd_port ;;
  *) echo "uso: $0 {run [--watch]|migrate|seed|api|api-down|e2e-backend (DEPRECADO)|e2e-backend-down (DEPRECADO)|test|test-clean|unit|gate|gate-manifest-regen|wait-gate|format|format-check|down|nuke|ps|logs|port}"; exit 2 ;;
esac
