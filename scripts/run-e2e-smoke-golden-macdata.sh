#!/usr/bin/env bash
# Ejecutor REMOTO (macdata) del smoke golden: Chromium corre en macdata contra el guest directo (WINHOST:site),
# nunca contra el tunel de la M1. Fail-closed T-002: handshake, watchdogs en rsync/SSH, .results/<RUN_ID>,
# collect siempre tras iniciar remoto, evidencia validada (no solo rsync rc).
# Credenciales por STDIN NUL-delimited (req6), re-emitidas al hop SSH interno.
# uso: printf '%s\0%s\0' "$user" "$password" | run-e2e-smoke-golden-macdata.sh <legacy_src> <result_dir> <base_url> <slot>
set -eo pipefail
umask 077
LEGACY_SRC="$1"; RESULT_DIR="$2"; BASE_URL="$3"; SLOT="$4"
NODE_BIN="${PWNODEBIN:-/Users/diana/pm-e2e-node/node-v20.18.1-darwin-x64/bin}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SIDECAR_DIR="$(cd "$SELF_DIR/.." && pwd)"
RUN_ID="${PM_E2E_GOLDEN_RUN_ID:?falta PM_E2E_GOLDEN_RUN_ID}"
GOLDEN_EVIDENCE_EXIT=74

die(){ printf 'ERROR [run-e2e-smoke-golden-macdata]: %s\n' "$*" >&2; exit 1; }
log(){ printf '== [run-e2e-smoke-golden-macdata] %s\n' "$*"; }
valid_uint(){ case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# shellcheck source=/dev/null
. "$SIDECAR_DIR/lib/watchdog.sh"
WATCHDOG_RUNNER=macdata
ACTIVE_CMD_PID=''; ACTIVE_WATCHDOG_PID=''
RESULT_ROOT="$RESULT_DIR"
mkdir -p "$RESULT_DIR"
export RESULT_ROOT

mac_signal(){
  local pid tree
  trap - INT TERM
  for pid in "${ACTIVE_CMD_PID:-}" "${ACTIVE_WATCHDOG_PID:-}"; do
    [ -n "$pid" ] || continue
    tree="$(process_tree "$pid")"
    for pid in $tree; do kill -TERM "$pid" 2>/dev/null || true; done
  done
  exit 130
}
trap 'mac_signal' INT TERM

[ "${PM_E2E_GOLDEN_READY:-}" = 1 ] || die "PM_E2E_GOLDEN_READY=1 requerido"

NPM_TO="${PM_E2E_GOLDEN_NPM_TIMEOUT_S:-300}"
CHR_TO="${PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S:-900}"
PW_TO="${PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S:-1800}"
RSYNC_TO="${PM_E2E_GOLDEN_RSYNC_TIMEOUT_S:-300}"
SSH_TO="${PM_E2E_GOLDEN_SSH_TIMEOUT_S:-$(( NPM_TO + CHR_TO + PW_TO + 120 ))}"
for _t in "$NPM_TO" "$CHR_TO" "$PW_TO" "$RSYNC_TO" "$SSH_TO"; do
  valid_uint "$_t" && [ "$_t" -gt 0 ] || die "timeout golden invalido '$_t'"
done

IFS= read -r -d '' TEST_USER || die "payload usuario incompleto"
IFS= read -r -d '' TEST_PASSWORD || die "payload password incompleto"
REMOTE_SSH="${PM_REMOTE_SSH:-macdata}"
REMOTE_ROOT="pm-e2e-smoke-golden/wt${SLOT}"
REMOTE_RESULT="$REMOTE_ROOT/.results/$RUN_ID"

# Rechazar comillas/saltos en argumentos publicos antes de construir el comando SSH.
for arg in "$REMOTE_ROOT" "$BASE_URL" "$NODE_BIN" "$RUN_ID" "$NPM_TO" "$CHR_TO" "$PW_TO"; do
  case "$arg" in
    *"'"*|*$'\n'*|*$'\r'*) die "argumento remoto contiene comilla simple o salto de linea; se rechaza antes de SSH" ;;
  esac
done

log "staging suite -> $REMOTE_SSH:$REMOTE_ROOT (results=$REMOTE_RESULT) ..."
stage_fail(){
  local phase="$1" rc="$2" msg="$3"
  log "ERROR: $msg (phase=$phase rc=$rc)"
  exit "$rc"
}
PHASE=ssh-mkdir
rc=0
run_with_watchdog "$RSYNC_TO" ssh -o ConnectTimeout=20 "$REMOTE_SSH" "mkdir -p '$REMOTE_RESULT'" || rc=$?
[ "$rc" = 0 ] || stage_fail "$PHASE" "$rc" "no se pudo crear el directorio remoto"

PHASE=rsync-suite
rc=0
run_with_watchdog "$RSYNC_TO" rsync -az --delete \
  --include '.env.example' --exclude '.env*' --exclude '.npmrc' --exclude 'credentials*' \
  --exclude '*.pem' --exclude '*.key' \
  --exclude 'node_modules/' --exclude 'test-results*/' --exclude 'playwright-report*/' --exclude '.git/' \
  --exclude '.results/' \
  "$LEGACY_SRC/tests/e2e/" "$REMOTE_SSH:$REMOTE_ROOT/" || rc=$?
[ "$rc" = 0 ] || stage_fail "$PHASE" "$rc" "rsync de la suite fallo"

PHASE=rsync-runner
rc=0
run_with_watchdog "$RSYNC_TO" rsync -az \
  "$SELF_DIR/e2e-smoke-golden-remote-inner.sh" \
  "$SIDECAR_DIR/lib/watchdog.sh" \
  "$REMOTE_SSH:$REMOTE_ROOT/" || rc=$?
