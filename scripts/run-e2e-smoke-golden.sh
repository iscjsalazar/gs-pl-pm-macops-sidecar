#!/usr/bin/env bash
# make run-e2e-smoke-golden (I30 + T-002 fail-closed):
# aprovisiona una golden FRESCA desde los worktrees fuente EXACTOS (WT=<pm-wt> LEGACYWT=<legacy-wt>, vía
# goldenslice-up en modo worktree: sin fetch/checkout/reset/rebase, código tal cual) y ejecuta EXCLUSIVAMENTE
# el smoke golden mutante de BajaUnidades (@golden-smoke), en RUNNER=m1 (headless/visible) o RUNNER=macdata
# (siempre headless). Playwright SOLO modela interacciones/aserciones del navegador; este target hace TODA la
# preparación operativa. No hace e2e-down/wt-down: la golden queda arriba y mutada para inspección (c6).
#
# Maquina de estados fail-closed (T-002):
#   unset handshake -> validar -> goldenslice-up -> health+warmup -> golden_restore (fatal) ->
#   export PM_E2E_GOLDEN_READY=1 -> dispatch m1|macdata -> collect+validate evidence -> veredicto atomico
set -eo pipefail
# BASH_SOURCE para que el source-only de contratos resuelva el sidecar aunque $0 sea "_" .
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
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
valid_uint(){ case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Codigo de I/O de evidencia incompleta (distinto de un rojo funcional de Playwright).
GOLDEN_EVIDENCE_EXIT=74

# --- handshake: eliminar cualquier valor stale heredado antes de validar o ejecutar ---
unset PM_E2E_GOLDEN_READY || true

# --- modo contrato: define funciones y sale sin tocar infra (PM_E2E_GOLDEN_CONTRACT_SOURCE_ONLY=1 + source) ---
if [ "${PM_E2E_GOLDEN_CONTRACT_SOURCE_ONLY:-0}" = 1 ] && [ "${BASH_SOURCE[0]}" != "$0" ]; then
  GOLDEN_CONTRACT_SOURCE_ONLY=1
else
  GOLDEN_CONTRACT_SOURCE_ONLY=0
fi

golden_validate_matrix(){
  # req5: matriz completa validada ANTES de load_env()/aprovisionar nada.
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

  PM_E2E_GOLDEN_NPM_TIMEOUT_S="${PM_E2E_GOLDEN_NPM_TIMEOUT_S:-300}"
  PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S="${PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S:-900}"
  PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S="${PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S:-1800}"
  PM_E2E_GOLDEN_RSYNC_TIMEOUT_S="${PM_E2E_GOLDEN_RSYNC_TIMEOUT_S:-300}"
  local _t_name _t_val
  for _t_name in PM_E2E_GOLDEN_NPM_TIMEOUT_S PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S \
    PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S PM_E2E_GOLDEN_RSYNC_TIMEOUT_S; do
    eval "_t_val=\$${_t_name}"
    valid_uint "$_t_val" && [ "$_t_val" -gt 0 ] || die "$_t_name debe ser entero positivo (recibido '$_t_val')"
  done
  PM_E2E_GOLDEN_SSH_TIMEOUT_S=$(( PM_E2E_GOLDEN_NPM_TIMEOUT_S + PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S + PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S + 120 ))
  export PM_E2E_GOLDEN_NPM_TIMEOUT_S PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S \
    PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S PM_E2E_GOLDEN_RSYNC_TIMEOUT_S PM_E2E_GOLDEN_SSH_TIMEOUT_S

  [ -d "$WRAPPER_DIR/worktrees/$WT" ] || die "no existe worktrees/$WT: este target no crea worktrees (crealo con new-worktree/git worktree add antes de invocarlo)"
  [ -d "$WRAPPER_DIR/worktrees/$LEGACYWT" ] || die "no existe worktrees/$LEGACYWT"
  LEGACY_SRC="$WRAPPER_DIR/worktrees/$LEGACYWT"
  [ -f "$LEGACY_SRC/tests/e2e/playwright.smoke-golden.config.ts" ] || die "el worktree legacy '$LEGACYWT' no trae tests/e2e/playwright.smoke-golden.config.ts (I28/I29 sin implementar en ese árbol)"
}

# Estado de fases del reductor (inicializado antes de cualquier fase).
PREPARE_EXIT=-1
TEST_EXIT=-1
EVIDENCE_EXIT=-1
EVIDENCE_COMPLETE=0
HANDSHAKE_EXPORTED=0
# Rc real de la fase de runner (hop M1/macdata): se propaga a final_exit en RUNNER_FAILED.
RUNNER_EXIT=-1
FINAL_STATUS=PREPARATION_FAILED
FINAL_PHASE=init
FINAL_EXIT=1
REMOTE_STARTED=0

golden_write_atomic(){
  # Escribe $1 desde contenido en stdin via temporal + mv (nunca sourceable en caliente).
  local dest="$1" tmp
  tmp="${dest}.tmp.$$"
  cat > "$tmp" || { unlink "$tmp" 2>/dev/null || true; return 1; }
  mv -f "$tmp" "$dest"
}

golden_parse_runner_status(){
  # Parsea runner.status como DATOS (nunca source). Falla cerrado ante claves duplicadas o rc no numerico.
  # Expone: RS_SCHEMA RS_RUN_ID RS_PHASE RS_TEST_EXIT RS_HANDSHAKE
  local file="$1" line key val t
  RS_SCHEMA=''; RS_RUN_ID=''; RS_PHASE=''; RS_TEST_EXIT=''; RS_HANDSHAKE=''
  local seen_schema=0 seen_run=0 seen_phase=0 seen_test=0 seen_hs=0
  [ -f "$file" ] || return 1
  [ -s "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
      *$'\t'*) : ;;
      *) return 1 ;;
    esac
    key="${line%%	*}"
    val="${line#*	}"
    case "$key" in
      schema)
        [ "$seen_schema" = 0 ] || return 1
        seen_schema=1; RS_SCHEMA="$val"
        ;;
      run_id)
        [ "$seen_run" = 0 ] || return 1
        seen_run=1; RS_RUN_ID="$val"
        ;;
      phase)
        [ "$seen_phase" = 0 ] || return 1
        seen_phase=1; RS_PHASE="$val"
        ;;
      test_exit)
        [ "$seen_test" = 0 ] || return 1
        seen_test=1
        # Enteros con signo estrictos (7, -1, 0); rechazo vacio / - / 1-2 / NOTNUM.
        t="${val#-}"; case "$t" in ''|*[!0-9]*) return 1 ;; esac
        RS_TEST_EXIT="$val"
        ;;
      handshake_exported|handshake)
        [ "$seen_hs" = 0 ] || return 1
        seen_hs=1; RS_HANDSHAKE="$val"
        ;;
      *) : ;; # claves adicionales se ignoran (forward-compat)
    esac
  done < "$file"
  [ -n "$RS_SCHEMA" ] && [ -n "$RS_RUN_ID" ] && [ -n "$RS_TEST_EXIT" ] || return 1
  return 0
}

