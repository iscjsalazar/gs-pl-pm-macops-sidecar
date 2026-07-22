#!/usr/bin/env bash
# make run-e2e-smoke-golden (I30, solicitud 260720-1225_feat_all_bajaunidades-lectura-sqlfirst / solicitud-03):
# aprovisiona una golden FRESCA desde los worktrees fuente EXACTOS (WT=<pm-wt> LEGACYWT=<legacy-wt>, vía
# goldenslice-up en modo worktree: sin fetch/checkout/reset/rebase, código tal cual) y ejecuta EXCLUSIVAMENTE
# el smoke golden mutante de BajaUnidades (@golden-smoke), en RUNNER=m1 (headless/visible) o RUNNER=macdata
# (siempre headless). Playwright SOLO modela interacciones/aserciones del navegador; este target hace TODA la
# preparación operativa. No hace e2e-down/wt-down: la golden queda arriba y mutada para inspección (c6).
set -eo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SIDECAR_DIR="${PM_SIDECAR_DIR:-$(cd "$SELF_DIR/.." && pwd)}"
# lib/common.sh resuelve WRAPPER_DIR por MARCADOR (primer ancestro con gs-pl-pm-macops-sidecar/), no por
# profundidad fija: un 'cd ../..' a mano aqui asume mal la profundidad y apunta un nivel arriba de lo debido.
# Sourcear ya fija BASE_DIR/WRAPPER_DIR (top-level de common.sh); load_env() se llama DESPUES (mas abajo), para
# que su validacion de WT/resolve_solution_dir no se adelante a los mensajes propios de este target.
# shellcheck source=/dev/null
. "$SIDECAR_DIR/lib/common.sh"
# shellcheck source=/dev/null
. "$SIDECAR_DIR/lib/worktrees.sh"

log(){ printf '== [run-e2e-smoke-golden] %s\n' "$*"; }
die(){ printf 'ERROR [run-e2e-smoke-golden]: %s\n' "$*" >&2; exit 1; }

# --- req5: matriz completa validada ANTES de llamar load_env()/aprovisionar nada. Mensaje de uso claro para
#     cada falla, propio de este target. ---
[ -n "${WT:-}" ] || die "falta WT=<pm-wt> (uso: make run-e2e-smoke-golden WT=<pm-wt> LEGACYWT=<legacy-wt> [RUNNER=m1|macdata] [HEADLESS=0|1])"
[ -n "${LEGACYWT:-}" ] || die "falta LEGACYWT=<legacy-wt> (uso igual que arriba; ambas obligatorias juntas)"
RUNNER="${RUNNER:-m1}"
HEADLESS="${HEADLESS:-1}"
case "$RUNNER" in
  m1)
    case "$HEADLESS" in 0|1) : ;; *) die "HEADLESS debe ser 0|1 con RUNNER=m1 (recibido '$HEADLESS')" ;; esac
    ;;
  macdata)
    [ "$HEADLESS" = 1 ] || die "RUNNER=macdata solo admite HEADLESS=1 (siempre headless; recibido HEADLESS=$HEADLESS)"
    ;;
  *) die "RUNNER debe ser m1|macdata (recibido '$RUNNER')" ;;
esac
[ -d "$WRAPPER_DIR/worktrees/$WT" ] || die "no existe worktrees/$WT: este target no crea worktrees (crealo con new-worktree/git worktree add antes de invocarlo)"
[ -d "$WRAPPER_DIR/worktrees/$LEGACYWT" ] || die "no existe worktrees/$LEGACYWT"
LEGACY_SRC="$WRAPPER_DIR/worktrees/$LEGACYWT"
[ -f "$LEGACY_SRC/tests/e2e/playwright.smoke-golden.config.ts" ] || die "el worktree legacy '$LEGACYWT' no trae tests/e2e/playwright.smoke-golden.config.ts (I28/I29 sin implementar en ese árbol)"

: "${PM_TARGET:=intel}" ; : "${PM_REMOTE_SSH:=macdata}" ; : "${PM_REMOTE_DOCKER_CONTEXT:=}"
export PM_TARGET PM_REMOTE_SSH PM_REMOTE_DOCKER_CONTEXT
load_env

RUN_ID="smoke-golden-$(date -u +%Y%m%dT%H%M%SZ)-${RUNNER}-$$"
RESULT_DIR="$SIDECAR_DIR/artifacts/playwright-smoke/$RUN_ID"
mkdir -p "$RESULT_DIR"
RC_FILE="$RESULT_DIR/result.rc"
printf 'running\n' > "$RC_FILE"

