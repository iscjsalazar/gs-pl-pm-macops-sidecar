#!/usr/bin/env bash
# goldenslice-relaunch (ac6): actualiza, recompila y relanza AMBAS apps (pm-api .NET + legado ASP.NET) con la
# ultima origin/develop SIN rehacer el seed. Reusa el Oracle/LN golden y la BD planning ya sembrada/cargada por
# un goldenslice-up previo: recrea el pm-api contra las MISMAS BD, redespliega el legado, reactiva el flag e
# imprime las URLs de acceso desde la M1. Es goldenslice-up MENOS el seed (goldenslice-seed), los loaders
# (catalog-load/intake-load) y el registro del menu UBO.
#
# Flujo:
#   1) PRECONDICION: el slot del worktree ya existe (Oracle golden + LN golden + BD planning cargada). Si no ⇒
#      error sugiriendo 'make goldenslice-up'. El slot se deriva del registro (wt_slot_lookup).
#   2) worktrees canonicos pm + legacy a origin/develop (git stash + checkout: preserva cambios locales, D18).
#   3) recrea el pm-api contra las MISMAS BD (LN golden + planning ya cargada) via 'make wt-up ORACLE=1' con
#      PM_WT_SKIP_PLANNING_SEED=1 (no re-siembra planning) y el env FINAL del golden exportado (LN golden +
#      Tools ON), como el colapso de I6. NO llama goldenslice-seed: el Oracle/LN golden y la BD planning
#      persisten intactos en el motor compartido.
#   4) recompila y redespliega el legado con la ultima develop via 'make e2e-up' con PM_E2E_FORCE=1 (fuerza
#      legacy-build+deploy: toma el codigo nuevo) + PM_E2E_SKIP_WTUP=1 (el API ya lo recreo el paso 3) +
#      PM_E2E_SKIP_SMOKE=1 (ambiente arriba; smoke aparte con 'make e2e-smoke'). e2e-up reactiva el flag
#      carga-backend/RES e imprime las URLs.
#   5) reimprime el recuadro de acceso (URLs desde M1). NO seed, NO catalog/intake-load, NO menu (ya registrado).
#      R4: si el pull trae migraciones EF que tocan el schema de catalogos, AVISA (no recarga en silencio).
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
load_env

# El slot del worktree pm es parametrizable por WT= (Make lo propaga via PM_ENV); GS_PM_WT gana si se fija
# explicito; si ambos vacios, el default canonico gs_pm_goldenslice. El worktree legado usa GS_LEGACY_WT.
GS_PM_WT="${GS_PM_WT:-${WT:-gs_pm_goldenslice}}"
GS_LEGACY_WT="${GS_LEGACY_WT:-gs_legacy_goldenslice}"
GS_BASE="${GS_BASE:-develop}"
PM_REPO="$WRAPPER_DIR/pl-programa-maestro"
LEGACY_REPO="$WRAPPER_DIR/pl-pm-legacy"
WORKTREES="$WRAPPER_DIR/worktrees"

gs_log(){ printf '== [goldenslice-relaunch] %s\n' "$*"; }
gs_die(){ printf 'ERROR [goldenslice-relaunch]: %s\n' "$*" >&2; exit 1; }

# --- instrumentacion de tiempos por fase (aditiva; no altera la logica ni los codigos de salida) ---
# El artefacto es maquina-legible: una linea 'fase|segundos' por fase + 'TOTAL|<wall-clock>' al final. Usa
# date +%s (segundos epoch, wall-clock); NO usa gdate ni date +%s.%N (pueden faltar en macdata/macOS).
: "${PM_TIMING_LOG:=$WRAPPER_DIR/gs-pl-pm-macops-sidecar/artifacts/goldenslice-timing/goldenslice-relaunch-$(date -u +%Y%m%dT%H%M%SZ).log}"
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

# El relaunch NO re-siembra la BD planning: reusa la que goldenslice-up dejo cargada. Exportado => fluye a wt-up.
# Espeja goldenslice-up (up.sh): el SQL golden se poblo desde el golden Oracle (catalog-load + intake-load) y esa
# carga persiste en el motor compartido; recrear el API no la toca.
export PM_WT_SKIP_PLANNING_SEED=1

wt_require_intel || exit 1

