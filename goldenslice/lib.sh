#!/usr/bin/env bash
# Librería compartida de los orquestadores goldenslice (up.sh y relaunch.sh). Aloja los helpers reutilizables por
# ambos flujos para no duplicar cuerpos de función. Se sourcea DESPUES de lib/common.sh + lib/worktrees.sh; las
# funciones aqui invocan gs_log/gs_die y variables del script consumidor en tiempo de EJECUCION (no de definición),
# de modo que cada script aporta su propio prefijo de log ([goldenslice-up] / [goldenslice-relaunch]) y su contexto.

# gs_run_job: POST a un tool-job del pm-api y poll a Completed (async 202 + jobId; GET /api/v1/jobs/{id}).
# Depende de dos variables que el script consumidor resuelve ANTES de invocarlo: API_PORT (puerto publicado del
# contenedor API en macdata) y PM_REMOTE_SSH (alias SSH de la Intel). Retorna 0 solo si el job llega a Completed.
gs_run_job(){  # <path> <json-body-o-vacio> <label>
  local path="$1" body="$2" label="$3" resp jid st i
  if [ -n "$body" ]; then
    resp="$(ssh "$PM_REMOTE_SSH" "curl -fsS -X POST http://127.0.0.1:$API_PORT$path -H 'Content-Type: application/json' -d '$body'" 2>/dev/null)"
  else
    resp="$(ssh "$PM_REMOTE_SSH" "curl -fsS -X POST http://127.0.0.1:$API_PORT$path" 2>/dev/null)"
  fi
  jid="$(printf '%s' "$resp" | sed -nE 's/.*"jobId"[": ]*"?([0-9a-fA-F-]{16,})"?.*/\1/p')"
  [ -n "$jid" ] || { gs_log "AVISO: $label no devolvio jobId (resp: ${resp:-<vacio>})"; return 1; }
  for i in $(seq 1 90); do
    st="$(ssh "$PM_REMOTE_SSH" "curl -fsS http://127.0.0.1:$API_PORT/api/v1/jobs/$jid" 2>/dev/null | sed -nE 's/.*"currentStatus"[": ]*"([A-Za-z]+)".*/\1/p')"
    case "$st" in
      Completed) gs_log "$label -> Completed"; return 0 ;;
      Failed|TimedOut) gs_log "AVISO: $label -> $st (revisa el job $jid)"; return 1 ;;
    esac
    sleep 2
  done
  gs_log "AVISO: $label no llego a Completed (job $jid)"; return 1
}

# ---------------------------------------------------------------------------
# Primitivas compartidas del hilo 260720-0719 (I7 gate de loaders / I9 timeout portable). Como gs_run_job, las
# funciones dependen de variables que el script consumidor resuelve en tiempo de EJECUCION (API_PORT, PLANNING_DB,
# PM_REMOTE_SSH, SLOT). No se ejecuta nada al sourcear: solo definiciones.
# ---------------------------------------------------------------------------

# Las 6 tablas del schema Catalogs gobernadas por la estrategia de lectura del login (CatalogTableMap.All del
# pm-api): intake-load (WarmAllAsync) las repuebla desde el golden Oracle. Nombres verbatim del write model EF.
# Fuente: src/Modules/Catalogs/03.Infrastructure/Strategy/CatalogTableMap.cs.
GS_STRATEGY_TABLES="Catalogs.Filters Catalogs.Parameters Catalogs.PlantFamilies Catalogs.FiscalCalendar Catalogs.EquivalentUnits Catalogs.ProductionLineRules"

# Las 11 tablas de convergencia del schema Catalogs (CatalogsConvergenceDescriptors.All del pm-api): catalog-load
# (clean) repuebla las 11; intake-load solo cubre 3, por lo que las 8 restantes EXIGEN catalog-load. Fuente:
# src/Modules/Catalogs/03.Infrastructure/Convergence/CatalogsConvergenceDescriptors.cs.
GS_CONVERGENCE_TABLES="Catalogs.WorkCenters Catalogs.OperationCalendars Catalogs.Operations Catalogs.MachineCalendars Catalogs.ManufacturingLines Catalogs.ManufacturingRoutes Catalogs.ManufacturingRouteOperations Catalogs.RelCpisoJscRules Catalogs.Machines Catalogs.CriticalFamilies Catalogs.WeeklyProgrammableDays"

# gs_planning_count <pw> <planning_db> <tabla-cualificada>: conteo escalar de una tabla de la BD planning por el
# motor SQL compartido (mismo puente que wt-sql). La BD se fija por -d (no 'USE') para no ensuciar el escalar con
# el mensaje "Changed database context". La tabla la controla el llamador (literal cualificado); sin inyeccion.
gs_planning_count(){  # <pw> <planning_db> <tabla>
  wt_shared_query "$1" "SET NOCOUNT ON; SELECT COUNT(*) FROM $3" "-h -1 -W -d $2" 2>/dev/null | tr -d ' \r\n'
}

# gs_list_empty <pw> <planning_db> <tabla...>: imprime (una por linea) las tablas cuyo COUNT(*) es 0 o no se pudo
# leer (tabla ausente por migracion, o error transitorio). Un conteo no numerico se trata como 0.
gs_list_empty(){  # <pw> <planning_db> <tabla...>
  local pw="$1" db="$2" t n; shift 2
  for t in "$@"; do
    n="$(gs_planning_count "$pw" "$db" "$t" || true)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -le 0 ]; then printf '%s\n' "$t"; fi
  done
  return 0
}