golden_validate_evidence(){
  # Tras npx playwright, evidencia completa exige archivos regulares no vacios del run_id vigente.
  local dir="$1" expected_run="$2"
  EVIDENCE_COMPLETE=0
  [ -d "$dir" ] || return 1
  local f
  for f in runner.status test.log results.json playwright-report/index.html test-results/.last-run.json; do
    [ -f "$dir/$f" ] || return 1
    [ -s "$dir/$f" ] || return 1
  done
  if ! golden_parse_runner_status "$dir/runner.status"; then
    return 1
  fi
  [ "$RS_RUN_ID" = "$expected_run" ] || return 1
  [ "$RS_SCHEMA" = "pm-e2e-smoke-golden-runner/v1" ] || return 1
  EVIDENCE_COMPLETE=1
  return 0
}

golden_classify_after_dispatch(){
  # Mapea SMOKE_RC + evidencia local → TEST_EXIT / EVIDENCE_* / RUNNER_EXIT (ambos carriles).
  # Falla de fase de runner (test_exit=-1 en runner.status, o 124/130/255 sin resultado PW
  # confiable) fija TEST_EXIT=-1 y conserva el rc de la fase en RUNNER_EXIT.
  # Requiere: SMOKE_RC, RESULT_DIR, RUN_ID, GOLDEN_EVIDENCE_EXIT.
  RUNNER_EXIT="$SMOKE_RC"
  local parsed=0
  RS_TEST_EXIT=''
  if [ -f "$RESULT_DIR/runner.status" ] && golden_parse_runner_status "$RESULT_DIR/runner.status"; then
    parsed=1
  fi
  if golden_validate_evidence "$RESULT_DIR" "$RUN_ID"; then
    EVIDENCE_EXIT=0
    if [ "$parsed" = 1 ] && [ -n "${RS_TEST_EXIT:-}" ]; then
      TEST_EXIT="$RS_TEST_EXIT"
    else
      TEST_EXIT="$SMOKE_RC"
    fi
    if [ "$TEST_EXIT" = -1 ]; then
      if [ "$SMOKE_RC" != 0 ]; then
        RUNNER_EXIT="$SMOKE_RC"
      else
        RUNNER_EXIT=1
      fi
    fi
    return 0
  fi
  EVIDENCE_EXIT="$GOLDEN_EVIDENCE_EXIT"
  EVIDENCE_COMPLETE=0
  # Pre-resultado Playwright confiable: test_exit=-1 del leaf, o rc fatal de hop/watchdog/senal.
  if [ "$parsed" = 1 ] && [ "$RS_TEST_EXIT" = -1 ]; then
    TEST_EXIT=-1
    if [ "$SMOKE_RC" != 0 ]; then
      RUNNER_EXIT="$SMOKE_RC"
    else
      RUNNER_EXIT=1
    fi
    return 0
  fi
  case "$SMOKE_RC" in
    124|130|255)
      TEST_EXIT=-1
      RUNNER_EXIT="$SMOKE_RC"
      return 0
      ;;
  esac
  if [ "$parsed" = 1 ] && [ -n "${RS_TEST_EXIT:-}" ]; then
    TEST_EXIT="$RS_TEST_EXIT"
  elif [ "$SMOKE_RC" = "$GOLDEN_EVIDENCE_EXIT" ]; then
    # Wrapper macdata: evidencia incompleta con test verde (o sin status) sale 74.
    TEST_EXIT=0
  else
    TEST_EXIT="$SMOKE_RC"
  fi
  return 0
}

