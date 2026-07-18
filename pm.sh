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
  # Log completo por corrida a disco (artifacts/, gitignored): un '| tail' del terminal nunca pierde la
  # evidencia; la lista de pruebas fallidas se recupera con grep. El 'if' evita el abort de set -e y captura
  # el rc real de dotnet por pipefail (set -euo pipefail); tee solo duplica la salida.
  local logdir="$BASE_DIR/artifacts/test-logs"; mkdir -p "$logdir"
  local logf="$logdir/test-$(date -u +%Y%m%dT%H%M%SZ)-${PM_PROJECT}.log"
  echo "[pm] test: log completo -> $logf (fallos: grep -E 'Failed|Con error PL' \"$logf\")"
  local rc=0 rcf="${logf%.log}.rc"
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
       ConnectionStrings__CtrlPiso="$ctrlcs" dotnet "${args[@]}" "$@" 2>&1 | tee "$logf"; then
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
  local gate_folder gate_abs gate_short gate_slot
  if ! gate_folder="$(wt_resolve_folder 2>/dev/null)"; then
    echo "[pm] test-clean: falta WT: el gate corre SIEMPRE sobre el slot del worktree (process-e2e-local-slots.md). Usa: make pm-test-clean WT=<worktree> (aprovisiona antes con make wt-up WT=<worktree>)" >&2
    return 2
  fi
  if ! gate_abs="$(pm_resolve_worktree_dir "$gate_folder")"; then
    echo "[pm] test-clean: WT '$gate_folder' no es un worktree PM valido; se rechazo antes de consultar/provisionar slots" >&2
    return 2
  fi
  gate_short="$(basename "$gate_abs")"
  gate_slot="$(wt_slot_lookup "$gate_folder")"
  if [ -z "$gate_slot" ]; then gate_slot="$(wt_slot_lookup "$gate_abs")"; [ -n "$gate_slot" ] && gate_folder="$gate_abs"; fi
  if [ -z "$gate_slot" ]; then gate_slot="$(wt_slot_lookup "$gate_short")"; [ -n "$gate_slot" ] && gate_folder="$gate_short"; fi
  if [ -z "$gate_slot" ]; then
    echo "[pm] test-clean: el worktree valido '$gate_abs' no tiene slot asignado (se probaron las claves '$gate_folder', '$gate_abs' y '$gate_short'); corre primero make wt-up WT=$gate_short. No se uso el checkout central." >&2
    return 2
  fi
  WT="$gate_folder"
  wt_require_intel || return 1
  # 1) Aprovisiona el slot: reusa el slot ya asignado (el guard de arriba garantiza que existe en el registro),
  #    recrea la API del slot (frescura = el analogo de APIFORCE) y siembra la BD. Deja en scope los globals del
  #    slot que fija wt_derive: PM_PLANNING_DB (pm_planning_wt<N>), PM_PORT_OFFSET, PM_API_PORT (5180+N*10),
  #    PM_ORACLE_HOST_PORT (15210+N), WT_SB_PREFIX.
  # Modo warm (WARM=1): re-correr el gate tras un kill esporadico del background es caro si rehace rsync+build de
  # la API y el cold-init del Oracle (~91 s) sobre un slot que ya quedo sano. Con WARM=1, si el slot responde
  # /health/live y su Oracle corre, se REUSA el aprovisionamiento: wt_derive fija los globals del slot sin re-
  # provisionar. Si el slot NO esta sano, cae al aprovisionamiento normal (no hay atajo enganoso).
  if [ "${PM_WT_WARM:-0}" = "1" ]; then
    wt_derive "$gate_slot"
    if on_intel "curl -fsS -o /dev/null http://127.0.0.1:$PM_API_PORT/health/live" 2>/dev/null && wt_oracle_running; then
      WT_ORACLE_ACTIVE=1
      echo "[pm] test-clean: WARM=1 y slot $gate_slot sano (API :$PM_API_PORT + Oracle $WT_ORACLE_CONTAINER) -> se reusa el aprovisionamiento (sin wt-up; evita rsync/build/reseed/cold-init)"
    else
      echo "[pm] test-clean: WARM=1 pero el slot $gate_slot NO esta sano (API o Oracle abajo) -> aprovisionando normalmente (wt-up) ..."
      cmd_wt_up || return 1
    fi
  else
    echo "[pm] test-clean: aprovisionando el data tier del slot (wt-up) ..."
    cmd_wt_up || return 1
  fi
  # Falla-cerrado (regla dura del gate): el gate DEBE correr con el Oracle del slot activo y listo (perfil full).
  # Sin el, las pruebas dependientes de Oracle se saltan y el gate quedaria verde sin cobertura real. cmd_wt_up
  # ya verifico la readiness al aprovisionar/adoptar el Oracle (WT_ORACLE_ACTIVE=1 via wt_oracle_ready); si quedo
  # en 0 (p. ej. 'ORACLE=0' o una corrida cruda 'WT=... ./pm.sh test-clean') se aborta en vez de degradar a csv.
  if [ "${WT_ORACLE_ACTIVE:-0}" != "1" ]; then
    echo "[pm] test-clean: el slot NO tiene Oracle activo del slot -> degradaria a modo csv (pruebas Oracle omitidas, gate verde falso). El gate exige ORACLE=1/perfil full: usa 'make pm-test-clean WT=<worktree>'; una corrida cruda 'WT=... ./pm.sh test-clean' o 'ORACLE=0' no es un gate valido." >&2
    return 2
  fi
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
  # Descubrimiento por convencion: tests/*.UnitTests/*.csproj + tests/*.ArchitectureTests/*.csproj bajo la raiz de
  # la solucion (resolve_solution_dir, via load_env: PM_SOLUTION_DIR explicito > WT=<worktree> > CWD en un worktree
  # de codigo > checkout central). Los ArchitectureTests son puros (NetArchTest lee IL: sin Docker ni data tier),
  # asi que pertenecen al loop rapido local: el guard de escritura Oracle (ADR-0010) exige que su test corra aqui.
  local projects=() p
  while IFS= read -r p; do projects+=("$p"); done \
    < <({ find "$PM_SOLUTION_DIR/tests" -maxdepth 2 -name '*.UnitTests.csproj' 2>/dev/null; \
          find "$PM_SOLUTION_DIR/tests" -maxdepth 2 -name '*.ArchitectureTests.csproj' 2>/dev/null; } | sort)
  if [ "${#projects[@]}" -eq 0 ]; then
    echo "[pm] unit: ningun *.UnitTests.csproj ni *.ArchitectureTests.csproj bajo $PM_SOLUTION_DIR/tests; la raiz resuelta no parece la solucion pl-programa-maestro (revisa WT=<worktree> / PM_SOLUTION_DIR)" >&2
    return 2
  fi
  # Guard warn-only (I6): un FILTER sin operador vstest (~ = ! ( & |) casa 0 pruebas y sale EXIT=0 -> falso verde
  # de "0 tests corridos". No bloquea (podria haber un caso legitimo); solo avisa para no leerlo como evidencia.
  case "${PM_TEST_FILTER:-}" in
    ''|*'~'*|*'='*|*'!'*|*'('*|*'&'*|*'|'*) : ;;
    *) echo "[pm] AVISO: FILTER='$PM_TEST_FILTER' sin operador vstest: puede casar 0 pruebas y dar verde vacuo. Usa FullyQualifiedName~$PM_TEST_FILTER (o Name~...). La corrida de EVIDENCIA de cierre va SIN FILTER." >&2 ;;
  esac
  local args=(); [ -n "${PM_TEST_FILTER:-}" ] && args+=(--filter "$PM_TEST_FILTER")
  echo "[pm] unit: ${#projects[@]} proyectos *.UnitTests + *.ArchitectureTests bajo $PM_SOLUTION_DIR/tests (filtro: ${PM_TEST_FILTER:-<todos>})"
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
  wait-gate)  cmd_wait_gate "$@" ;;
  format)       cmd_format "$@" ;;
  format-check) cmd_format_check "$@" ;;
  down)     cmd_down ;;
  nuke)     cmd_nuke ;;
  ps)       cmd_ps ;;
  logs)     cmd_logs ;;
  port)     cmd_port ;;
  *) echo "uso: $0 {run [--watch]|migrate|seed|api|api-down|e2e-backend (DEPRECADO)|e2e-backend-down (DEPRECADO)|test|test-clean|unit|wait-gate|format|format-check|down|nuke|ps|logs|port}"; exit 2 ;;
esac
