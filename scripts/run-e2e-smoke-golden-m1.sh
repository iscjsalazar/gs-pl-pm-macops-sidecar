#!/usr/bin/env bash
# Ejecutor LOCAL (M1) del smoke golden: Chromium corre en esta Mac contra la URL del tunel/localhost del slot.
# Sin decisiones de negocio ni de infraestructura (eso vive en run-e2e-smoke-golden.sh); solo instala lo que
# falte y corre Playwright. Credenciales por STDIN NUL-delimited (req6: nunca en argumentos/logs).
# Fail-closed T-002: exige PM_E2E_GOLDEN_READY=1, watchdogs, ambiente fijo, runner.status atomico, un solo npx.
# uso: printf '%s\0%s\0' "$user" "$password" | run-e2e-smoke-golden-m1.sh <legacy_src> <result_dir> <base_url> <headless>
set -euo pipefail
umask 077
LEGACY_SRC="$1"; RESULT_DIR="$2"; BASE_URL="$3"; HEADLESS="$4"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SIDECAR_DIR="$(cd "$SELF_DIR/.." && pwd)"

die(){ printf 'ERROR [run-e2e-smoke-golden-m1]: %s\n' "$*" >&2; exit 1; }
log(){ printf '== [run-e2e-smoke-golden-m1] %s\n' "$*"; }
valid_uint(){ case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# shellcheck source=/dev/null
. "$SIDECAR_DIR/lib/watchdog.sh"
WATCHDOG_RUNNER=m1
ACTIVE_CMD_PID=''; ACTIVE_WATCHDOG_PID=''
RESULT_ROOT="$RESULT_DIR"
mkdir -p "$RESULT_DIR"
export RESULT_ROOT

m1_signal(){
  local pid tree
  trap - INT TERM
  for pid in "${ACTIVE_CMD_PID:-}" "${ACTIVE_WATCHDOG_PID:-}"; do
    [ -n "$pid" ] || continue
    tree="$(process_tree "$pid")"
    for pid in $tree; do kill -TERM "$pid" 2>/dev/null || true; done
  done
  PHASE=signal
  golden_write_runner_status signal 130
  exit 130
}
trap 'm1_signal' INT TERM

golden_write_runner_status(){
  local phase="$1" test_exit="$2" tmp
  tmp="$RESULT_DIR/runner.status.tmp.$$"
  {
    printf 'schema\tpm-e2e-smoke-golden-runner/v1\n'
    printf 'run_id\t%s\n' "${PM_E2E_GOLDEN_RUN_ID:-}"
    printf 'phase\t%s\n' "$phase"
    printf 'test_exit\t%s\n' "$test_exit"
    printf 'handshake_exported\t1\n'
  } > "$tmp"
  mv -f "$tmp" "$RESULT_DIR/runner.status"
}

# Handshake obligatorio (productor = orquestador).
[ "${PM_E2E_GOLDEN_READY:-}" = 1 ] || die "PM_E2E_GOLDEN_READY=1 requerido (ambiente no preparado; no invocar este runner a mano)"

NPM_TO="${PM_E2E_GOLDEN_NPM_TIMEOUT_S:-300}"
CHR_TO="${PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S:-900}"
PW_TO="${PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S:-1800}"
valid_uint "$NPM_TO" && [ "$NPM_TO" -gt 0 ] || die "PM_E2E_GOLDEN_NPM_TIMEOUT_S invalido"
valid_uint "$CHR_TO" && [ "$CHR_TO" -gt 0 ] || die "PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S invalido"
valid_uint "$PW_TO" && [ "$PW_TO" -gt 0 ] || die "PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S invalido"

IFS= read -r -d '' TEST_USER || die "payload usuario incompleto"
IFS= read -r -d '' TEST_PASSWORD || die "payload password incompleto"
SUITE="$LEGACY_SRC/tests/e2e"
[ -d "$SUITE" ] || die "no existe $SUITE"
cd "$SUITE"

command -v node >/dev/null 2>&1 || die "node ausente en la M1"
command -v npx >/dev/null 2>&1 || die "npx ausente en la M1"

# Ambiente fijo del orquestador: sin :- ni herencia accidental de profile/url/outputs.
export PM_E2E_PROFILE=m1
export PM_E2E_BASE_URL="$BASE_URL"
export PM_E2E_TEST_USER="$TEST_USER"
export PM_E2E_TEST_PASSWORD="$TEST_PASSWORD"
export PM_E2E_PLANTA=RES
export PM_E2E_GOLDEN_READY=1
export PM_E2E_SEED_DONE=1
export PM_E2E_OUTPUT_DIR="$RESULT_DIR/test-results"
export PM_E2E_HTML_OUTPUT_DIR="$RESULT_DIR/playwright-report"
export PM_E2E_RESULTS_FILE="$RESULT_DIR/results.json"

PHASE=npm-ci
_t0=$(date +%s)
log "phase=npm-ci timeout_s=$NPM_TO"
rc=0
run_with_watchdog "$NPM_TO" npm ci || rc=$?
if [ "$rc" != 0 ]; then
  log "phase=npm-ci elapsed_s=$(( $(date +%s) - _t0 )) exit=$rc"
  golden_write_runner_status npm-ci -1
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
    golden_write_runner_status chromium -1
    exit "$rc"
  fi
fi
log "phase=chromium elapsed_s=$(( $(date +%s) - _t0 )) exit=0"

PHASE=playwright
_t0=$(date +%s)
# Una sola invocacion: config smoke-golden, tag @golden-smoke, cero retries.
ARGS=(playwright test --config=playwright.smoke-golden.config.ts --grep @golden-smoke --retries=0)
[ "$HEADLESS" = 1 ] || ARGS+=(--headed)
log "phase=playwright timeout_s=$PW_TO"
rc=0
run_with_watchdog "$PW_TO" npx "${ARGS[@]}" || rc=$?
log "phase=playwright elapsed_s=$(( $(date +%s) - _t0 )) exit=$rc"

# test.log local (espejo del remoto) para el manifiesto de evidencia
{
  printf 'runner=m1\n'
  printf 'run_id=%s\n' "${PM_E2E_GOLDEN_RUN_ID:-}"
  printf 'exit=%s\n' "$rc"
} > "$RESULT_DIR/test.log"

golden_write_runner_status playwright "$rc"
exit "$rc"
