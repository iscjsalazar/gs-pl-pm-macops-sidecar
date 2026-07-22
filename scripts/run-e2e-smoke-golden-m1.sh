#!/usr/bin/env bash
# Ejecutor LOCAL (M1) del smoke golden: Chromium corre en esta Mac contra la URL del tunel/localhost del slot.
# Sin decisiones de negocio ni de infraestructura (eso vive en run-e2e-smoke-golden.sh); solo instala lo que
# falte y corre Playwright. Credenciales por STDIN NUL-delimited (req6: nunca en argumentos/logs).
# uso: printf '%s\0%s\0' "$user" "$password" | run-e2e-smoke-golden-m1.sh <legacy_src> <result_dir> <base_url> <headless>
set -euo pipefail
umask 077
LEGACY_SRC="$1"; RESULT_DIR="$2"; BASE_URL="$3"; HEADLESS="$4"

die(){ printf 'ERROR [run-e2e-smoke-golden-m1]: %s\n' "$*" >&2; exit 1; }
IFS= read -r -d '' TEST_USER || die "payload usuario incompleto"
IFS= read -r -d '' TEST_PASSWORD || die "payload password incompleto"
SUITE="$LEGACY_SRC/tests/e2e"
[ -d "$SUITE" ] || die "no existe $SUITE"
cd "$SUITE"

command -v node >/dev/null 2>&1 || die "node ausente en la M1"
command -v npx >/dev/null 2>&1 || die "npx ausente en la M1"

npm ci
node --input-type=module -e \
  "import {accessSync,constants} from 'node:fs'; import {chromium} from 'playwright'; try { accessSync(chromium.executablePath(), constants.X_OK); process.exit(0);} catch { process.exit(1); }" \
  2>/dev/null || npx playwright install chromium

ARGS=(playwright test --config=playwright.smoke-golden.config.ts)
[ "$HEADLESS" = 1 ] || ARGS+=(--headed)

export PM_E2E_BASE_URL="$BASE_URL"
export PM_E2E_TEST_USER="$TEST_USER"
export PM_E2E_TEST_PASSWORD="$TEST_PASSWORD"
export PM_E2E_PLANTA=RES
export PM_E2E_SEED_DONE=1
export PM_E2E_OUTPUT_DIR="$RESULT_DIR/test-results"
export PM_E2E_HTML_OUTPUT_DIR="$RESULT_DIR/playwright-report"
export PM_E2E_RESULTS_FILE="$RESULT_DIR/results.json"

npx "${ARGS[@]}"
