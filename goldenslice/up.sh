#!/usr/bin/env bash
# goldenslice-up (D18): levanta un ambiente E2E completo sembrado con la golden slice (datos reales de PROD,
# ventana FY2026 sem 18-25) y accesible desde la M1. SIN parametros: usa checkouts canonicos.
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
# Overrides (con default): GS_PM_WT, GS_LEGACY_WT (nombres de worktree), GS_BASE (rama base, default develop).
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

GS_PM_WT="${GS_PM_WT:-gs_pm_goldenslice}"
GS_LEGACY_WT="${GS_LEGACY_WT:-gs_legacy_goldenslice}"
GS_BASE="${GS_BASE:-develop}"
PM_REPO="$WRAPPER_DIR/pl-programa-maestro"
LEGACY_REPO="$WRAPPER_DIR/pl-pm-legacy"
WORKTREES="$WRAPPER_DIR/worktrees"

gs_log(){ printf '== [goldenslice-up] %s\n' "$*"; }
gs_die(){ printf 'ERROR [goldenslice-up]: %s\n' "$*" >&2; exit 1; }

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

# I6 (colapso 3x->1x del API): en corrida TIBIA el slot ya vive en el registro, asi que la LN golden y las Tools
# son computables ANTES de la fase 2. Pre-resolverlo permite que la UNICA recreacion (fase 2) nazca con el env
# FINAL (LN golden + Tools ON), volviendo redundantes la recreacion interna de e2e-up y la de enable-tools.
# FALLBACK FRIO: si el slot aun no existe (SLOT_PRE vacio), GS_COLLAPSE=0 y la ruta actual queda intacta (3x).
SLOT_PRE="$(wt_slot_lookup "$GS_PM_WT")"
if [ -n "$SLOT_PRE" ]; then
  export PM_WT_LN_DB="pm_gs_ln_wt${SLOT_PRE}"          # (a) nace apuntando a la LN golden => la recreacion (b) sobra
  PLANNING_DB_PRE="pm_planning_wt${SLOT_PRE}"
  # Las 9 Tools__* que enable-tools.sh (fase 5a) inyectaba en una 3a recreacion; ahora viajan en la recreacion (a)
  # via el passthrough PM_WT_API_EXTRA_ENV de wt_up_api. Valores entre comillas simples: el shell remoto de on_intel
  # los separa como los -e hermanos (oracle_env/pm_parity_env_flags). Espeja enable-tools.sh:22-32.
  export PM_WT_API_EXTRA_ENV="-e Tools__CatalogLoad__Enabled='true' -e Tools__CatalogLoad__AllowedServers__0='sqlserver,1433' -e Tools__CatalogLoad__AllowedServers__1='sqlserver' -e Tools__CatalogLoad__AllowedDatabases__0='${PLANNING_DB_PRE}' -e Tools__IntakeLoad__Enabled='true' -e Tools__IntakeLoad__CleanLoad='true' -e Tools__IntakeLoad__AllowedServers__0='sqlserver,1433' -e Tools__IntakeLoad__AllowedServers__1='sqlserver' -e Tools__IntakeLoad__AllowedDatabases__0='${PLANNING_DB_PRE}'"
  GS_COLLAPSE=1
  gs_log "colapso TIBIO activo: slot $SLOT_PRE pre-resuelto => LN golden ($PM_WT_LN_DB) + Tools ON en la unica recreacion (fase 2)"
else
  GS_COLLAPSE=0
  gs_log "corrida FRIA: slot aun no asignado; ruta actual (3 recreaciones del API)"
fi

# 2) provisiona el slot (backend + Oracle propio). El slot se auto-asigna; se deriva del registro.
gs_log "wt-up (slot + Oracle) para $GS_PM_WT ..."
t0=$(date +%s)
make -C "$SIDECAR_DIR" wt-up WT="$GS_PM_WT" ORACLE=1 || gs_die "wt-up fallo"
_gs_timing "wt-up" "$t0"
SLOT="$(wt_slot_lookup "$GS_PM_WT")"
[ -n "$SLOT" ] || gs_die "no se resolvio el slot de $GS_PM_WT tras wt-up"
LN_GS_DB="pm_gs_ln_wt${SLOT}"
gs_log "slot asignado: $SLOT -> LN golden aislada = $LN_GS_DB"

# 2.5) regenera goldenslice/build (CREATE + loaders + CSV concatenados) desde el extract de PROD. El build es
#      gitignored (datos reales) y se regenera SIEMPRE, de modo que cualquier cambio del extract (p. ej. un
#      catalogo re-extraido) fluye al golden sin paso manual. Corre en la M1 (solo lee CSV/DDL y escribe SQL/CSV;
#      sin Docker). seed-slot.sh consume $SELF_DIR/build; el default de su SRC coincide con GS_SRC.
GS_SRC="${GS_SRC:-$WRAPPER_DIR/gs-pl-pm-macops-sidecar/artifacts/prod-extract-260718}"
command -v python3 >/dev/null 2>&1 || gs_die "python3 no disponible (requerido por generate.py)"
[ -d "$GS_SRC/oracle" ] || gs_die "extract no encontrado: $GS_SRC (falta oracle/)"
gs_log "regenerando goldenslice/build desde el extract ($GS_SRC) ..."
t0=$(date +%s)
python3 "$SELF_DIR/generate.py" --src "$GS_SRC" --out "$SELF_DIR/build" >/dev/null || gs_die "generate.py fallo"
_gs_timing "build-regen" "$t0"