golden_reduce_status(){
  # Precedencia cerrada del veredicto maquina-legible (analisis.md §4).
  # Entrada: PREPARE_EXIT TEST_EXIT EVIDENCE_EXIT EVIDENCE_COMPLETE RUNNER_EXIT HANDSHAKE_EXPORTED
  if [ "$PREPARE_EXIT" != -1 ] && [ "$PREPARE_EXIT" != 0 ]; then
    FINAL_STATUS=PREPARATION_FAILED
    FINAL_EXIT="$PREPARE_EXIT"
    return 0
  fi
  if [ "$TEST_EXIT" = -1 ]; then
    # Runner no produjo resultado Playwright confiable → rc de la fase (124/130/255/…), no 74.
    FINAL_STATUS=RUNNER_FAILED
    if [ "${RUNNER_EXIT:--1}" != -1 ] && [ "${RUNNER_EXIT}" != 0 ]; then
      FINAL_EXIT="$RUNNER_EXIT"
    else
      FINAL_EXIT=1
    fi
    return 0
  fi
  # Playwright termino (0 u otro).
  if [ "$TEST_EXIT" = 0 ] && [ "$EVIDENCE_COMPLETE" = 1 ]; then
    FINAL_STATUS=PASS
    FINAL_EXIT=0
    return 0
  fi
  if [ "$TEST_EXIT" = 0 ] && [ "$EVIDENCE_COMPLETE" != 1 ]; then
    FINAL_STATUS=EVIDENCE_FAILED
    FINAL_EXIT="$GOLDEN_EVIDENCE_EXIT"
    return 0
  fi
  # test != 0
  if [ "$EVIDENCE_COMPLETE" = 1 ]; then
    FINAL_STATUS=TEST_FAILED
    FINAL_EXIT="$TEST_EXIT"
    return 0
  fi
  FINAL_STATUS=TEST_AND_EVIDENCE_FAILED
  FINAL_EXIT="$TEST_EXIT"
  return 0
}

