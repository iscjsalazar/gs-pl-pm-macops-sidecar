#!/usr/bin/env bash
# Ejecutor REMOTO (macdata) del smoke golden: Chromium corre en macdata contra el guest directo (WINHOST:site),
# nunca contra el tunel de la M1. Sin decisiones de negocio/infra (eso vive en run-e2e-smoke-golden.sh): stagea
# la suite, corre el runner interno por SSH y descarga SIEMPRE la evidencia a la M1 (verde o rojo). Credenciales
# por STDIN NUL-delimited (req6: nunca en argumentos/logs), re-emitidas tal cual al hop SSH interno.
# uso: printf '%s\0%s\0' "$user" "$password" | run-e2e-smoke-golden-macdata.sh <legacy_src> <result_dir> <base_url> <slot>
set -eo pipefail
umask 077
LEGACY_SRC="$1"; RESULT_DIR="$2"; BASE_URL="$3"; SLOT="$4"
# Instalacion standalone de node en macdata para la suite E2E (una sesion SSH no interactiva no trae
# node/npm/npx en PATH); overridable via PWNODEBIN, mismo criterio que e2e-playwright-remote.sh.
NODE_BIN="${PWNODEBIN:-/Users/diana/pm-e2e-node/node-v20.18.1-darwin-x64/bin}"

die(){ printf 'ERROR [run-e2e-smoke-golden-macdata]: %s\n' "$*" >&2; exit 1; }
IFS= read -r -d '' TEST_USER || die "payload usuario incompleto"
IFS= read -r -d '' TEST_PASSWORD || die "payload password incompleto"
log(){ printf '== [run-e2e-smoke-golden-macdata] %s\n' "$*"; }
REMOTE_SSH="${PM_REMOTE_SSH:-macdata}"
REMOTE_ROOT="pm-e2e-smoke-golden/wt${SLOT}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

log "staging suite -> $REMOTE_SSH:$REMOTE_ROOT ..."
ssh -o ConnectTimeout=20 "$REMOTE_SSH" "mkdir -p '$REMOTE_ROOT/.results'" || die "no se pudo crear el directorio remoto"
rsync -az --delete --include '.env.example' --exclude '.env*' --exclude '.npmrc' --exclude 'credentials*' \
  --exclude '*.pem' --exclude '*.key' \
  --exclude 'node_modules/' --exclude 'test-results*/' --exclude 'playwright-report*/' --exclude '.git/' \
  --exclude '.results/' \
  "$LEGACY_SRC/tests/e2e/" "$REMOTE_SSH:$REMOTE_ROOT/" || die "rsync de la suite fallo"
rsync -az "$SELF_DIR/e2e-smoke-golden-remote-inner.sh" "$REMOTE_SSH:$REMOTE_ROOT/.runner-smoke.sh" || die "rsync del runner interno fallo"

RC=0
printf '%s\0%s\0' "$TEST_USER" "$TEST_PASSWORD" | \
  ssh -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$REMOTE_SSH" \
    "bash '$REMOTE_ROOT/.runner-smoke.sh' '$REMOTE_ROOT' '$BASE_URL' '$NODE_BIN'" \
  || RC=$?

log "descargando evidencia -> $RESULT_DIR (verde o rojo) ..."
mkdir -p "$RESULT_DIR"
rsync -az "$REMOTE_SSH:$REMOTE_ROOT/.results/" "$RESULT_DIR/" || log "AVISO: fallo la descarga de evidencia remota (rc=$RC del smoke se conserva)"

exit "$RC"
