#!/usr/bin/env bash
# goldenslice-up (D18): levanta un ambiente E2E completo sembrado con la golden slice (datos reales de PROD,
# ventana FY2026 sem 18-25) y accesible desde la M1. SIN parametros: usa checkouts canonicos (origin/develop
# desechables). CON WT=<pm-wt> LEGACYWT=<legacy-wt> (modo worktree, req2/req3): usa ESOS worktrees TAL CUAL, sin
# tocar su git, y cada nombre distinto cae en su propio slot aislado (varios golden en paralelo).
#
# Flujo:
#   1) worktrees canonicos pm + legacy en origin/develop (git stash + checkout: preserva cambios locales, D18).
#   2) make wt-up (slot + Oracle propio del slot). El slot se auto-asigna; se deriva por wt_slot_lookup.
#   3) make goldenslice-seed (Oracle multi-owner + recompila + LN aislada pm_gs_ln_wt<N> UTF-16). Idempotente.
#   4) make e2e-up con PM_WT_LN_DB=pm_gs_ln_wt<N>: recrea el pm-api apuntando a la LN GOLDEN (no el pm_erpln106
#      compartido), levanta el frontend IIS del slot con su wiring, activa el flag carga-backend/RES e imprime
#      las URLs (backend + legado) accesibles desde la M1. El guard wt_ensure_ln_singleton ve la golden completa
#      (8/8 tablas de WT_LN_TABLES) y NO siembra handcrafted; el contenedor Oracle ya corre y se reusa (golden
#      intacto); wt_up_api hace 'docker rm -f' siempre, asi que el API se recrea con la connstring golden.
#
# Perillas: WT=<pm-wt> LEGACYWT=<legacy-wt> (modo worktree; ambas obligatorias juntas). Overrides de bajo nivel
# (con default, semantica canonica git): GS_PM_WT, GS_LEGACY_WT (nombres de worktree), GS_BASE (rama base develop).
set -eo pipefail
: "${PM_TARGET:=intel}" ; : "${PM_REMOTE_SSH:=macdata}" ; : "${PM_REMOTE_DOCKER_CONTEXT:=}"
export PM_TARGET PM_REMOTE_SSH PM_REMOTE_DOCKER_CONTEXT
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SIDECAR_DIR="${PM_SIDECAR_DIR:-$(cd "$SELF_DIR/.." && pwd)}"
WRAPPER_DIR="$(cd "$SELF_DIR/../../.." && pwd)"
# shellcheck source=/dev/null
. "$SIDECAR_DIR/lib/common.sh"
# shellcheck source=/dev/null
. "$SIDECAR_DIR/lib/worktrees.sh"
# shellcheck source=/dev/null
. "$SELF_DIR/lib.sh"     # gs_run_job (helper compartido con relaunch.sh)
load_env

GS_PM_WT="${GS_PM_WT:-${WT:-gs_pm_goldenslice}}"
GS_LEGACY_WT="${GS_LEGACY_WT:-${LEGACYWT:-gs_legacy_goldenslice}}"
GS_BASE="${GS_BASE:-develop}"
PM_REPO="$WRAPPER_DIR/pl-programa-maestro"
LEGACY_REPO="$WRAPPER_DIR/pl-pm-legacy"
WORKTREES="$WRAPPER_DIR/worktrees"

gs_log(){ printf '== [goldenslice-up] %s\n' "$*"; }
gs_die(){ printf 'ERROR [goldenslice-up]: %s\n' "$*" >&2; exit 1; }

# MODO WORKTREE (req2/req3): WT=/LEGACYWT= (perillas del Makefile) activan "usa el worktree TAL CUAL, sin tocar
# git". Se detecta por las perillas CRUDAS; sin ninguna de las dos => comportamiento canonico (worktrees
# desechables en origin/<base>, req1.1). En modo worktree ambos son explicitos y obligatorios (D2): no se adivina
# el par pm/legado. El override de bajo nivel GS_PM_WT/GS_LEGACY_WT por env conserva su semantica canonica (git).
GS_WT_MODE=0
if [ -n "${WT:-}" ] || [ -n "${LEGACYWT:-}" ]; then
  GS_WT_MODE=1
  [ -n "${WT:-}" ] || gs_die "modo worktree: falta WT=<pm-wt> (LEGACYWT='${LEGACYWT:-}' dado). Uso: make goldenslice-up WT=<pm-wt> LEGACYWT=<legacy-wt>"
  [ -n "${LEGACYWT:-}" ] || gs_die "modo worktree: falta LEGACYWT=<legacy-wt> (WT='${WT:-}' dado). Uso: make goldenslice-up WT=<pm-wt> LEGACYWT=<legacy-wt>"
  gs_log "modo worktree: pm='$GS_PM_WT' legado='$GS_LEGACY_WT' (codigo tal cual, sin fetch/stash/checkout)"