golden_persist_verdict(){
  local dir="$1"
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  golden_reduce_status
  golden_write_atomic "$dir/result.status" <<EOF
schema	pm-e2e-smoke-golden/v1
run_id	${RUN_ID:-}
runner	${RUNNER:-}
status	$FINAL_STATUS
phase	$FINAL_PHASE
prepare_exit	$PREPARE_EXIT
test_exit	$TEST_EXIT
evidence_exit	$EVIDENCE_EXIT
evidence_complete	$EVIDENCE_COMPLETE
handshake_exported	$HANDSHAKE_EXPORTED
final_exit	$FINAL_EXIT
EOF
  {
    printf 'run_id=%s\n' "${RUN_ID:-}"
    printf 'runner=%s\n' "${RUNNER:-}"
    printf 'headless=%s\n' "${HEADLESS:-}"
    printf 'slot=%s\n' "${SLOT:-}"
    printf 'base_url=%s\n' "${BASE_URL:-}"
    printf 'pm_head=%s\n' "${PM_HEAD:-}"
    printf 'legacy_head=%s\n' "${LEGACY_HEAD:-}"
    printf 'timestamp_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'status=%s\n' "$FINAL_STATUS"
    printf 'phase=%s\n' "$FINAL_PHASE"
    printf 'prepare_exit=%s\n' "$PREPARE_EXIT"
    printf 'test_exit=%s\n' "$TEST_EXIT"
    printf 'evidence_exit=%s\n' "$EVIDENCE_EXIT"
    printf 'evidence_complete=%s\n' "$EVIDENCE_COMPLETE"
    printf 'handshake_exported=%s\n' "$HANDSHAKE_EXPORTED"
    printf 'exit=%s\n' "$FINAL_EXIT"
  } | golden_write_atomic "$dir/summary.txt"
  printf '%s\n' "$FINAL_EXIT" | golden_write_atomic "$dir/result.rc"
}

golden_phase_log(){
  local phase="$1" started elapsed exit_code timeout_s
  started="$2"; exit_code="$3"; timeout_s="${4:-}"
  elapsed=$(( $(date +%s) - started ))
  if [ -n "$timeout_s" ]; then
    log "phase=$phase started_utc=$(date -u -r "$started" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ) elapsed_s=$elapsed timeout_s=$timeout_s exit=$exit_code"
  else
    log "phase=$phase elapsed_s=$elapsed exit=$exit_code"
  fi
}