# gs_run_bounded <segundos> <etiqueta> -- <cmd...>: corre <cmd> con un watchdog que lo mata si excede <segundos>
# (macOS/zsh NO tiene 'timeout': patron background + watchdog + kill). Devuelve el rc del comando, o 124 si el
# watchdog lo mato (convencion de timeout(1)). Un cuelgue produce fallo en <segundos>, nunca una fase de horas.
# Invocar SIEMPRE en un condicional (if gs_run_bounded ...) para que set -e no aborte por el rc.
gs_run_bounded(){  # <segundos> <etiqueta> -- <cmd...>
  local secs="$1"; shift 2                 # descarta segundos + etiqueta
  [ "${1:-}" = "--" ] && shift
  "$@" &
  local cmd_pid=$!
  # watchdog: espera <secs> y, si el comando sigue vivo, lo termina (TERM y luego KILL de gracia).
  ( sleep "$secs"; if kill -0 "$cmd_pid" 2>/dev/null; then kill -TERM "$cmd_pid" 2>/dev/null; sleep 2; kill -KILL "$cmd_pid" 2>/dev/null; fi ) &
  local wd_pid=$!
  local rc=0
  wait "$cmd_pid" 2>/dev/null || rc=$?
  kill "$wd_pid" 2>/dev/null || true       # el comando ya termino: retira el watchdog si sigue durmiendo
  wait "$wd_pid" 2>/dev/null || true
  # 143=128+SIGTERM, 137=128+SIGKILL: lo mato el watchdog -> normaliza a 124 (timeout)
  if [ "$rc" = 143 ] || [ "$rc" = 137 ]; then return 124; fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Banner final garantizado (ac7/req5) y guard de la frontera de resolucion de slot (ac8/req6.3). Como el resto de
# lib.sh, invocan gs_log/gs_die del script consumidor en tiempo de EJECUCION.
# ---------------------------------------------------------------------------

# gs_banner <slot> <pm_wt> <legacy_wt> [api_port]: imprime SIEMPRE (independiente de make e2e-url, que puede
# colgarse) un recuadro con slot, URL del legado (tunel 18100+slot), URL del backend (guest gateway + puerto
# publicado del API) y el comando EXACTO de reuso del slot. El puerto del API se resuelve por docker port si no se
# pasa; si no se puede resolver, se marca <n/d> (el banner nunca aborta). PM_GUEST_GATEWAY lo fija load_env.
gs_banner(){  # <slot> <pm_wt> <legacy_wt> [api_port]
  local slot="$1" pm_wt="$2" legacy_wt="$3" api_port="${4:-}" ctx gw tunnel
  ctx="$(remote_docker_ctx)"
  gw="${PM_GUEST_GATEWAY:-172.16.128.1}"
  tunnel=$(( 18100 + slot ))
  if [ -z "$api_port" ]; then
    api_port="$(on_intel "docker $ctx port 'pm-wt${slot}-api' 8080/tcp 2>/dev/null" 2>/dev/null | head -1 | sed 's/.*://' | tr -d '\r')"
  fi
  [ -n "$api_port" ] || api_port="<n/d>"
  printf '\n'
  printf '  +----------------------------------------------------------------+\n'
  printf '  |%-64s|\n' "  goldenslice ARRIBA -- slot ${slot}"
  printf '  +----------------------------------------------------------------+\n'
  printf '   Slot:            %s\n' "$slot"
  printf '   Legado (M1):     http://localhost:%s/ProgramaMaestroLN/\n' "$tunnel"
  printf '   Backend (slot):  http://%s:%s\n' "$gw" "$api_port"
  printf '   Reusar el slot:  make goldenslice-relaunch WT=%s LEGACYWT=%s\n' "$pm_wt" "$legacy_wt"
  printf '\n'
}

# gs_guard_slot_provisioned <slot> <folder>: RED DE SEGURIDAD de req6.3 (drift b3). Antes de deployar a un slot
# RESUELTO POR NOMBRE (fila pre-existente del registro), verifica contra la realidad (docker de macdata) que ese
# slot esta aprovisionado. Si el slot resuelto NO tiene contenedores vivos PERO hay un env HUERFANO vivo (slot con
# contenedores vivos SIN fila = posible env que perdio su fila) -> DISCREPANCIA registro<->realidad: falla ruidoso
# (D3), golden NO deploya al fantasma. La firma que dispara es el HUERFANO (no cualquier slot vivo): un slot vivo
# LEGITIMO de otro tenant (con su propia fila) NO bloquea (multi-golden concurrente). Sin huerfanos (arranque en
# frio, o env propio caido a relanzar sin drift) NO bloquea. Sonda no responde => no bloquea (best-effort).
gs_guard_slot_provisioned(){  # <slot> <folder>
  local slot="$1" folder="$2" orphans
  wt_probe_live_slots || { gs_log "[guard] no se pudo sondear el docker de macdata; se omite el guard de fantasma (best-effort)"; return 0; }
  wt_slot_in_set "$slot" "${WT_LIVE_SLOTS:-}" && return 0                 # slot resuelto aprovisionado: OK
  orphans="$(wt_live_orphan_slots)"                                       # slots vivos SIN fila (huerfanos)
  if [ -n "${orphans// /}" ]; then
    gs_die "DISCREPANCIA registro<->realidad (drift b3): el registro resuelve '$folder' -> slot $slot, pero ese slot NO tiene contenedores vivos mientras hay env(s) HUERFANO(S) vivo(s) sin fila en slot(s) [${orphans% }] (posible env que perdio su fila). golden NO deploya al slot fantasma. Reconcilia el registro ('make wt-gc FORCE=1' retira huerfanos y filas fantasma; 'make wt-reclaim WT=$folder' libera la fila fantasma) y reintenta."
  fi
  return 0   # sin huerfanos vivos: slot propio caido a relanzar / arranque en frio / tenants legitimos; no bloquea
}