# 1) PRECONDICION: el slot ya existe. relaunch reusa un slot YA aprovisionado y sembrado por goldenslice-up; a
#    diferencia de up.sh (que auto-asigna el slot en frio), aqui un slot ausente es un error, no un fallback.
SLOT="$(wt_slot_lookup "$GS_PM_WT")"
[ -n "$SLOT" ] || gs_die "el worktree '$GS_PM_WT' no tiene slot asignado: corre 'make goldenslice-up' primero (relaunch reusa un slot ya sembrado; no siembra)"
LN_GS_DB="pm_gs_ln_wt${SLOT}"
PLANNING_DB="pm_planning_wt${SLOT}"
gs_log "slot pre-existente $SLOT -> LN golden=$LN_GS_DB, planning=$PLANNING_DB (reuso sin re-sembrar)"

# 2) worktrees canonicos a origin/<base>. stash+checkout (no reset --hard): preserva cambios locales (D18).
#    Mirror de up.sh:gs_ensure_worktree (misma logica; se copia para no sourcear up.sh, que ejecutaria todo su flujo).
gs_ensure_worktree(){  # <repo> <wt_name>
  local repo="$1" name="$2"          # decls separadas: los libs activan 'set -u' y 'local a=$1 b=$WORKTREES/$a'
  local path="$WORKTREES/$name"      # expande $a ANTES de asignarlo (gotcha de local multi-asignacion)
  [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || gs_die "repo no encontrado: $repo"
  git -C "$repo" fetch origin "$GS_BASE" >/dev/null 2>&1 || gs_die "git fetch origin $GS_BASE fallo en $repo"
  if [ -d "$path" ]; then
    gs_log "worktree $name: git stash (autostash) + checkout origin/$GS_BASE"
    git -C "$path" stash push -u -m "goldenslice-relaunch autostash $(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo now)" >/dev/null 2>&1 || true
    git -C "$path" checkout --detach "origin/$GS_BASE" >/dev/null 2>&1 || gs_die "checkout origin/$GS_BASE fallo en $path"
  else
    gs_log "creando worktree $name en origin/$GS_BASE"
    git -C "$repo" worktree add --detach "$path" "origin/$GS_BASE" >/dev/null 2>&1 || gs_die "git worktree add fallo ($name en $path)"
  fi
}

# R4: avisa (no recarga en silencio) si el pull trae migraciones EF del modulo Catalogs. El relaunch NO recarga
# catalogos; si el schema de catalogos cambio, la BD planning reusada quedaria desalineada y hay que re-sembrar.
gs_warn_catalog_migrations(){  # <pm_path> <head_before> <head_after>
  local path="$1" before="$2" after="$3" changed
  { [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; } || return 0
  changed="$(git -C "$path" diff --name-only "$before" "$after" 2>/dev/null | grep -Ei 'Modules/Catalogs/.*/Migrations/.*\.cs$' || true)"
  [ -n "$changed" ] || return 0
  gs_log "AVISO (R4): el pull a origin/$GS_BASE trae migraciones EF del modulo Catalogs:"
  printf '  - %s\n' $changed
  gs_log "AVISO (R4): goldenslice-relaunch NO recarga catalogos; si el schema de catalogos cambio, re-corre 'make goldenslice-up' para re-sembrar."
}

t0=$(date +%s)
PM_PATH="$WORKTREES/$GS_PM_WT"
PM_HEAD_BEFORE="$(git -C "$PM_PATH" rev-parse HEAD 2>/dev/null || echo '')"
gs_ensure_worktree "$PM_REPO" "$GS_PM_WT"
gs_ensure_worktree "$LEGACY_REPO" "$GS_LEGACY_WT"
_gs_timing "worktrees" "$t0"
LEGACY_SRC="$WORKTREES/$GS_LEGACY_WT"
[ -f "$LEGACY_SRC/ProgramaMaestroPT.sln" ] || gs_die "el worktree legacy '$LEGACY_SRC' no trae ProgramaMaestroPT.sln"
PM_HEAD_AFTER="$(git -C "$PM_PATH" rev-parse HEAD 2>/dev/null || echo '')"
gs_warn_catalog_migrations "$PM_PATH" "$PM_HEAD_BEFORE" "$PM_HEAD_AFTER"
gs_log "R4: el relaunch reusa los catalogos ya cargados; NO los recarga. Si cambiaste el schema de catalogos, re-corre 'make goldenslice-up'."

# 3) recrea el pm-api contra las MISMAS BD (LN golden + planning ya cargada). Espeja el env FINAL del golden que
#    goldenslice-up deja (colapso I6): la UNICA recreacion (wt_up_api hace 'docker rm -f' + create) nace con la LN
#    golden (PM_WT_LN_DB) y las Tools ON (PM_WT_API_EXTRA_ENV), de modo que el API relanzado queda en el MISMO
#    estado de env que produce goldenslice-up. NO se llama goldenslice-seed: el Oracle/LN golden no se tocan y la
#    BD planning pm_planning_wt<N> persiste en el motor compartido con los catalogos/insumos ya cargados.
export PM_WT_LN_DB="$LN_GS_DB"
# Las 9 Tools__* del env FINAL del golden (espeja enable-tools.sh:22-32 y el passthrough de up.sh). Valores entre
# comillas simples: el shell remoto de on_intel los separa como los -e hermanos. relaunch NO invoca los loaders;
# las Tools solo quedan disponibles para preservar el env FINAL del golden (P1: mismo estado observable).
export PM_WT_API_EXTRA_ENV="-e Tools__CatalogLoad__Enabled='true' -e Tools__CatalogLoad__AllowedServers__0='sqlserver,1433' -e Tools__CatalogLoad__AllowedServers__1='sqlserver' -e Tools__CatalogLoad__AllowedDatabases__0='${PLANNING_DB}' -e Tools__IntakeLoad__Enabled='true' -e Tools__IntakeLoad__CleanLoad='true' -e Tools__IntakeLoad__AllowedServers__0='sqlserver,1433' -e Tools__IntakeLoad__AllowedServers__1='sqlserver' -e Tools__IntakeLoad__AllowedDatabases__0='${PLANNING_DB}'"
gs_log "recrea pm-api (wt-up ORACLE=1) contra LN golden $LN_GS_DB + planning $PLANNING_DB; SKIP_PLANNING_SEED, Tools ON, sin re-sembrar ..."
t0=$(date +%s)
make -C "$SIDECAR_DIR" wt-up WT="$GS_PM_WT" ORACLE=1 || gs_die "wt-up (recreate API) fallo"
_gs_timing "wt-up" "$t0"

# 4) recompila y redespliega el legado con la ultima develop, reactiva el flag e imprime URLs. e2e-up con:
#    PM_E2E_FORCE=1      => fuerza legacy-build+deploy (toma el codigo nuevo; no confia en el health-200-skip);
#    PM_E2E_SKIP_WTUP=1  => el API ya lo recreo el paso 3 (evita una 2a recreacion redundante, colapso I6-3);
#    PM_E2E_SKIP_SMOKE=1 => salta el smoke de paridad (el ambiente queda arriba; smoke aparte 'make e2e-smoke').
#    PM_WT_LN_DB se reexporta por simetria con up.sh (inerte aqui: con SKIP_WTUP e2e-up no recrea el API).
#    El smoke saltado y un rc != 0 no abortan: el objetivo es dejar ambos apps ARRIBA con URLs.
gs_log "e2e-up (legacy rebuild+redeploy FORCE, sin re-recrear API, sin smoke): toma la develop nueva del legado + reactiva flag + URLs ..."
t0=$(date +%s)
PM_WT_LN_DB="$LN_GS_DB" PM_E2E_FORCE=1 PM_E2E_SKIP_WTUP=1 PM_E2E_SKIP_SMOKE=1 \
  make -C "$SIDECAR_DIR" e2e-up WT="$GS_PM_WT" LEGACYSRC="$LEGACY_SRC" \
  || gs_log "AVISO: e2e-up salio con codigo != 0 (revisa arriba); el ambiente puede estar arriba: usa 'make e2e-url WT=$GS_PM_WT'"
_gs_timing "e2e-up" "$t0"

# 5) reimprime el recuadro de acceso (URLs desde M1) y re-levanta el tunel si murio. NO seed, NO catalog/intake-load,
#    NO menu (ya registrado por goldenslice-up).
t0=$(date +%s)
make -C "$SIDECAR_DIR" e2e-url WT="$GS_PM_WT" 2>/dev/null || true
_gs_timing "e2e-url" "$t0"
_gs_timing "TOTAL" "$GS_START_EPOCH"
gs_log "timing por fase persistido en $PM_TIMING_LOG"
gs_log "goldenslice-relaunch LISTO (slot $SLOT). Ambas apps relanzadas con origin/$GS_BASE; Oracle/LN golden + BD planning INTACTOS (no re-sembrados)."
gs_log "Acceso al legado: http://localhost:$(( 18100 + SLOT ))/ProgramaMaestroLN/ . Reimprime URL: make e2e-url WT=$GS_PM_WT"