# En modo contrato solo se exportan las funciones anteriores (y se salta el cuerpo vivo).
if [ "$GOLDEN_CONTRACT_SOURCE_ONLY" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

golden_validate_matrix

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
log "timeouts: npm=${PM_E2E_GOLDEN_NPM_TIMEOUT_S}s chromium=${PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S}s playwright=${PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S}s rsync=${PM_E2E_GOLDEN_RSYNC_TIMEOUT_S}s ssh=${PM_E2E_GOLDEN_SSH_TIMEOUT_S}s"
PM_HEAD="$(git -C "$WRAPPER_DIR/worktrees/$WT" rev-parse HEAD 2>/dev/null || echo '?')"
LEGACY_HEAD="$(git -C "$LEGACY_SRC" rev-parse HEAD 2>/dev/null || echo '?')"
log "HEADs: pm=$PM_HEAD legacy=$LEGACY_HEAD"

wt_require_intel || die "requisitos intel (REMOTE=macdata) no satisfechos"

# 1) golden fresca
FINAL_PHASE=goldenslice-up
_t0=$(date +%s)
export FORCE=1
log "goldenslice-up WT=$WT LEGACYWT=$LEGACYWT FORCE=1 (compila/despliega/siembra desde el código exacto de ambos worktrees) ..."
if ! make -C "$SIDECAR_DIR" goldenslice-up WT="$WT" LEGACYWT="$LEGACYWT"; then
  PREPARE_EXIT=1
  FINAL_PHASE=goldenslice-up
  golden_phase_log goldenslice-up "$_t0" 1
  golden_persist_verdict "$RESULT_DIR"
  die "goldenslice-up fallo (ver arriba); el ambiente puede haber quedado a medio levantar"
fi
golden_phase_log goldenslice-up "$_t0" 0

SLOT="$(wt_slot_lookup "$WT")"
[ -n "$SLOT" ] || { PREPARE_EXIT=1; FINAL_PHASE=slot-lookup; golden_persist_verdict "$RESULT_DIR"; die "no se resolvio el slot de $WT tras goldenslice-up"; }
API_PORT="$(wt_api_port "$SLOT")" || { PREPARE_EXIT=1; FINAL_PHASE=api-port; golden_persist_verdict "$RESULT_DIR"; die "no se resolvio el puerto publicado del API del slot $SLOT"; }
SITE_PORT=$(( 8100 + SLOT )); TUNNEL_PORT=$(( 18100 + SLOT ))
WINHOST="${WINHOST:-172.16.128.129}"
log "slot=$SLOT api_port=$API_PORT site_port=$SITE_PORT tunnel_port=$TUNNEL_PORT"

# 2) health
FINAL_PHASE=health
_t0=$(date +%s)
make -C "$SIDECAR_DIR" wt-health WT="$WT" || { PREPARE_EXIT=1; golden_phase_log health "$_t0" 1; golden_persist_verdict "$RESULT_DIR"; die "wt-health del slot $SLOT no paso (API no 'Healthy')"; }
if [ "$RUNNER" = m1 ]; then
  BASE_URL="http://localhost:${TUNNEL_PORT}/ProgramaMaestroLN/"
  curl -fsS -o /dev/null --max-time 15 "${BASE_URL}Login.aspx" \
    || { PREPARE_EXIT=1; golden_persist_verdict "$RESULT_DIR"; die "el tunel M1 (localhost:$TUNNEL_PORT) no respondio HTTP 200 en Login.aspx"; }
else
  BASE_URL="http://${WINHOST}:${SITE_PORT}/ProgramaMaestroLN/"
  ssh -o ConnectTimeout=10 "$PM_REMOTE_SSH" "curl -fsS -o /dev/null --max-time 15 '${BASE_URL}Login.aspx'" \
    || { PREPARE_EXIT=1; golden_persist_verdict "$RESULT_DIR"; die "macdata no alcanza el site legacy del slot en ${BASE_URL}Login.aspx"; }
fi
golden_phase_log health "$_t0" 0
log "health OK: API slot $SLOT + site legacy ${BASE_URL}Login.aspx (vantage $RUNNER)"

# 2b) calentamiento
FINAL_PHASE=warmup
_t0=$(date +%s)
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
[ "$WARMUP_OK" = 1 ] || { PREPARE_EXIT=1; golden_phase_log warmup "$_t0" 1; golden_persist_verdict "$RESULT_DIR"; die "el endpoint api/v1/user-bulk-operations/unit-series del slot $SLOT no respondio 2xx tras 10 reintentos (30s); revisa logs de pm-wt${SLOT}-api"; }
golden_phase_log warmup "$_t0" 0
log "calentamiento OK: api/v1/user-bulk-operations/unit-series responde 2xx"

# 3) restore/intake: FATAL si no llega a Completed (fail-closed T-002 MUST 1)
FINAL_PHASE=golden_restore
_t0=$(date +%s)
log "forzando intake-load (clean) para arrancar de un backlog fresco ..."
# shellcheck source=/dev/null
. "$SIDECAR_DIR/goldenslice/lib.sh"
RESTORE_RC=0
gs_run_job "/api/v1/tools/intake-load" "" "intake-load-smoke" || RESTORE_RC=$?
if [ "$RESTORE_RC" != 0 ]; then
  PREPARE_EXIT="$RESTORE_RC"
  FINAL_PHASE=golden_restore
  golden_phase_log golden_restore "$_t0" "$RESTORE_RC"
  golden_persist_verdict "$RESULT_DIR"
  die "intake-load (golden_restore) fallo con rc=$RESTORE_RC; no se abre el navegador ni se exporta handshake"
fi
PREPARE_EXIT=0
golden_phase_log golden_restore "$_t0" 0

# 4) handshake SOLO tras Completed
export PM_E2E_GOLDEN_READY=1
HANDSHAKE_EXPORTED=1
log "handshake exportado: PM_E2E_GOLDEN_READY=1"

# 5) credenciales
TEST_USER="${PM_E2E_TEST_USER:-}"; TEST_PASSWORD="${PM_E2E_TEST_PASSWORD-}"
CREDS_FILE="$LEGACY_SRC/tests/e2e/.env"
if [ -z "$TEST_USER" ] && [ -f "$CREDS_FILE" ]; then
  TEST_USER="$(sed -nE "s/^PM_E2E_TEST_USER=[\"']?([^\"'\$]*)[\"']?\$/\\1/p" "$CREDS_FILE" | head -1)"
  [ -n "${TEST_PASSWORD:+x}" ] || TEST_PASSWORD="$(sed -nE "s/^PM_E2E_TEST_PASSWORD=[\"']?([^\"'\$]*)[\"']?\$/\\1/p" "$CREDS_FILE" | head -1)"
fi
[ -n "$TEST_USER" ] || { PREPARE_EXIT=1; FINAL_PHASE=credentials; golden_persist_verdict "$RESULT_DIR"; die "falta PM_E2E_TEST_USER (env o $CREDS_FILE)"; }

# 6) dispatch
FINAL_PHASE=dispatch
REMOTE_STARTED=1
SMOKE_RC=0
if [ "$RUNNER" = m1 ]; then
  printf '%s\0%s\0' "$TEST_USER" "$TEST_PASSWORD" \
    | env PM_E2E_GOLDEN_READY=1 \
      PM_E2E_GOLDEN_NPM_TIMEOUT_S="$PM_E2E_GOLDEN_NPM_TIMEOUT_S" \
      PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S="$PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S" \
      PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S="$PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S" \
      PM_E2E_GOLDEN_RUN_ID="$RUN_ID" \
      bash "$SELF_DIR/run-e2e-smoke-golden-m1.sh" "$LEGACY_SRC" "$RESULT_DIR" "$BASE_URL" "$HEADLESS" \
    || SMOKE_RC=$?
else
  printf '%s\0%s\0' "$TEST_USER" "$TEST_PASSWORD" \
    | env PM_E2E_GOLDEN_READY=1 \
      PM_E2E_GOLDEN_NPM_TIMEOUT_S="$PM_E2E_GOLDEN_NPM_TIMEOUT_S" \
      PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S="$PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S" \
      PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S="$PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S" \
      PM_E2E_GOLDEN_RSYNC_TIMEOUT_S="$PM_E2E_GOLDEN_RSYNC_TIMEOUT_S" \
      PM_E2E_GOLDEN_SSH_TIMEOUT_S="$PM_E2E_GOLDEN_SSH_TIMEOUT_S" \
      PM_E2E_GOLDEN_RUN_ID="$RUN_ID" \
      bash "$SELF_DIR/run-e2e-smoke-golden-macdata.sh" "$LEGACY_SRC" "$RESULT_DIR" "$BASE_URL" "$SLOT" \
    || SMOKE_RC=$?
fi
# Clasificacion comun M1|macdata: TEST_EXIT=-1 + RUNNER_EXIT=rc de fase en fallas pre-Playwright.
golden_classify_after_dispatch

FINAL_PHASE=verdict
golden_persist_verdict "$RESULT_DIR"
log "smoke status=$FINAL_STATUS EXIT=$FINAL_EXIT — evidencia en $RESULT_DIR"
log "golden DEJADA ARRIBA y mutada (sin e2e-down/wt-down): reusar con 'make e2e-url WT=$WT' o repetir el target completo para una golden fresca"
return "$FINAL_EXIT"
}

RC=0
run_body 2>&1 | tee "$RESULT_DIR/orchestrator.log" || true   # neutraliza set -e: PIPESTATUS abajo sigue exacto
RC="${PIPESTATUS[0]}"
# Asegurar veredicto persistido aun si run_body corto antes
if [ ! -f "$RESULT_DIR/result.status" ]; then
  FINAL_EXIT="$RC"
  [ "$RC" = 0 ] || FINAL_STATUS=RUNNER_FAILED
  golden_persist_verdict "$RESULT_DIR" || true
fi
# result.rc es fuente de final_exit ya escrita; re-leer si existe
if [ -f "$RESULT_DIR/result.rc" ]; then
  RC="$(tr -d '[:space:]' < "$RESULT_DIR/result.rc")"
fi
printf '%s\n' "$RC" > "$RC_FILE"
exit "$RC"
