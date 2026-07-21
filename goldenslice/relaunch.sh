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
#   4) recompila y redespliega el legado con la ultima develop via 'make e2e-up' con PM_E2E_FORCE condicionado al
#      SHA del worktree legacy (I4: fuerza legacy-build+deploy solo si el legado cambio, o FORCE=1 manual; sin cambio
#      delega el skip por health==200 a legacy.sh) + PM_E2E_SKIP_WTUP=1 (el API ya lo recreo el paso 3) +
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
# shellcheck source=/dev/null
. "$SELF_DIR/lib.sh"     # gs_run_job (helper compartido con up.sh)
load_env

# El slot del worktree pm es parametrizable por WT= (Make lo propaga); el worktree legado por LEGACYWT=. GS_PM_WT/
# GS_LEGACY_WT (env) ganan si se fijan explicitos; si todo vacio, los defaults canonicos gs_pm/gs_legacy_goldenslice.
GS_PM_WT="${GS_PM_WT:-${WT:-gs_pm_goldenslice}}"
GS_LEGACY_WT="${GS_LEGACY_WT:-${LEGACYWT:-gs_legacy_goldenslice}}"
GS_BASE="${GS_BASE:-develop}"
PM_REPO="$WRAPPER_DIR/pl-programa-maestro"
LEGACY_REPO="$WRAPPER_DIR/pl-pm-legacy"
WORKTREES="$WRAPPER_DIR/worktrees"

gs_log(){ printf '== [goldenslice-relaunch] %s\n' "$*"; }
gs_die(){ printf 'ERROR [goldenslice-relaunch]: %s\n' "$*" >&2; exit 1; }

# MODO WORKTREE (req2): WT=/LEGACYWT= usan ESOS worktrees TAL CUAL, sin tocar git. Detectado por las perillas
# CRUDAS; sin ninguna => canonico (origin/<base> desechable). Ambas obligatorias juntas (D2). En modo worktree el
# rebuild del legado se FUERZA (D1: no hay SHA before/after que diffear); LEGACYBUILD=0 lo omite explicitamente.
GS_WT_MODE=0
if [ -n "${WT:-}" ] || [ -n "${LEGACYWT:-}" ]; then
  GS_WT_MODE=1
  [ -n "${WT:-}" ] || gs_die "modo worktree: falta WT=<pm-wt> (LEGACYWT='${LEGACYWT:-}' dado). Uso: make goldenslice-relaunch WT=<pm-wt> LEGACYWT=<legacy-wt>"
  [ -n "${LEGACYWT:-}" ] || gs_die "modo worktree: falta LEGACYWT=<legacy-wt> (WT='${WT:-}' dado). Uso: make goldenslice-relaunch WT=<pm-wt> LEGACYWT=<legacy-wt>"
  gs_log "modo worktree: pm='$GS_PM_WT' legado='$GS_LEGACY_WT' (codigo tal cual, sin fetch/stash/checkout)"
fi

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
# req6.3 (red de seguridad, drift b3): relaunch SIEMPRE resuelve una fila pre-existente => es el escenario primo del
# bug. Si el slot resuelto apunta a un slot sin aprovisionar mientras hay un env vivo en otro => falla ruidoso (no
# relanza contra el fantasma). Con env caido y ningun otro slot vivo NO bloquea (relaunch re-provisiona el API).
gs_guard_slot_provisioned "$SLOT" "$GS_PM_WT"
LN_GS_DB="pm_gs_ln_wt${SLOT}"
PLANNING_DB="pm_planning_wt${SLOT}"
gs_log "slot pre-existente $SLOT -> LN golden=$LN_GS_DB, planning=$PLANNING_DB (reuso sin re-sembrar)"