# El cuerpo completo corre bajo 'tee': el log persistido es exactamente lo que se ve en pantalla (req6).
run_body(){
log "run-id=$RUN_ID runner=$RUNNER headless=$HEADLESS WT=$WT LEGACYWT=$LEGACYWT"
PM_HEAD="$(git -C "$WRAPPER_DIR/worktrees/$WT" rev-parse HEAD 2>/dev/null || echo '?')"
LEGACY_HEAD="$(git -C "$LEGACY_SRC" rev-parse HEAD 2>/dev/null || echo '?')"
log "HEADs: pm=$PM_HEAD legacy=$LEGACY_HEAD"

wt_require_intel || die "requisitos intel (REMOTE=macdata) no satisfechos"

# 1) golden fresca: goldenslice-up en modo worktree (D2 de goldenslice/up.sh: código tal cual, sin tocar git).
# FORCE=1 exportado: sin el, e2e-up/legacy-launch se SALTA el build+deploy del legado si el health-200 ya
# pasa (gotcha documentado: "e2e-up sin FORCE=1 no re-despliega el legado"), dejando corriendo un binario
# viejo del guest aunque el worktree legacy haya cambiado -- viola req4 ("codigo EXACTO de ambos worktrees").
export FORCE=1
log "goldenslice-up WT=$WT LEGACYWT=$LEGACYWT FORCE=1 (compila/despliega/siembra desde el código exacto de ambos worktrees) ..."
make -C "$SIDECAR_DIR" goldenslice-up WT="$WT" LEGACYWT="$LEGACYWT" \
  || die "goldenslice-up fallo (ver arriba); el ambiente puede haber quedado a medio levantar"

SLOT="$(wt_slot_lookup "$WT")"
[ -n "$SLOT" ] || die "no se resolvio el slot de $WT tras goldenslice-up"
API_PORT="$(wt_api_port "$SLOT")" || die "no se resolvio el puerto publicado del API del slot $SLOT"
SITE_PORT=$(( 8100 + SLOT )); TUNNEL_PORT=$(( 18100 + SLOT ))
# IP del guest Windows (VMware NAT); este target no encadena LEGACY_ENV, asi que el default vive aqui igual
# que WINHOST ?= 172.16.128.129 del Makefile (misma convencion que legacy.sh/e2e.sh).
WINHOST="${WINHOST:-172.16.128.129}"
log "slot=$SLOT api_port=$API_PORT site_port=$SITE_PORT tunnel_port=$TUNNEL_PORT"

# 2) health completo antes de tocar el navegador (req4): API 'Healthy' + site legacy HTTP 200 desde la
#    vantage del RUNNER elegido (M1 via tunel; macdata via SSH directo al guest).
make -C "$SIDECAR_DIR" wt-health WT="$WT" || die "wt-health del slot $SLOT no paso (API no 'Healthy')"
if [ "$RUNNER" = m1 ]; then
  BASE_URL="http://localhost:${TUNNEL_PORT}/ProgramaMaestroLN/"
  curl -fsS -o /dev/null --max-time 15 "${BASE_URL}Login.aspx" \
    || die "el tunel M1 (localhost:$TUNNEL_PORT) no respondio HTTP 200 en Login.aspx"
else
  BASE_URL="http://${WINHOST}:${SITE_PORT}/ProgramaMaestroLN/"
  ssh -o ConnectTimeout=10 "$PM_REMOTE_SSH" "curl -fsS -o /dev/null --max-time 15 '${BASE_URL}Login.aspx'" \
    || die "macdata no alcanza el site legacy del slot en ${BASE_URL}Login.aspx"
fi
log "health OK: API slot $SLOT + site legacy ${BASE_URL}Login.aspx (vantage $RUNNER)"

# 2b) calentamiento del endpoint especifico que BajaUnidades consume (BajaGridReadBackendGateway.LeerGrid ->
#     GET api/v1/user-bulk-operations/unit-series). /health/live puede reportar 'Healthy' con las rutas de un
#     modulo recien reiniciado aun sin terminar de registrarse (404 transitorio observado en vivo, I31): se
#     reintenta con parametros benignos hasta que responda 2xx antes de arrancar el navegador.
WARMUP_OK=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ssh -o ConnectTimeout=8 "$PM_REMOTE_SSH" \
    "curl -fsS -o /dev/null --max-time 8 'http://127.0.0.1:${API_PORT}/api/v1/user-bulk-operations/unit-series?plant=RT&item=WARMUP&batch=WARMUP'" \
    >/dev/null 2>&1; then
    WARMUP_OK=1
    break
  fi
  sleep 3
done
[ "$WARMUP_OK" = 1 ] || die "el endpoint api/v1/user-bulk-operations/unit-series del slot $SLOT no respondio 2xx tras 10 reintentos (30s); revisa logs de pm-wt${SLOT}-api"
log "calentamiento OK: api/v1/user-bulk-operations/unit-series responde 2xx"

# 3) cero jobs de preparacion activos: fuerza un intake-load 'clean' (mismo Tools endpoint que goldenslice-up
#    habilita) para arrancar de un backlog fresco incluso si un smoke previo dejo una serie eliminada (c6: cada
#    corrida empieza desde el target completo, nunca contra la golden ya consumida por un run anterior).
log "forzando intake-load (clean) para arrancar de un backlog fresco ..."
# shellcheck source=/dev/null
. "$SIDECAR_DIR/goldenslice/lib.sh"
gs_run_job "/api/v1/tools/intake-load" "" "intake-load-smoke" \
  || log "AVISO: intake-load no completo limpio; el smoke corre sobre el backlog tal cual quedo"

# 4) credenciales (mismo canal que e2e-playwright): env primero, .env del legado como respaldo.
TEST_USER="${PM_E2E_TEST_USER:-}"; TEST_PASSWORD="${PM_E2E_TEST_PASSWORD-}"
CREDS_FILE="$LEGACY_SRC/tests/e2e/.env"
if [ -z "$TEST_USER" ] && [ -f "$CREDS_FILE" ]; then
  TEST_USER="$(sed -nE "s/^PM_E2E_TEST_USER=[\"']?([^\"'\$]*)[\"']?\$/\\1/p" "$CREDS_FILE" | head -1)"
  [ -n "${TEST_PASSWORD:+x}" ] || TEST_PASSWORD="$(sed -nE "s/^PM_E2E_TEST_PASSWORD=[\"']?([^\"'\$]*)[\"']?\$/\\1/p" "$CREDS_FILE" | head -1)"
fi
[ -n "$TEST_USER" ] || die "falta PM_E2E_TEST_USER (env o $CREDS_FILE)"

# 5) ejecuta EXCLUSIVAMENTE el smoke @golden-smoke, en el modo pedido. PM_E2E_SEED_DONE=1: el spec no siembra.
#    Credenciales por STDIN NUL-delimited (req6: nunca en argumentos/logs), como e2e-playwright-remote.sh.
SMOKE_RC=0
if [ "$RUNNER" = m1 ]; then
  printf '%s\0%s\0' "$TEST_USER" "$TEST_PASSWORD" \
    | bash "$SELF_DIR/run-e2e-smoke-golden-m1.sh" "$LEGACY_SRC" "$RESULT_DIR" "$BASE_URL" "$HEADLESS" \
    || SMOKE_RC=$?
else
  printf '%s\0%s\0' "$TEST_USER" "$TEST_PASSWORD" \
    | bash "$SELF_DIR/run-e2e-smoke-golden-macdata.sh" "$LEGACY_SRC" "$RESULT_DIR" "$BASE_URL" "$SLOT" \
    || SMOKE_RC=$?
fi

{
  printf 'run_id=%s\n' "$RUN_ID"
  printf 'runner=%s\n' "$RUNNER"
  printf 'headless=%s\n' "$HEADLESS"
  printf 'slot=%s\n' "$SLOT"
  printf 'base_url=%s\n' "$BASE_URL"
  printf 'pm_head=%s\n' "$PM_HEAD"
  printf 'legacy_head=%s\n' "$LEGACY_HEAD"
  printf 'timestamp_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'exit=%s\n' "$SMOKE_RC"
} > "$RESULT_DIR/summary.txt"

log "smoke EXIT=$SMOKE_RC — evidencia en $RESULT_DIR"
log "golden DEJADA ARRIBA y mutada (sin e2e-down/wt-down): reusar con 'make e2e-url WT=$WT' o repetir el target completo para una golden fresca"
return "$SMOKE_RC"
}

RC=0
run_body 2>&1 | tee "$RESULT_DIR/orchestrator.log" || true   # neutraliza set -e: PIPESTATUS abajo sigue exacto
RC="${PIPESTATUS[0]}"
printf '%s\n' "$RC" > "$RC_FILE"
exit "$RC"
