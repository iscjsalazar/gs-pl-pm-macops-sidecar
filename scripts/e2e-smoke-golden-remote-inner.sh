#!/usr/bin/env bash
# Corre EN macdata (via ssh) por run-e2e-smoke-golden-macdata.sh. Fail-closed T-002: handshake,
# watchdogs, ambiente fijo, un solo npx @golden-smoke --retries=0, runner.status en .results/<RUN_ID>.
# Secretos por stdin NUL-delimited (nunca argumentos ni archivos persistentes).
# uso: .runner-smoke.sh <REMOTE_ROOT> <BASE_URL> <NODE_BIN> <RUN_ID>
set -euo pipefail
umask 077

REMOTE_ROOT="${1:?falta REMOTE_ROOT}"
BASE_URL="${2:?falta BASE_URL}"
NODE_BIN="${3:-}"
RUN_ID="${4:-${PM_E2E_GOLDEN_RUN_ID:-}}"

die(){ printf 'ERROR [e2e-smoke-golden-remote-inner]: %s\n' "$*" >&2; exit 1; }
log(){ printf '== [e2e-smoke-golden-remote-inner] %s\n' "$*"; }
valid_uint(){ case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

[ -n "$RUN_ID" ] || die "falta RUN_ID"
[ "${PM_E2E_GOLDEN_READY:-}" = 1 ] || die "PM_E2E_GOLDEN_READY=1 requerido (handshake del orquestador)"

# Watchdog: stage lo deja en $REMOTE_ROOT/watchdog.sh
if [ -f "$REMOTE_ROOT/watchdog.sh" ]; then
  # shellcheck source=/dev/null
  . "$REMOTE_ROOT/watchdog.sh"
elif [ -f "$(dirname "$0")/watchdog.sh" ]; then
  # shellcheck source=/dev/null
  . "$(dirname "$0")/watchdog.sh"
else
  die "watchdog.sh ausente en el stage remoto"
fi
WATCHDOG_RUNNER=macdata-inner
ACTIVE_CMD_PID=''; ACTIVE_WATCHDOG_PID=''

IFS= read -r -d '' PM_REMOTE_TEST_USER || die "payload usuario incompleto"
IFS= read -r -d '' PM_REMOTE_TEST_PASSWORD || die "payload password incompleto"

[ -z "$NODE_BIN" ] || PATH="$NODE_BIN:$PATH"
export PATH

[ -d "$REMOTE_ROOT" ] || die "no existe $REMOTE_ROOT en macdata (rsync de staging fallo)"
cd "$REMOTE_ROOT"

command -v node >/dev/null 2>&1 || die "node ausente en macdata (¿falta NODE_BIN? probar PWNODEBIN=~/pm-e2e-node/node-v20.18.1-darwin-x64/bin)"
command -v npm >/dev/null 2>&1 || die "npm ausente en macdata"
command -v npx >/dev/null 2>&1 || die "npx ausente en macdata"
major="$(node -p "process.versions.node.split('.')[0]")"
case "$major" in ''|*[!0-9]*) die "version de node no numerica" ;; esac
[ "$major" -ge 18 ] || die "Node >=18 requerido (detectado $major)"

NPM_TO="${PM_E2E_GOLDEN_NPM_TIMEOUT_S:-300}"
CHR_TO="${PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S:-900}"
PW_TO="${PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S:-1800}"
valid_uint "$NPM_TO" && [ "$NPM_TO" -gt 0 ] || die "NPM timeout invalido"
valid_uint "$CHR_TO" && [ "$CHR_TO" -gt 0 ] || die "Chromium timeout invalido"
valid_uint "$PW_TO" && [ "$PW_TO" -gt 0 ] || die "Playwright timeout invalido"

# Aislamiento por corrida: .results/<RUN_ID> (nunca .results compartido).
RESULT_ROOT=".results/$RUN_ID"
mkdir -p "$RESULT_ROOT"
chmod 700 "$RESULT_ROOT"
export RESULT_ROOT