# 2) worktrees canonicos a origin/<base>. stash+checkout (no reset --hard): preserva cambios locales (D18).
#    Mirror de up.sh:gs_ensure_worktree (misma logica; se copia para no sourcear up.sh, que ejecutaria todo su flujo).
gs_ensure_worktree(){  # <repo> <wt_name>
  local repo="$1" name="$2"          # decls separadas: los libs activan 'set -u' y 'local a=$1 b=$WORKTREES/$a'
  local path="$WORKTREES/$name"      # expande $a ANTES de asignarlo (gotcha de local multi-asignacion)
  [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || gs_die "repo no encontrado: $repo"
  if [ "$GS_WT_MODE" = 1 ]; then
    # Modo worktree (req2/ac1): usa el worktree TAL CUAL, sin tocar git (ni fetch, ni stash, ni checkout). Debe
    # PRE-EXISTIR; el usuario maneja su git (incluido git pull --rebase origin develop) por su cuenta.
    [ -d "$path" ] || gs_die "el worktree '$name' no existe en $path (modo WT=/LEGACYWT=): crealo con 'new-worktree' (o 'git worktree add') y deja tu codigo antes de correr golden"
    gs_log "worktree $name: modo WT= (codigo tal cual; branch $(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?'), sin fetch/stash/checkout)"
    return 0
  fi
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

# I8 (resuelve RISK 8): detecta (y ACTUA sobre) migraciones EF del modulo Catalogs traidas por el pull
# (HEAD_BEFORE->HEAD_AFTER del worktree pm). Antes solo AVISABA; ahora fija GS_CATALOG_MIGRATION=1 para forzar el
# re-warm COMPLETO del bloque 3.5 generalizado, AUNQUE los conteos sondeados sigan > 0: una migracion puede alterar
# el schema/semantica de Catalogs sin vaciar las tablas, y el probe de emptiness (I7) no lo veria (ese es el valor
# unico de I8 frente a I7). El filtro es ESTRECHO a Modules/Catalogs/.../Migrations/*.cs, que excluye a proposito
# los Seed*CatalogFlags de FeatureManagement (siembran flags, no tocan el schema de Catalogs).
gs_detect_catalog_migrations(){  # <pm_path> <head_before> <head_after>
  local path="$1" before="$2" after="$3" changed
  GS_CATALOG_MIGRATION=0
  { [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; } || return 0
  changed="$(git -C "$path" diff --name-only "$before" "$after" 2>/dev/null | grep -Ei 'Modules/Catalogs/.*/Migrations/.*\.cs$' || true)"
  [ -n "$changed" ] || return 0
  GS_CATALOG_MIGRATION=1
  gs_log "I8: el pull a origin/$GS_BASE trae migraciones EF del schema Catalogs -> se FUERZA el re-warm de catalogos (aunque los conteos sigan > 0):"
  printf '  - %s\n' $changed
}

t0=$(date +%s)
PM_PATH="$WORKTREES/$GS_PM_WT"
LEGACY_PATH="$WORKTREES/$GS_LEGACY_WT"
# I8 (reproducibilidad del escenario ac6): honra un PM_HEAD_BEFORE pre-exportado por el operador para simular la
# llegada de una migracion de Catalogs (apuntar a un commit ANTERIOR a una migracion Catalogs de develop, con la
# BD planning ya sembrada y poblada); si no se exporta, se computa el HEAD real previo al checkout.
PM_HEAD_BEFORE="${PM_HEAD_BEFORE:-$(git -C "$PM_PATH" rev-parse HEAD 2>/dev/null || echo '')}"
# I4: SHA del worktree legacy ANTES del checkout (espeja PM_HEAD_BEFORE), para forzar el rebuild/redeploy del legado
# SOLO si su codigo cambia (ver la fase 4).
LEGACY_HEAD_BEFORE="$(git -C "$LEGACY_PATH" rev-parse HEAD 2>/dev/null || echo '')"
gs_ensure_worktree "$PM_REPO" "$GS_PM_WT"
gs_ensure_worktree "$LEGACY_REPO" "$GS_LEGACY_WT"
_gs_timing "worktrees" "$t0"
LEGACY_SRC="$WORKTREES/$GS_LEGACY_WT"
[ -f "$LEGACY_SRC/ProgramaMaestroPT.sln" ] || gs_die "el worktree legacy '$LEGACY_SRC' no trae ProgramaMaestroPT.sln"
PM_HEAD_AFTER="$(git -C "$PM_PATH" rev-parse HEAD 2>/dev/null || echo '')"
LEGACY_HEAD_AFTER="$(git -C "$LEGACY_PATH" rev-parse HEAD 2>/dev/null || echo '')"
GS_CATALOG_MIGRATION=0
gs_detect_catalog_migrations "$PM_PATH" "$PM_HEAD_BEFORE" "$PM_HEAD_AFTER"

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

# 3.5) I7 (resuelve RISK 7): asegura pobladas las tablas de catalogos del login/negocio en la BD planning REUSADA.
#      relaunch reusa esa BD sin recargar (es goldenslice-up MENOS los loaders); si trae VACIAS tablas de catalogos
#      (BD casi fresca, reseteo por migracion, estado parcial), el login del legado rompe ("Acceso denegado"/imagen
#      null) o el negocio queda incompleto. Se GENERALIZA el probe/re-warm de las 2 tablas del login a las 6 de
#      ESTRATEGIA (CatalogTableMap) Y las 11 de CONVERGENCIA (CatalogsConvergenceDescriptors): estrategia vacia =>
#      intake-load; convergencia vacia => catalog-load {"clean":true} (intake-load NO puebla las 8 de convergencia
#      no-estrategia — ese es el punto de la generalizacion). Fast-path: todo poblado => continuar sin recargar. Si
#      tras el re-warm algo sigue vacio, FALLA ruidoso (gs_die): un relaunch NUNCA termina "OK" con catalogos rotos.
#      Backstop de I8: force=1 (migracion de Catalogs detectada) corre AMBOS loaders aunque el probe no este vacio.

# gs_ensure_catalogs <force>: probe estrategia(6)+convergencia(11) -> re-warm DIRIGIDO -> re-probe -> fail-loud.
# <force>=1 corre AMBOS loaders aunque el probe no este vacio (I8). Usa las primitivas compartidas de lib.sh
# (GS_STRATEGY_TABLES/GS_CONVERGENCE_TABLES/gs_list_empty). API_PORT es global (lo lee gs_run_job).
gs_ensure_catalogs(){  # <force>
  local force="${1:-0}" pw empty_s empty_c need_intake=0 need_catalog=0 API_C
  pw="$(wt_shared_sql_password)" || gs_die "no se resolvio el SA del SQL compartido para probar los catalogos"
  wt_shared_sql_check || gs_die "el SQL compartido no esta disponible: no se pueden probar los catalogos"
  empty_s="$(gs_list_empty "$pw" "$PLANNING_DB" $GS_STRATEGY_TABLES)"
  empty_c="$(gs_list_empty "$pw" "$PLANNING_DB" $GS_CONVERGENCE_TABLES)"
  if [ "$force" != 1 ] && [ -z "$empty_s" ] && [ -z "$empty_c" ]; then
    gs_log "catalogos poblados (estrategia 6/6, convergencia 11/11); relanzando sin recargar (fast-path)"
    return 0
  fi
  if [ "$force" = 1 ]; then
    need_catalog=1; need_intake=1
    gs_log "re-warm FORZADO (I8: migracion de Catalogs): catalog-load + intake-load aunque el probe no este vacio ..."
  else
    if [ -n "$empty_c" ]; then need_catalog=1; gs_log "AVISO: convergencia VACIA [$(printf '%s ' $empty_c)]=> catalog-load (clean) ..."; fi
    if [ -n "$empty_s" ]; then need_intake=1; gs_log "AVISO: estrategia VACIA [$(printf '%s ' $empty_s)]=> intake-load ..."; fi
  fi
  # El API recreado en el paso 3 nace con Tools:CatalogLoad/IntakeLoad ON (PM_WT_API_EXTRA_ENV); solo hace falta
  # resolver el puerto para gs_run_job. Sin re-sembrar LN/orders: los loaders solo repueblan el schema Catalogs.
  API_C="pm-wt${SLOT}-api"
  API_PORT="$(wt_api_port "$SLOT")" || gs_die "re-warm: no se resolvio el puerto publicado del API $API_C (revisa que wt-up recreo el pm-api)"
  # Orden espejo de up.sh (5b): convergencia (catalog-load) primero, luego estrategia (intake-load).
  if [ "$need_catalog" = 1 ]; then gs_run_job "/api/v1/tools/catalog-load" '{"clean":true}' "catalog-load (re-warm)" || gs_log "AVISO: catalog-load (re-warm) no completo limpio"; fi
  if [ "$need_intake" = 1 ]; then gs_run_job "/api/v1/tools/intake-load" "" "intake-load (re-warm)" || gs_log "AVISO: intake-load (re-warm) no completo limpio"; fi
  empty_s="$(gs_list_empty "$pw" "$PLANNING_DB" $GS_STRATEGY_TABLES)"
  empty_c="$(gs_list_empty "$pw" "$PLANNING_DB" $GS_CONVERGENCE_TABLES)"
  if [ -z "$empty_s" ] && [ -z "$empty_c" ]; then
    gs_log "re-warm OK: estrategia 6/6 + convergencia 11/11 pobladas"
    return 0
  fi
  gs_die "tras el re-warm siguen VACIAS -> estrategia:[$(printf '%s ' $empty_s)] convergencia:[$(printf '%s ' $empty_c)]. Revisa el Oracle golden del slot $SLOT (pm-wt${SLOT}-oracle-1 / $API_C) o corre 'make goldenslice-up' para re-sembrar. Un relaunch no debe terminar OK con catalogos rotos."
}

gs_log "asegura catalogos (estrategia 6 + convergencia 11) en la BD planning reusada $PLANNING_DB (force=$GS_CATALOG_MIGRATION) ..."
t0=$(date +%s)
gs_ensure_catalogs "$GS_CATALOG_MIGRATION"
_gs_timing "ensure-catalogs" "$t0"

# 4) recompila y redespliega el legado con la ultima develop, reactiva el flag e imprime URLs. e2e-up con:
#    PM_E2E_FORCE        => I4: 1 SOLO si el SHA del worktree legacy cambio (before!=after) o el usuario paso FORCE=1;
#                          0 => se DELEGA el skip por health==200 a legacy.sh (stage_build/deploy): guest sano (health
#                          200) omite el build, guest que no responde 200 compila igual. Asi un relaunch sin cambio de
#                          legado no repaga build+deploy, pero un legado nuevo o un guest caido SI se recompila. El
#                          skip por wiring divergente lo cubre e2e.sh (cmd_up [3b/7] re-deploya forzado) => D7 cubierto;
#    PM_E2E_SKIP_WTUP=1  => el API ya lo recreo el paso 3 (evita una 2a recreacion redundante, colapso I6-3);
#    PM_E2E_SKIP_SMOKE=1 => salta el smoke de paridad (el ambiente queda arriba; smoke aparte 'make e2e-smoke').
#    PM_WT_LN_DB se reexporta por simetria con up.sh (inerte aqui: con SKIP_WTUP e2e-up no recrea el API).
#    El smoke saltado y un rc != 0 no abortan: el objetivo es dejar ambos apps ARRIBA con URLs.
GS_LEGACY_FORCE=0
if [ "${FORCE:-0}" = "1" ]; then
  GS_LEGACY_FORCE=1
  gs_log "FORCE=1 (manual): se fuerza rebuild/redeploy del legado"
elif [ "$GS_WT_MODE" = 1 ]; then
  # D1 (modo worktree): golden no mueve HEAD, no hay SHA before/after que diffear; el usuario cambio codigo por
  # definicion => se FUERZA el rebuild/redeploy del legado SIEMPRE. Escape LEGACYBUILD=0: lo omite (relaunch
  # repetido sin cambios del legado; delega el skip por health==200 a legacy.sh).
  if [ "${LEGACYBUILD:-1}" = "0" ]; then
    GS_LEGACY_FORCE=0
    gs_log "modo worktree + LEGACYBUILD=0: NO se fuerza el legado (delega el skip por health==200 a legacy.sh)"
  else
    GS_LEGACY_FORCE=1
    gs_log "modo worktree: se fuerza rebuild/redeploy del legado (D1; el worktree trae tu codigo). Omite con LEGACYBUILD=0"
  fi
elif [ -n "$LEGACY_HEAD_BEFORE" ] && [ -n "$LEGACY_HEAD_AFTER" ] && [ "$LEGACY_HEAD_BEFORE" != "$LEGACY_HEAD_AFTER" ]; then
  GS_LEGACY_FORCE=1
  gs_log "SHA legacy cambio ($LEGACY_HEAD_BEFORE -> $LEGACY_HEAD_AFTER): se fuerza rebuild/redeploy del legado"
else
  gs_log "SHA legacy sin cambio (${LEGACY_HEAD_AFTER:-<n/d>}): NO se fuerza; legacy.sh omite el build si el guest da health 200, compila si no"
fi
gs_log "e2e-up (legacy rebuild+redeploy FORCE=$GS_LEGACY_FORCE, sin re-recrear API, sin smoke): reactiva flag + URLs ..."
t0=$(date +%s)
PM_WT_LN_DB="$LN_GS_DB" PM_E2E_FORCE=$GS_LEGACY_FORCE PM_E2E_SKIP_WTUP=1 PM_E2E_SKIP_SMOKE=1 \
  make -C "$SIDECAR_DIR" e2e-up WT="$GS_PM_WT" LEGACYSRC="$LEGACY_SRC" \
  || gs_log "AVISO: e2e-up salio con codigo != 0 (revisa arriba); el ambiente puede estar arriba: usa 'make e2e-url WT=$GS_PM_WT'"
_gs_timing "e2e-up" "$t0"

# 5) reimprime el recuadro de acceso (URLs desde M1) y re-levanta el tunel si murio. NO seed, NO catalog/intake-load,
#    NO menu. I9 (resuelve RISK 10): e2e-url puede COLGARSE al re-levantar el tunel SSH (el outlier de 22993 s fue un
#    HANG que '2>/dev/null || true' NO atrapa). Se acota con gs_run_bounded (timeout portable background+watchdog;
#    macOS NO tiene 'timeout'); un cuelgue produce aviso accionable en <= N s y NO cuelga la corrida.
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
if [ "$GS_WT_MODE" = 1 ]; then
  gs_log "goldenslice-relaunch LISTO (slot $SLOT). Ambas apps relanzadas con el codigo de los worktrees ($GS_PM_WT / $GS_LEGACY_WT, tal cual); Oracle/LN golden + BD planning INTACTOS (no re-sembrados)."
else
  gs_log "goldenslice-relaunch LISTO (slot $SLOT). Ambas apps relanzadas con origin/$GS_BASE; Oracle/LN golden + BD planning INTACTOS (no re-sembrados)."
fi
gs_log "Acceso al legado: http://localhost:$(( 18100 + SLOT ))/ProgramaMaestroLN/ . Reimprime URL: make e2e-url WT=$GS_PM_WT"
# req5/ac7: banner final GARANTIZADO (independiente del recuadro de e2e-url, que puede timeoutear y saltarse).
gs_banner "$SLOT" "$GS_PM_WT" "$GS_LEGACY_WT"