fi

# --- instrumentacion de tiempos por fase (aditiva; no altera la logica ni los codigos de salida) ---
# El artefacto es maquina-legible: una linea 'fase|segundos' por fase + 'TOTAL|<wall-clock>' al final. Usa
# date +%s (segundos epoch, wall-clock); NO usa gdate ni date +%s.%N (pueden faltar en macdata/macOS).
# PM_TIMING_LOG se EXPORTA antes de la fase 3 para que seed-slot.sh escriba sus sub-fases al MISMO archivo.
: "${PM_TIMING_LOG:=$WRAPPER_DIR/gs-pl-pm-macops-sidecar/artifacts/goldenslice-timing/goldenslice-up-$(date -u +%Y%m%dT%H%M%SZ).log}"
mkdir -p "$(dirname "$PM_TIMING_LOG")"
export PM_TIMING_LOG
GS_START_EPOCH="$(date +%s)"

# _gs_timing registra el wall-clock de una fase: escribe 'fase|segundos' al artefacto y a stdout con prefijo [timing].
_gs_timing(){  # <fase> <t0-epoch>
  local fase="$1"
  local t0="$2"
  local dur=$(( $(date +%s) - t0 ))
  printf '%s|%s\n' "$fase" "$dur" >> "$PM_TIMING_LOG"
  printf '[timing] %s|%s\n' "$fase" "$dur"
}

# El SQL del slot arranca VACIO (esquema EF, sin el seed handcrafted): fiel a un deploy limpio. Los catalogos se
# pueblan DESPUES desde el golden Oracle (catalog-load + intake-load). Exportado => fluye a wt-up y al wt-up
# interno de e2e-up. Inerte para cualquier otro slot (solo make golden lo fija).
export PM_WT_SKIP_PLANNING_SEED=1

wt_require_intel || exit 1

