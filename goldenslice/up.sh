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
load_env

GS_PM_WT="${GS_PM_WT:-gs_pm_goldenslice}"
GS_LEGACY_WT="${GS_LEGACY_WT:-gs_legacy_goldenslice}"
GS_BASE="${GS_BASE:-develop}"
PM_REPO="$WRAPPER_DIR/pl-programa-maestro"
LEGACY_REPO="$WRAPPER_DIR/pl-pm-legacy"
WORKTREES="$WRAPPER_DIR/worktrees"

gs_log(){ printf '== [goldenslice-up] %s\n' "$*"; }
gs_die(){ printf 'ERROR [goldenslice-up]: %s\n' "$*" >&2; exit 1; }

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
gs_ensure_worktree "$PM_REPO" "$GS_PM_WT"
gs_ensure_worktree "$LEGACY_REPO" "$GS_LEGACY_WT"
LEGACY_SRC="$WORKTREES/$GS_LEGACY_WT"
[ -f "$LEGACY_SRC/ProgramaMaestroPT.sln" ] || gs_die "el worktree legacy '$LEGACY_SRC' no trae ProgramaMaestroPT.sln"

# 2) provisiona el slot (backend + Oracle propio). El slot se auto-asigna; se deriva del registro.
gs_log "wt-up (slot + Oracle) para $GS_PM_WT ..."
make -C "$SIDECAR_DIR" wt-up WT="$GS_PM_WT" ORACLE=1 || gs_die "wt-up fallo"
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
python3 "$SELF_DIR/generate.py" --src "$GS_SRC" --out "$SELF_DIR/build" >/dev/null || gs_die "generate.py fallo"

# 3) siembra la golden slice (Oracle multi-owner + recompila + LN aislada). Idempotente.
gs_log "goldenslice-seed SLOT=$SLOT (Oracle golden + LN aislada) ..."
make -C "$SIDECAR_DIR" goldenslice-seed SLOT="$SLOT" || gs_die "goldenslice-seed fallo"

# 4) e2e-up apuntando el pm-api a la LN GOLDEN (PM_WT_LN_DB exportado; WT_ENV no lo pisa). e2e-up recrea el API
#    con la connstring golden, levanta el frontend, activa el flag e imprime las URLs. El smoke puede fallar sin
#    abortar goldenslice-up: el objetivo es dejar el ambiente ARRIBA con URLs para validar en vivo.
gs_log "e2e-up con LN golden ($LN_GS_DB) y SQL VACIO: recrea API + frontend + flag ..."
PM_WT_LN_DB="$LN_GS_DB" make -C "$SIDECAR_DIR" e2e-up WT="$GS_PM_WT" LEGACYSRC="$LEGACY_SRC" \
  || gs_log "AVISO: e2e-up salio con codigo != 0 (revisa el smoke arriba); el ambiente puede estar arriba: usa 'make e2e-url WT=$GS_PM_WT'"

# --- 5) poblar los CATALOGOS/insumos del golden en el SQL VACIO (sin pantalla), como un deploy limpio. El intake
#        REAL (produce el plan) queda MANUAL desde la app (OrdenesNuevasCargar_LN.aspx). ---
ctx="$(remote_docker_ctx)"
API_C="pm-wt${SLOT}-api"; ORA_C="pm-wt${SLOT}-oracle-1"; PLANNING_DB="pm_planning_wt${SLOT}"; OH="$PM_WT_ORACLE_HOME"
API_PORT="$(on_intel "docker $ctx port '$API_C' 8080/tcp 2>/dev/null" 2>/dev/null | head -1 | sed 's/.*://' | tr -d '\r')"
[ -n "$API_PORT" ] || gs_die "no se resolvio el puerto publicado del API $API_C"

# 5a) habilitar los tools dev de carga (recrea el API preservando env/redes + Tools:CatalogLoad/IntakeLoad ON).
gs_log "habilitando tools de carga en el API del slot (catalog-load + intake-load) ..."
ssh "$PM_REMOTE_SSH" "mkdir -p ~/goldenslice-bin" >/dev/null
rsync -az "$SELF_DIR/enable-tools.sh" "$PM_REMOTE_SSH:~/goldenslice-bin/enable-tools.sh" >/dev/null
ssh "$PM_REMOTE_SSH" "zsh -lc 'bash ~/goldenslice-bin/enable-tools.sh $API_C $PLANNING_DB'" || gs_die "fallo habilitar los tools de carga"

# helper: POST a un tool-job y poll a Completed (async 202 + jobId; GET /api/v1/jobs/{id})
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

# 5b) catalog-load Clean (11 catalogos Catalogs.* desde el golden Oracle) + intake-load Clean (insumo: 3 de
#     convergencia + 6 de estrategia). SQL vacio => es carga inicial limpia, no reemplaza handcrafted.
gs_log "catalog-load (clean) desde el golden Oracle ..."
gs_run_job "/api/v1/tools/catalog-load" '{"clean":true}' "catalog-load" || gs_log "AVISO: catalog-load no completo limpio"
gs_log "intake-load (clean) desde el golden Oracle ..."
gs_run_job "/api/v1/tools/intake-load" "" "intake-load" || gs_log "AVISO: intake-load no completo limpio"

# 6) registrar el menu UBO (Administracion -> Operaciones Masivas + 7 paginas) en el golden Oracle. El .sql es
#    idempotente (NOT EXISTS) y NO commitea: se agrega COMMIT. El menu (Site.Master -> WCF -> pge_ctrlpiso.MENU)
#    lo sirve Oracle, no el SQL.
gs_log "registrando el menu UBO (Operaciones Masivas) en el golden Oracle ..."
ssh "$PM_REMOTE_SSH" "mkdir -p ~/goldenslice-bin" >/dev/null
rsync -az "$SELF_DIR/insert-menu-operaciones-masivas.sql" "$PM_REMOTE_SSH:~/goldenslice-bin/menu-ubo.sql" >/dev/null
on_intel "docker $ctx cp \$HOME/goldenslice-bin/menu-ubo.sql '$ORA_C:/tmp/menu-ubo.sql'"
printf '@/tmp/menu-ubo.sql\nCOMMIT;\n' | on_intel "docker $ctx exec -i -e ORACLE_HOME='$OH' '$ORA_C' bash -c 'export PATH=\$ORACLE_HOME/bin:\$PATH; sqlplus -S system/oracle@localhost:1521/XE'" 2>/dev/null | tr -d '\r' | tail -12

# 7) reimprime el recuadro de acceso (URLs desde M1). El intake es MANUAL desde la app.
make -C "$SIDECAR_DIR" e2e-url WT="$GS_PM_WT" 2>/dev/null || true
gs_log "goldenslice-up LISTO (slot $SLOT). SQL golden VACIO + catalogos/insumos cargados desde el golden Oracle; menu UBO registrado."
gs_log "El intake RES se dispara MANUAL desde la app: http://localhost:$(( 18100 + SLOT ))/ProgramaMaestroLN/ (OrdenesNuevasCargar_LN). Reimprime URL: make e2e-url WT=$GS_PM_WT"