# 3) siembra la golden slice (Oracle multi-owner + recompila + LN aislada). Idempotente.
gs_log "goldenslice-seed SLOT=$SLOT (Oracle golden + LN aislada) ..."
t0=$(date +%s)   # PM_TIMING_LOG ya exportado: seed-slot.sh anexa sus sub-fases al MISMO archivo
make -C "$SIDECAR_DIR" goldenslice-seed SLOT="$SLOT" || gs_die "goldenslice-seed fallo"
_gs_timing "goldenslice-seed" "$t0"

# 4) e2e-up apuntando el pm-api a la LN GOLDEN (PM_WT_LN_DB exportado; WT_ENV no lo pisa). e2e-up recrea el API
#    con la connstring golden, levanta el frontend, activa el flag e imprime las URLs. El smoke puede fallar sin
#    abortar goldenslice-up: el objetivo es dejar el ambiente ARRIBA con URLs para validar en vivo.
gs_log "e2e-up con LN golden ($LN_GS_DB) y SQL VACIO: recrea API + frontend + flag ..."
t0=$(date +%s)
# En el colapso (GS_COLLAPSE=1): PM_E2E_SKIP_WTUP=1 evita la recreacion (b) redundante del API (el backend+Oracle
# ya viven desde la fase 2) y PM_E2E_SKIP_SMOKE=1 salta el smoke de paridad (el ambiente queda arriba; el smoke se
# corre aparte con 'make e2e-smoke'). Ambos default 0 en frio => e2e-up sin cambio.
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

# 5a) habilitar los tools dev de carga (recrea el API preservando env/redes + Tools:CatalogLoad/IntakeLoad ON).
# I6-4: en el colapso las Tools ya viajaron en la unica recreacion (fase 2) via PM_WT_API_EXTRA_ENV, asi que esta
# 3a recreacion es redundante y se OMITE (registra enable-tools|0 para que la tabla de tiempos siga completa).
if [ "${GS_COLLAPSE:-0}" = 1 ]; then
  gs_log "enable-tools OMITIDO (colapso): las Tools ya viajaron en la unica recreacion (fase 2)"
  _gs_timing "enable-tools" "$(date +%s)"
else
  gs_log "habilitando tools de carga en el API del slot (catalog-load + intake-load) ..."
  t0=$(date +%s)
  ssh "$PM_REMOTE_SSH" "mkdir -p ~/goldenslice-bin" >/dev/null
  rsync -az "$SELF_DIR/enable-tools.sh" "$PM_REMOTE_SSH:~/goldenslice-bin/enable-tools.sh" >/dev/null
  ssh "$PM_REMOTE_SSH" "zsh -lc 'bash ~/goldenslice-bin/enable-tools.sh $API_C $PLANNING_DB'" || gs_die "fallo habilitar los tools de carga"
  _gs_timing "enable-tools" "$t0"
fi

# helper gs_run_job (POST a un tool-job + poll a Completed): extraido a goldenslice/lib.sh y compartido con
# relaunch.sh (sourceado arriba). Depende de API_PORT + PM_REMOTE_SSH, ya resueltos en este punto.

# 5b) catalog-load Clean (11 catalogos Catalogs.* desde el golden Oracle) + intake-load Clean (insumo: 3 de
#     convergencia + 6 de estrategia). SQL vacio => es carga inicial limpia, no reemplaza handcrafted.
gs_log "catalog-load (clean) desde el golden Oracle ..."
t0=$(date +%s)
gs_run_job "/api/v1/tools/catalog-load" '{"clean":true}' "catalog-load" || gs_log "AVISO: catalog-load no completo limpio"
_gs_timing "catalog-load" "$t0"
gs_log "intake-load (clean) desde el golden Oracle ..."
t0=$(date +%s)
gs_run_job "/api/v1/tools/intake-load" "" "intake-load" || gs_log "AVISO: intake-load no completo limpio"
_gs_timing "intake-load" "$t0"

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

# 7) reimprime el recuadro de acceso (URLs desde M1). El intake es MANUAL desde la app.
t0=$(date +%s)
make -C "$SIDECAR_DIR" e2e-url WT="$GS_PM_WT" 2>/dev/null || true
_gs_timing "e2e-url" "$t0"
_gs_timing "TOTAL" "$GS_START_EPOCH"
gs_log "timing por fase persistido en $PM_TIMING_LOG"
gs_log "goldenslice-up LISTO (slot $SLOT). SQL golden VACIO + catalogos/insumos cargados desde el golden Oracle; menu UBO registrado."
gs_log "El intake RES se dispara MANUAL desde la app: http://localhost:$(( 18100 + SLOT ))/ProgramaMaestroLN/ (OrdenesNuevasCargar_LN). Reimprime URL: make e2e-url WT=$GS_PM_WT"