# 1) worktrees canonicos en origin/<base>. stash+checkout (no reset --hard): preserva cambios locales (D18).
gs_ensure_worktree(){  # <repo> <wt_name>
  local repo="$1" name="$2"          # decls separadas: los libs activan 'set -u' y 'local a=$1 b=$WORKTREES/$a'
  local path="$WORKTREES/$name"      # expande $a ANTES de asignarlo (gotcha de local multi-asignacion)
  [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || gs_die "repo no encontrado: $repo"
  if [ "$GS_WT_MODE" = 1 ]; then
    # Modo worktree (req2/ac1): usa el worktree TAL CUAL, sin tocar git (ni fetch, ni stash, ni checkout). Debe
    # PRE-EXISTIR (lo crea el usuario con 'new-worktree'); no se crea ni se mueve HEAD aqui (elegir un branch
    # tocaria git). El usuario maneja git por su cuenta (incluido git pull --rebase origin develop).
    [ -d "$path" ] || gs_die "el worktree '$name' no existe en $path (modo WT=/LEGACYWT=): crealo con 'new-worktree' (o 'git worktree add') y deja tu codigo antes de correr golden"
    gs_log "worktree $name: modo WT= (codigo tal cual; branch $(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?'), sin fetch/stash/checkout)"
    return 0
  fi
  git -C "$repo" fetch origin "$GS_BASE" >/dev/null 2>&1 || gs_die "git fetch origin $GS_BASE fallo en $repo"
  if [ -d "$path" ]; then
    gs_log "worktree $name: git stash (autostash) + checkout origin/$GS_BASE"
    git -C "$path" stash push -u -m "goldenslice-up autostash $(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo now)" >/dev/null 2>&1 || true
    git -C "$path" checkout --detach "origin/$GS_BASE" >/dev/null 2>&1 || gs_die "checkout origin/$GS_BASE fallo en $path"
  else
    gs_log "creando worktree $name en origin/$GS_BASE"
    git -C "$repo" worktree add --detach "$path" "origin/$GS_BASE" >/dev/null 2>&1 || gs_die "git worktree add fallo ($name en $path)"
  fi
}
t0=$(date +%s)
gs_ensure_worktree "$PM_REPO" "$GS_PM_WT"
gs_ensure_worktree "$LEGACY_REPO" "$GS_LEGACY_WT"
_gs_timing "worktrees" "$t0"
LEGACY_SRC="$WORKTREES/$GS_LEGACY_WT"
[ -f "$LEGACY_SRC/ProgramaMaestroPT.sln" ] || gs_die "el worktree legacy '$LEGACY_SRC' no trae ProgramaMaestroPT.sln"

# I3 (colapso 3x->1x del API, FRIO + TIBIO): la UNICA recreacion del API (fase 2, make wt-up) nace con el env FINAL
# del golden (LN golden + Tools ON), volviendo redundantes la recreacion interna de e2e-up (PM_E2E_SKIP_WTUP=1 en la
# fase 4) y la fase enable-tools (eliminada mas abajo). En TIBIO el slot ya vive en el registro; en FRIO se pre-asigna
# aqui (con reclaim de un arrendamiento muerto, espejo de cmd_wt_up) para computar el env FINAL antes de la fase 2. La
# LN golden aun no existe en frio: la API arranca con esa connstring (al boot migra solo el SQL planning; la LN se lee
# lazy en el intake-load, cuando goldenslice-seed ya la creo). Sin slot asignable => se aborta (goldenslice exige slot).
SLOT_PRE="$(wt_slot_lookup "$GS_PM_WT")"
if [ -z "$SLOT_PRE" ]; then
  # req6.1: sonda de realidad para que la pre-asignacion NO entregue un slot huerfano (env vivo que perdio su fila).
  wt_probe_live_slots || true; GS_LIVE="${WT_LIVE_SLOTS:-}"
  SLOT_PRE="$(wt_registry_lock wt_slot_assign "$GS_PM_WT" "$GS_LIVE" 2>/dev/null || true)"
  if [ -z "$SLOT_PRE" ]; then
    wt_reclaim_dead_leases 0 1 >/dev/null 2>&1 || true
    wt_probe_live_slots || true; GS_LIVE="${WT_LIVE_SLOTS:-}"   # re-sonda tras el reclaim
    SLOT_PRE="$(wt_registry_lock wt_slot_assign "$GS_PM_WT" "$GS_LIVE" 2>/dev/null || true)"
  fi
  [ -n "$SLOT_PRE" ] || gs_die "sin slots libres para goldenslice-up (PM_WT_SLOTS=${PM_WT_SLOTS:-?}); baja un worktree (make wt-down) o sube PM_WT_SLOTS"
  gs_log "slot $SLOT_PRE pre-asignado en FRIO (colapso: env final del golden en la unica recreacion)"
else
  # req6.3 (red de seguridad, drift b3): el slot vino de una fila PRE-EXISTENTE del registro (TIBIO). Si apunta a
  # un slot sin aprovisionar mientras hay un env vivo en otro slot => falla ruidoso (no deploya al fantasma).
  gs_guard_slot_provisioned "$SLOT_PRE" "$GS_PM_WT"
  gs_log "slot $SLOT_PRE ya asignado (TIBIO): env final del golden en la unica recreacion"
fi
export PM_WT_LN_DB="pm_gs_ln_wt${SLOT_PRE}"             # nace apuntando a la LN golden => la recreacion de e2e-up sobra
PLANNING_DB_PRE="pm_planning_wt${SLOT_PRE}"
# Las 9 Tools__* que enable-tools.sh inyectaba en una 3a recreacion; ahora viajan en la UNICA recreacion via el
# passthrough PM_WT_API_EXTRA_ENV de wt_up_api. Valores entre comillas simples: el shell remoto de on_intel los
# separa como los -e hermanos (oracle_env/pm_parity_env_flags). Espeja enable-tools.sh:22-32.
export PM_WT_API_EXTRA_ENV="-e Tools__CatalogLoad__Enabled='true' -e Tools__CatalogLoad__AllowedServers__0='sqlserver,1433' -e Tools__CatalogLoad__AllowedServers__1='sqlserver' -e Tools__CatalogLoad__AllowedDatabases__0='${PLANNING_DB_PRE}' -e Tools__IntakeLoad__Enabled='true' -e Tools__IntakeLoad__CleanLoad='true' -e Tools__IntakeLoad__AllowedServers__0='sqlserver,1433' -e Tools__IntakeLoad__AllowedServers__1='sqlserver' -e Tools__IntakeLoad__AllowedDatabases__0='${PLANNING_DB_PRE}'"
GS_COLLAPSE=1

# 2) provisiona el slot (backend + Oracle propio). El slot se auto-asigna; se deriva del registro.
gs_log "wt-up (slot + Oracle) para $GS_PM_WT ..."
t0=$(date +%s)
make -C "$SIDECAR_DIR" wt-up WT="$GS_PM_WT" ORACLE=1 || gs_die "wt-up fallo"
_gs_timing "wt-up" "$t0"
SLOT="$(wt_slot_lookup "$GS_PM_WT")"
[ -n "$SLOT" ] || gs_die "no se resolvio el slot de $GS_PM_WT tras wt-up"
LN_GS_DB="pm_gs_ln_wt${SLOT}"
gs_log "slot asignado: $SLOT -> LN golden aislada = $LN_GS_DB"

# 2.5) regenera goldenslice/build-wt<N> (CREATE + loaders + CSV concatenados) desde el extract de PROD, en un
#      directorio de build POR SLOT (req4/ac6): asi dos golden concurrentes NO comparten el mismo 'build' (quitaba
#      la ventana de carrera del build compartido). Es gitignored (datos reales) y se regenera SIEMPRE, de modo que
#      cualquier cambio del extract (p. ej. un catalogo re-extraido) fluye al golden sin paso manual. Corre en la M1
#      (solo lee CSV/DDL y escribe SQL/CSV; sin Docker). Se pasa por BUILD= a goldenslice-seed (seed-slot.sh:26).
GS_SRC="${GS_SRC:-$WRAPPER_DIR/gs-pl-pm-macops-sidecar/artifacts/prod-extract-260718}"
GS_BUILD_DIR="$SELF_DIR/build-wt${SLOT}"
command -v python3 >/dev/null 2>&1 || gs_die "python3 no disponible (requerido por generate.py)"
[ -d "$GS_SRC/oracle" ] || gs_die "extract no encontrado: $GS_SRC (falta oracle/)"
gs_log "regenerando goldenslice/build-wt${SLOT} desde el extract ($GS_SRC) ..."
t0=$(date +%s)
python3 "$SELF_DIR/generate.py" --src "$GS_SRC" --out "$GS_BUILD_DIR" >/dev/null || gs_die "generate.py fallo"
_gs_timing "build-regen" "$t0"

# 3) siembra la golden slice (Oracle multi-owner + recompila + LN aislada). Idempotente. BUILD=<build-wt<N>> aisla
#    la fuente de seed por slot (req4).
gs_log "goldenslice-seed SLOT=$SLOT BUILD=build-wt${SLOT} (Oracle golden + LN aislada) ..."
t0=$(date +%s)   # PM_TIMING_LOG ya exportado: seed-slot.sh anexa sus sub-fases al MISMO archivo
make -C "$SIDECAR_DIR" goldenslice-seed SLOT="$SLOT" BUILD="$GS_BUILD_DIR" || gs_die "goldenslice-seed fallo"
_gs_timing "goldenslice-seed" "$t0"

# 4) e2e-up apuntando el pm-api a la LN GOLDEN (PM_WT_LN_DB exportado; WT_ENV no lo pisa). e2e-up recrea el API
#    con la connstring golden, levanta el frontend, activa el flag e imprime las URLs. El smoke puede fallar sin
#    abortar goldenslice-up: el objetivo es dejar el ambiente ARRIBA con URLs para validar en vivo.
gs_log "e2e-up con LN golden ($LN_GS_DB) y SQL VACIO: recrea API + frontend + flag ..."
t0=$(date +%s)
# Con I3 el colapso aplica SIEMPRE (frio + tibio, GS_COLLAPSE=1): PM_E2E_SKIP_WTUP=1 evita la 2a recreacion
# redundante del API (el backend+Oracle ya viven desde la fase 2 con el env FINAL) y PM_E2E_SKIP_SMOKE=1 salta el
# smoke de paridad (el ambiente queda arriba; el smoke se corre aparte con 'make e2e-smoke').
PM_WT_LN_DB="$LN_GS_DB" PM_E2E_SKIP_WTUP="${GS_COLLAPSE:-0}" PM_E2E_SKIP_SMOKE="${GS_COLLAPSE:-0}" \
  make -C "$SIDECAR_DIR" e2e-up WT="$GS_PM_WT" LEGACYSRC="$LEGACY_SRC" \
  || gs_log "AVISO: e2e-up salio con codigo != 0 (revisa el smoke arriba); el ambiente puede estar arriba: usa 'make e2e-url WT=$GS_PM_WT'"
_gs_timing "e2e-up" "$t0"

# --- 5) poblar los CATALOGOS/insumos del golden en el SQL VACIO (sin pantalla), como un deploy limpio. El intake
#        REAL (produce el plan) queda MANUAL desde la app (OrdenesNuevasCargar_LN.aspx). ---
ctx="$(remote_docker_ctx)"
API_C="pm-wt${SLOT}-api"; ORA_C="pm-wt${SLOT}-oracle-1"; PLANNING_DB="pm_planning_wt${SLOT}"; OH="$PM_WT_ORACLE_HOME"
API_PORT="$(on_intel "docker $ctx port '$API_C' 8080/tcp 2>/dev/null" 2>/dev/null | head -1 | sed 's/.*://' | tr -d '\r')"
[ -n "$API_PORT" ] || gs_die "no se resolvio el puerto publicado del API $API_C"

# 5a) fase enable-tools ELIMINADA (I3): las Tools dev de carga (CatalogLoad + IntakeLoad) entran en la UNICA
#     recreacion del API (fase 2, via PM_WT_API_EXTRA_ENV), en FRIO y en TIBIO. La 3a recreacion redundante ya no
#     existe. El script goldenslice/enable-tools.sh se conserva como fuente canonica de las 9 Tools__* que este flujo
#     y relaunch.sh espejan.

# helper gs_run_job (POST a un tool-job + poll a Completed): extraido a goldenslice/lib.sh y compartido con
# relaunch.sh (sourceado arriba). Depende de API_PORT + PM_REMOTE_SSH, ya resueltos en este punto.

# 5b) I7: gate de loaders (resuelve RISK 7). Sondea (a) el marcador de seed de I6 (¿cambio el extract?) y (b) los
#     conteos de planning (6 estrategia CatalogTableMap + 11 convergencia CatalogsConvergenceDescriptors). Si el
#     seed NO cambio y planning esta poblada => SKIP de los loaders (re-run tibio, ac5). Si el extract cambio o
#     falta poblar => corre los loaders DIRIGIDO por grupo vacio (en frio ambos vacios => ambos, como el flujo
#     original: catalog-load Clean = 11 convergencia; intake-load Clean = 6 estrategia + 3 convergencia).
seed_status="$(ssh "$PM_REMOTE_SSH" "cat ~/goldenslice-bin/seed-status-wt${SLOT} 2>/dev/null" || true)"
seed_reseeded="$(printf '%s\n' "$seed_status" | sed -nE 's/^SEED_RESEEDED_COUNT=([0-9]+).*/\1/p' | head -1)"
[ -n "$seed_reseeded" ] || seed_reseeded=1     # sin status legible => conservador: trata el extract como cambiado
sql_pw="$(wt_shared_sql_password)" || gs_die "no se resolvio el SA del SQL compartido para el gate de loaders"
wt_shared_sql_check || gs_die "el SQL compartido no esta disponible para el gate de loaders"
empty_strategy="$(gs_list_empty "$sql_pw" "$PLANNING_DB" $GS_STRATEGY_TABLES)"
empty_converg="$(gs_list_empty "$sql_pw" "$PLANNING_DB" $GS_CONVERGENCE_TABLES)"
need_catalog=0; need_intake=0
if [ "$seed_reseeded" != 0 ]; then
  need_catalog=1; need_intake=1
  gs_log "loaders: el extract cambio (SEED_RESEEDED_COUNT=$seed_reseeded) => recarga completa (catalog-load + intake-load)"
else
  if [ -n "$empty_converg" ]; then need_catalog=1; fi
  if [ -n "$empty_strategy" ]; then need_intake=1; fi
fi
if [ "$need_catalog" = 0 ] && [ "$need_intake" = 0 ]; then
  gs_log "[skip] loaders: planning poblada y seed sin cambio (estrategia 6/6, convergencia 11/11); 0 recargas"
  _gs_timing "catalog-load" "$(date +%s)"
  _gs_timing "intake-load" "$(date +%s)"
else
  if [ "$need_catalog" = 1 ]; then
    gs_log "catalog-load (clean) desde el golden Oracle ..."
    t0=$(date +%s)
    gs_run_job "/api/v1/tools/catalog-load" '{"clean":true}' "catalog-load" || gs_log "AVISO: catalog-load no completo limpio"
    _gs_timing "catalog-load" "$t0"
  else
    gs_log "[skip] catalog-load: convergencia ya poblada (11/11)"
    _gs_timing "catalog-load" "$(date +%s)"
  fi
  if [ "$need_intake" = 1 ]; then
    gs_log "intake-load (clean) desde el golden Oracle ..."
    t0=$(date +%s)
    gs_run_job "/api/v1/tools/intake-load" "" "intake-load" || gs_log "AVISO: intake-load no completo limpio"
    _gs_timing "intake-load" "$t0"
  else
    gs_log "[skip] intake-load: estrategia ya poblada (6/6)"
    _gs_timing "intake-load" "$(date +%s)"
  fi
fi

# 6) registrar el menu UBO (Administracion -> Operaciones Masivas + 7 paginas) en el golden Oracle. El .sql es
#    idempotente (NOT EXISTS) y NO commitea: se agrega COMMIT. El menu (Site.Master -> WCF -> pge_ctrlpiso.MENU)
#    lo sirve Oracle, no el SQL.
gs_log "registrando el menu UBO (Operaciones Masivas) en el golden Oracle ..."
t0=$(date +%s)
ssh "$PM_REMOTE_SSH" "mkdir -p ~/goldenslice-bin" >/dev/null
rsync -az "$SELF_DIR/insert-menu-operaciones-masivas.sql" "$PM_REMOTE_SSH:~/goldenslice-bin/menu-ubo.sql" >/dev/null
on_intel "docker $ctx cp \$HOME/goldenslice-bin/menu-ubo.sql '$ORA_C:/tmp/menu-ubo.sql'"
printf '@/tmp/menu-ubo.sql\nCOMMIT;\n' | on_intel "docker $ctx exec -i -e ORACLE_HOME='$OH' '$ORA_C' bash -c 'export PATH=\$ORACLE_HOME/bin:\$PATH; sqlplus -S system/oracle@localhost:1521/XE'" 2>/dev/null | tr -d '\r' | tail -12
_gs_timing "menu-ubo" "$t0"

# 7) reimprime el recuadro de acceso (URLs desde M1). I9 (resuelve RISK 10): e2e-url puede COLGARSE (re-levanta el
#    tunel SSH; el outlier de 22993 s fue un HANG que '2>/dev/null || true' NO atrapa). Se acota con gs_run_bounded
#    (timeout portable background+watchdog; macOS NO tiene 'timeout'). Un cuelgue produce aviso accionable en <= N s
#    y NO cuelga la corrida; el ambiente ya quedo arriba en las fases previas.
t0=$(date +%s)
if gs_run_bounded "${GS_E2E_URL_TIMEOUT:-90}" "e2e-url" -- make -C "$SIDECAR_DIR" e2e-url WT="$GS_PM_WT"; then :; else
  rc=$?
  if [ "$rc" = 124 ]; then
    gs_log "[TIMEOUT] e2e-url colgo > ${GS_E2E_URL_TIMEOUT:-90}s; el ambiente puede estar arriba: reintenta 'make e2e-url WT=$GS_PM_WT' o revisa el tunel $(( 18100 + SLOT ))"
  else
    gs_log "AVISO: e2e-url salio con rc=$rc; reintenta 'make e2e-url WT=$GS_PM_WT'"
  fi
fi
_gs_timing "e2e-url" "$t0"
_gs_timing "TOTAL" "$GS_START_EPOCH"
gs_log "timing por fase persistido en $PM_TIMING_LOG"
gs_log "goldenslice-up LISTO (slot $SLOT). SQL golden VACIO + catalogos/insumos cargados desde el golden Oracle; menu UBO registrado."
gs_log "El intake RES se dispara MANUAL desde la app: http://localhost:$(( 18100 + SLOT ))/ProgramaMaestroLN/ (OrdenesNuevasCargar_LN). Reimprime URL: make e2e-url WT=$GS_PM_WT"
# req5/ac7: banner final GARANTIZADO (independiente del recuadro de e2e-url, que puede timeoutear y saltarse).
gs_banner "$SLOT" "$GS_PM_WT" "$GS_LEGACY_WT" "$API_PORT"
