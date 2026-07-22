#!/usr/bin/env bash
# Corre EN macdata (via ssh) por run-e2e-smoke-golden-macdata.sh. Sin decisiones de negocio: instala lo que
# falte y ejecuta el smoke @golden-smoke contra el guest directo. Secretos por stdin NUL-delimited (nunca
# argumentos ni archivos persistentes), como e2e-playwright-remote.sh.
set -euo pipefail
umask 077

REMOTE_ROOT="${1:?falta REMOTE_ROOT}"
BASE_URL="${2:?falta BASE_URL}"
NODE_BIN="${3:-}"

die(){ printf 'ERROR [e2e-smoke-golden-remote-inner]: %s\n' "$*" >&2; exit 1; }

IFS= read -r -d '' PM_REMOTE_TEST_USER || die "payload usuario incompleto"
IFS= read -r -d '' PM_REMOTE_TEST_PASSWORD || die "payload password incompleto"

# Una sesion SSH no interactiva no trae node/npm/npx en PATH (mismo gotcha que docker en on_intel): node vive
# en una instalacion standalone dedicada a la suite E2E, igual que PWNODEBIN de e2e-playwright-remote.sh.
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

npm ci
node --input-type=module -e \
  "import {accessSync,constants} from 'node:fs'; import {chromium} from 'playwright'; try { accessSync(chromium.executablePath(), constants.X_OK); process.exit(0);} catch { process.exit(1); }" \
  2>/dev/null || npx playwright install chromium

# Relativo a la cwd (ya dentro de $REMOTE_ROOT por el 'cd' de arriba): prefijarlo con $REMOTE_ROOT de nuevo
# duplicaba la ruta (wt1/pm-e2e-smoke-golden/wt1/.results) y dejaba el rsync de vuelta apuntando a un
# directorio vacio (bug observado en vivo, I31 RUNNER=macdata: solo orchestrator.log/summary.txt llegaban a la M1).
RESULT_ROOT=".results"
mkdir -p "$RESULT_ROOT"; chmod 700 "$RESULT_ROOT"

export PM_E2E_PROFILE=macdata
export PM_E2E_BASE_URL="$BASE_URL"
export PM_E2E_TEST_USER="$PM_REMOTE_TEST_USER"
export PM_E2E_TEST_PASSWORD="$PM_REMOTE_TEST_PASSWORD"
export PM_E2E_PLANTA=RES
export PM_E2E_SEED_DONE=1
export PM_E2E_OUTPUT_DIR="$RESULT_ROOT/test-results"
export PM_E2E_HTML_OUTPUT_DIR="$RESULT_ROOT/playwright-report"
export PM_E2E_RESULTS_FILE="$RESULT_ROOT/results.json"

rc=0
npx playwright test --config=playwright.smoke-golden.config.ts > "$RESULT_ROOT/test.log" 2>&1 || rc=$?
cat "$RESULT_ROOT/test.log"
exit "$rc"