write_runner_status(){
  local phase="$1" test_exit="$2" tmp
  tmp="$RESULT_ROOT/runner.status.tmp.$$"
  {
    printf 'schema\tpm-e2e-smoke-golden-runner/v1\n'
    printf 'run_id\t%s\n' "$RUN_ID"
    printf 'phase\t%s\n' "$phase"
    printf 'test_exit\t%s\n' "$test_exit"
    printf 'handshake_exported\t1\n'
  } > "$tmp"
  mv -f "$tmp" "$RESULT_ROOT/runner.status"
}

inner_signal(){
  local pid tree
  trap - INT TERM
  for pid in "${ACTIVE_CMD_PID:-}" "${ACTIVE_WATCHDOG_PID:-}"; do
    [ -n "$pid" ] || continue
    tree="$(process_tree "$pid")"
    for pid in $tree; do kill -TERM "$pid" 2>/dev/null || true; done
  done
  write_runner_status signal 130
  exit 130
}
trap 'inner_signal' INT TERM

# Ambiente fijo (sin :- ni herencia accidental).
export PM_E2E_PROFILE=macdata
export PM_E2E_BASE_URL="$BASE_URL"
export PM_E2E_TEST_USER="$PM_REMOTE_TEST_USER"
export PM_E2E_TEST_PASSWORD="$PM_REMOTE_TEST_PASSWORD"
export PM_E2E_PLANTA=RES
export PM_E2E_GOLDEN_READY=1
export PM_E2E_SEED_DONE=1
export PM_E2E_OUTPUT_DIR="$RESULT_ROOT/test-results"
export PM_E2E_HTML_OUTPUT_DIR="$RESULT_ROOT/playwright-report"
export PM_E2E_RESULTS_FILE="$RESULT_ROOT/results.json"

PHASE=npm-ci
_t0=$(date +%s)
log "phase=npm-ci timeout_s=$NPM_TO"
rc=0
run_with_watchdog "$NPM_TO" npm ci || rc=$?
if [ "$rc" != 0 ]; then
  log "phase=npm-ci elapsed_s=$(( $(date +%s) - _t0 )) exit=$rc"
  write_runner_status npm-ci -1
  exit "$rc"
fi
log "phase=npm-ci elapsed_s=$(( $(date +%s) - _t0 )) exit=0"

PHASE=chromium
_t0=$(date +%s)
need_chromium=0
node --input-type=module -e \
  "import {accessSync,constants} from 'node:fs'; import {chromium} from 'playwright'; try { accessSync(chromium.executablePath(), constants.X_OK); process.exit(0);} catch { process.exit(1); }" \
  2>/dev/null || need_chromium=1
if [ "$need_chromium" = 1 ]; then
  log "phase=chromium-install timeout_s=$CHR_TO"
  rc=0
  run_with_watchdog "$CHR_TO" npx playwright install chromium || rc=$?
  if [ "$rc" != 0 ]; then
    log "phase=chromium-install elapsed_s=$(( $(date +%s) - _t0 )) exit=$rc"
    write_runner_status chromium -1
    exit "$rc"
  fi
fi
log "phase=chromium elapsed_s=$(( $(date +%s) - _t0 )) exit=0"

PHASE=playwright
_t0=$(date +%s)
log "phase=playwright timeout_s=$PW_TO"
rc=0
# Una sola invocacion: config smoke-golden, tag @golden-smoke, cero retries.
# macdata es siempre headless (el orquestador no pasa flag headed).
run_with_watchdog "$PW_TO" npx playwright test \
  --config=playwright.smoke-golden.config.ts \
  --grep @golden-smoke \
  --retries=0 \
  > "$RESULT_ROOT/test.log" 2>&1 || rc=$?
log "phase=playwright elapsed_s=$(( $(date +%s) - _t0 )) exit=$rc"
cat "$RESULT_ROOT/test.log"
write_runner_status playwright "$rc"
exit "$rc"