[ "$rc" = 0 ] || stage_fail "$PHASE" "$rc" "rsync del runner/watchdog fallo"
# Renombrar el runner en remoto a nombre fijo (watchdog.sh conserva nombre).
PHASE=ssh-chmod
rc=0
run_with_watchdog "$RSYNC_TO" ssh -o ConnectTimeout=20 "$REMOTE_SSH" \
  "mv -f '$REMOTE_ROOT/e2e-smoke-golden-remote-inner.sh' '$REMOTE_ROOT/.runner-smoke.sh' && chmod 700 '$REMOTE_ROOT/.runner-smoke.sh' '$REMOTE_ROOT/watchdog.sh'" \
  || rc=$?
[ "$rc" = 0 ] || stage_fail "$PHASE" "$rc" "no se pudo instalar el runner remoto"

REMOTE_STARTED=0
RC=0
PHASE=ssh-playwright
log "invocando runner remoto (timeout_s=$SSH_TO, handshake explicito) ..."
REMOTE_STARTED=1
# Handshake explicito en la asignacion de ambiente SSH (no SendEnv/AcceptEnv).
printf '%s\0%s\0' "$TEST_USER" "$TEST_PASSWORD" | \
  run_with_watchdog "$SSH_TO" \
    ssh -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$REMOTE_SSH" \
      "PM_E2E_GOLDEN_READY=1 PM_E2E_GOLDEN_RUN_ID='$RUN_ID' \
PM_E2E_GOLDEN_NPM_TIMEOUT_S='$NPM_TO' \
PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S='$CHR_TO' \
PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S='$PW_TO' \
bash '$REMOTE_ROOT/.runner-smoke.sh' '$REMOTE_ROOT' '$BASE_URL' '$NODE_BIN' '$RUN_ID'" \
  || RC=$?

# Collect SIEMPRE si el remoto ya inicio (verde o rojo).
EVIDENCE_RC=0
PHASE=rsync-collect
log "descargando evidencia -> $RESULT_DIR (run_id=$RUN_ID, verde o rojo) ..."
mkdir -p "$RESULT_DIR"
run_with_watchdog "$RSYNC_TO" rsync -az "$REMOTE_SSH:$REMOTE_RESULT/" "$RESULT_DIR/" || EVIDENCE_RC=$?
if [ "$EVIDENCE_RC" != 0 ]; then
  log "ERROR: fallo la descarga de evidencia remota (rsync_rc=$EVIDENCE_RC; smoke_rc=$RC)"
fi

# Validar manifiesto (rsync 0 no basta).
evidence_ok=1
for f in runner.status test.log results.json playwright-report/index.html test-results/.last-run.json; do
  if [ ! -f "$RESULT_DIR/$f" ] || [ ! -s "$RESULT_DIR/$f" ]; then
    evidence_ok=0
    log "evidencia incompleta: falta o vacio $f"
  fi
done
if [ "$evidence_ok" = 1 ] && [ -f "$RESULT_DIR/runner.status" ]; then
  # Parseo como datos: run_id debe coincidir
  got_run="$(awk -F'	' '$1=="run_id"{print $2; exit}' "$RESULT_DIR/runner.status" 2>/dev/null || true)"
  [ "$got_run" = "$RUN_ID" ] || { evidence_ok=0; log "evidencia stale: run_id='$got_run' esperado='$RUN_ID'"; }
  # test_exit numerico
  got_test="$(awk -F'	' '$1=="test_exit"{print $2; exit}' "$RESULT_DIR/runner.status" 2>/dev/null || true)"
  case "$got_test" in ''|*[!0-9-]*) evidence_ok=0; log "runner.status test_exit no numerico" ;; esac
fi

if [ "$EVIDENCE_RC" != 0 ]; then
  evidence_ok=0
fi

# Precedencia de salida del hop macdata (el orquestador revalida, pero el rc cruza):
# - watchdog/SSH fatales (124/255/130) ganan siempre: el hop no produjo resultado Playwright confiable
# - evidencia incompleta + test verde => 74
# - test rojo se conserva
# - si no hay runner.status, usar RC del SSH
if [ "$RC" = 124 ] || [ "$RC" = 255 ] || [ "$RC" = 130 ]; then
  log "hop remoto fallo fatal rc=$RC (watchdog/ssh/senal); se conserva aunque el collect haya traido archivos"
  exit "$RC"
fi

if [ -f "$RESULT_DIR/runner.status" ]; then
  TEST_FROM_STATUS="$(awk -F'	' '$1=="test_exit"{print $2; exit}' "$RESULT_DIR/runner.status" 2>/dev/null || echo "$RC")"
else
  TEST_FROM_STATUS="$RC"
fi

if [ "$evidence_ok" != 1 ]; then
  if [ "$TEST_FROM_STATUS" = 0 ] || [ "$TEST_FROM_STATUS" = -1 ]; then
    # Test verde o sin resultado confiable con evidencia rota
    if [ "$TEST_FROM_STATUS" = 0 ]; then
      exit "$GOLDEN_EVIDENCE_EXIT"
    fi
    # Runner fallido: preferir RC del SSH/watchdog
    [ "$RC" != 0 ] && exit "$RC"
    exit "$GOLDEN_EVIDENCE_EXIT"
  fi
  # test rojo + evidencia rota: conservar rc del test
  exit "$TEST_FROM_STATUS"
fi

# Evidencia completa: propagar rc de Playwright (desde status o SSH)
if [ "$TEST_FROM_STATUS" != -1 ]; then
  exit "$TEST_FROM_STATUS"
fi
exit "$RC"
