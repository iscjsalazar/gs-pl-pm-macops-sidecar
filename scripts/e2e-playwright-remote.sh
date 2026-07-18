#!/usr/bin/env bash
# Ejecutor remoto, sin decisiones de negocio, para el stage Playwright propio de un slot.
# Secretos: NUL-delimited por stdin; nunca argumentos ni archivos persistentes.
set -euo pipefail
umask 077

MODE="${1:-}"
SUITE_ROOT="${2:-}"
RESULT_ROOT="${3:-}"
NODE_BIN="${4:-}"
PHASE="${5:-$MODE}"
DOCKER_CONTEXT="${6:-}"
DOTNET_IMAGE="${7:-mcr.microsoft.com/dotnet/sdk:10.0}"

die(){ printf 'ERROR [e2e-playwright-remote]: %s\n' "$*" >&2; exit 1; }
valid_uint(){ case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

[ -n "$MODE" ] || die "falta modo"
[ -d "$SUITE_ROOT" ] || die "no existe la suite '$SUITE_ROOT'"
SUITE_ROOT="$(cd "$SUITE_ROOT" && pwd -P)"
mkdir -p "$RESULT_ROOT"
RESULT_ROOT="$(cd "$RESULT_ROOT" && pwd -P)"
case "$RESULT_ROOT" in "$SUITE_ROOT/.results/"*) : ;; *) die "resultados fuera de .results del stage" ;; esac
chmod 700 "$RESULT_ROOT"
case "$NODE_BIN" in '') : ;; '~/'*) NODE_BIN="$HOME/${NODE_BIN#~/}" ;; /*) : ;; *) die "PWNODEBIN debe ser absoluto o comenzar con ~/" ;; esac
PATH="/usr/local/share/dotnet:/usr/local/bin:$HOME/.dotnet:$PATH"
[ -z "$NODE_BIN" ] || PATH="$NODE_BIN:$PATH"
export PATH DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
[ -z "$NODE_BIN" ] || [ -d "$NODE_BIN" ] || die "PWNODEBIN no existe en macdata: '$NODE_BIN'"
DOCKER_CMD=(docker)
[ -z "$DOCKER_CONTEXT" ] || DOCKER_CMD+=(--context "$DOCKER_CONTEXT")
if [ "${PM_E2E_REMOTE_TEST_FORCE_DOCKER:-0}" = 1 ]; then
  [ -x "${PM_E2E_REMOTE_TEST_DOCKER_BIN:-}" ] || die "fixture Docker de contrato ausente"
  DOCKER_CMD=("$PM_E2E_REMOTE_TEST_DOCKER_BIN")
fi
DOTNET_CONTAINER_NAME=''
DOTNET_CONTAINER_CIDFILE=''
DOTNET_CONTAINER_SEQ=0
ACTIVE_CMD_PID=''
ACTIVE_WATCHDOG_PID=''

LOG_FILE="$RESULT_ROOT/$PHASE.log"
exec 3>&1
: > "$LOG_FILE"
flush_log(){
  local rc=$?
  trap - EXIT
  docker_cleanup_container || rc=1
  cat "$LOG_FILE" >&3
  exit "$rc"
}
trap 'flush_log' EXIT
exec > "$LOG_FILE" 2>&1

require_node(){
  command -v node >/dev/null 2>&1 || die "node ausente en macdata"
  command -v npm >/dev/null 2>&1 || die "npm ausente en macdata"
  command -v npx >/dev/null 2>&1 || die "npx ausente en macdata"
  local major; major="$(node -p "process.versions.node.split('.')[0]")"
  valid_uint "$major" && [ "$major" -ge 18 ] || die "Node >=18 requerido"
}

ensure_dotnet_path(){
  command -v dotnet >/dev/null 2>&1 && return 0
  local candidate
  for candidate in /usr/local/share/dotnet/dotnet /usr/local/share/dotnet/x64/dotnet \
    /opt/homebrew/share/dotnet/dotnet /opt/homebrew/share/dotnet/x64/dotnet \
    "$HOME/.dotnet/dotnet" "$HOME/.dotnet/x64/dotnet" "$HOME/dotnet/dotnet"; do
    [ -x "$candidate" ] || continue
    PATH="$(dirname "$candidate"):$PATH"; export PATH
    return 0
  done
  return 1
}

ensure_dotnet_runner(){
  if [ "${PM_E2E_REMOTE_TEST_FORCE_DOCKER:-0}" != 1 ] && ensure_dotnet_path; then DOTNET_RUNNER=native; return 0; fi
  command -v docker >/dev/null 2>&1 || return 1
  "${DOCKER_CMD[@]}" image inspect "$DOTNET_IMAGE" >/dev/null 2>&1 || return 1
  DOTNET_RUNNER=docker
}

process_tree(){
  local pid="$1" child children
  children="$(pgrep -P "$pid" 2>/dev/null || true)"
  for child in $children; do process_tree "$child"; done
  printf '%s\n' "$pid"
}

run_with_watchdog(){
  local timeout_s="$1"; shift
  valid_uint "$timeout_s" && [ "$timeout_s" -gt 0 ] || die "timeout invalido '$timeout_s'"
  local cmd_pid watchdog_pid rc=0 marker tree pid
  marker="$RESULT_ROOT/.timeout-$PHASE-$$"
  "$@" & cmd_pid=$!; ACTIVE_CMD_PID="$cmd_pid"
  (
    sleep "$timeout_s"
    if kill -0 "$cmd_pid" 2>/dev/null; then
      mkdir "$marker" 2>/dev/null || true
      tree="$(process_tree "$cmd_pid")"
      for pid in $tree; do kill -TERM "$pid" 2>/dev/null || true; done
      sleep 5
      for pid in $tree; do kill -KILL "$pid" 2>/dev/null || true; done
    fi
  ) & watchdog_pid=$!; ACTIVE_WATCHDOG_PID="$watchdog_pid"
  wait "$cmd_pid" || rc=$?
  if [ -d "$marker" ]; then
    wait "$watchdog_pid" 2>/dev/null || true
    rmdir "$marker" 2>/dev/null || true
    ACTIVE_CMD_PID=''; ACTIVE_WATCHDOG_PID=''
    return 124
  fi
  tree="$(process_tree "$watchdog_pid")"
  for pid in $tree; do kill -TERM "$pid" 2>/dev/null || true; done
  wait "$watchdog_pid" 2>/dev/null || true
  ACTIVE_CMD_PID=''; ACTIVE_WATCHDOG_PID=''
  return "$rc"
}

docker_cleanup_container(){
  local name="${DOTNET_CONTAINER_NAME:-}" cidfile="${DOTNET_CONTAINER_CIDFILE:-}" rc=0 had_cid=0
  [ -n "$name" ] || return 0
  [ -z "$cidfile" ] || [ ! -s "$cidfile" ] || had_cid=1
  # Ambos comandos son deliberados aun si docker run ya termino: --rm no se usa y el nombre es la identidad
  # recuperable cuando el cliente muere o el watchdog vence.
  "${DOCKER_CMD[@]}" stop --time 5 "$name" >/dev/null 2>&1 || true
  if ! "${DOCKER_CMD[@]}" rm -f "$name" >/dev/null 2>&1; then
    if [ "$had_cid" = 1 ] || "${DOCKER_CMD[@]}" inspect "$name" >/dev/null 2>&1; then rc=1; fi
  fi
  if [ "$rc" = 0 ]; then
    [ -z "$cidfile" ] || [ ! -e "$cidfile" ] || unlink "$cidfile" 2>/dev/null || rc=1
  fi
  if [ "$rc" = 0 ]; then DOTNET_CONTAINER_NAME=''; DOTNET_CONTAINER_CIDFILE=''; fi
  return "$rc"
}

remote_signal(){
  local pid tree
  trap - INT TERM
  for pid in "${ACTIVE_CMD_PID:-}" "${ACTIVE_WATCHDOG_PID:-}"; do
    [ -n "$pid" ] || continue
    tree="$(process_tree "$pid")"
    for pid in $tree; do kill -TERM "$pid" 2>/dev/null || true; done
  done
  docker_cleanup_container || true
  exit 130
}
trap 'remote_signal' INT TERM

run_dotnet(){
  local timeout_s="$1"; shift
  if [ "$DOTNET_RUNNER" = native ]; then run_with_watchdog "$timeout_s" dotnet "$@"; return $?; fi
  local uid gid rc=0 safe_phase; uid="$(id -u)"; gid="$(id -g)"
  local -a docker_run
  safe_phase="$(printf '%s' "$PHASE" | tr -c 'A-Za-z0-9_.-' '-')"
  DOTNET_CONTAINER_SEQ=$((DOTNET_CONTAINER_SEQ + 1))
  DOTNET_CONTAINER_NAME="pm-e2e-${safe_phase}-$$-${DOTNET_CONTAINER_SEQ}"
  DOTNET_CONTAINER_CIDFILE="$RESULT_ROOT/.${DOTNET_CONTAINER_NAME}.cid"
  docker_run=("${DOCKER_CMD[@]}" run --name "$DOTNET_CONTAINER_NAME" --cidfile "$DOTNET_CONTAINER_CIDFILE" --network host --user "$uid:$gid" \
    -e HOME=/tmp -e DOTNET_CLI_HOME=/tmp -e NUGET_PACKAGES=/tmp/.nuget/packages \
    -e DOTNET_CLI_TELEMETRY_OPTOUT=1 -e DOTNET_NOLOGO=1 -e DOTNET_ROLL_FORWARD=Major)
  if [ "${ConnectionStrings__Planning+x}" = x ]; then
    docker_run+=(-e ConnectionStrings__Planning -e ConnectionStrings__CtrlPiso)
  fi
  docker_run+=(-v "$SUITE_ROOT:/work" -w /work "$DOTNET_IMAGE" dotnet)
  run_with_watchdog "$timeout_s" "${docker_run[@]}" "$@" || rc=$?
  docker_cleanup_container || rc=1
  return "$rc"
}

read_data_secrets(){
  IFS= read -r -d '' PM_REMOTE_PLANNING_CS || die "payload SQL incompleto"
  IFS= read -r -d '' PM_REMOTE_CTRLPISO_CS || die "payload Oracle incompleto"
}

read_login_secrets(){
  IFS= read -r -d '' PM_REMOTE_TEST_USER || die "payload usuario incompleto"
  IFS= read -r -d '' PM_REMOTE_TEST_PASSWORD || die "payload password incompleto"
}

cd "$SUITE_ROOT"
case "$MODE" in
  preflight)
    require_node
    ensure_dotnet_runner || die "dotnet nativo ausente y la imagen '$DOTNET_IMAGE' no esta cacheada"
    [ -f package-lock.json ] || die "falta package-lock.json"
    [ -f playwright.config.ts ] || die "falta playwright.config.ts"
    [ ! -f .env ] || die "el stage contiene .env"
    ;;
  prepare)
    require_node
    ensure_dotnet_runner || die "dotnet nativo ausente y la imagen '$DOTNET_IMAGE' no esta cacheada"
    timeout_s="${8:-900}"; install_browser="${9:-0}"; seed_project="${10:-}"
    valid_uint "$timeout_s" && [ "$timeout_s" -gt 0 ] || die "timeout invalido"
    case "$install_browser" in 0|1) : ;; *) die "install debe ser 0|1" ;; esac
    [ -f "$seed_project" ] || die "proyecto seeder inexistente"
    run_with_watchdog "$timeout_s" npm ci
    run_dotnet "$timeout_s" build "$seed_project" --nologo
    [ "$install_browser" = 0 ] || run_with_watchdog "$timeout_s" npx playwright install chromium
    node --input-type=module -e \
      "import {accessSync,constants} from 'node:fs'; import {chromium} from 'playwright'; accessSync(chromium.executablePath(),constants.X_OK)" \
      || die "Chromium ausente; usa PWINSTALL=1"
    ;;
  seed|teardown)
    ensure_dotnet_runner || die "dotnet nativo ausente y la imagen '$DOTNET_IMAGE' no esta cacheada"
    read_data_secrets
    timeout_s="${8:-900}"; scenario="${9:-}"; seed_project="${10:-}"
    [ "$scenario" = tnuc02 ] || die "escenario remoto debe ser tnuc02"
    [ -f "$seed_project" ] || die "proyecto seeder inexistente"
    export ConnectionStrings__Planning="$PM_REMOTE_PLANNING_CS"
    export ConnectionStrings__CtrlPiso="$PM_REMOTE_CTRLPISO_CS"
    args=(--scenario "$scenario")
    [ "$MODE" = seed ] || args+=(--teardown)
    run_dotnet "$timeout_s" run --no-build --project "$seed_project" -- "${args[@]}"
    ;;
  test)
    require_node; read_login_secrets
    state="${8:-}"; state_env="${9:-}"; project="${10:-}"; grep_expr="${11:-}"; spec_rel="${12:-}"
    base_url="${13:-}"; api_url="${14:-}"; plant="${15:-}"; timeout_s="${16:-900}"; retries="${17:-0}"
    case "$state" in off|on) : ;; *) die "estado invalido" ;; esac
    [ "$state_env" = PM_E2E_NUCLEOS_FLAG_STATE ] || die "variable de estado inesperada"
    [ "$project" = plant-res ] || die "project inesperado"
    [ "$grep_expr" = @nucleos-full ] || die "grep inesperado"
    [ "$spec_rel" != "${spec_rel#features/}" ] || die "spec fuera de features/"
    case "$spec_rel" in /*|../*|*/../*|*/..) die "ruta de spec invalida" ;; esac
    case "$spec_rel" in */specs/tnuc02.spec.ts) : ;; *) die "spec debe ser tnuc02.spec.ts" ;; esac
    [ -f "$spec_rel" ] || die "spec exacto inexistente"
    [ "$plant" = RES ] || die "planta inesperada"
    valid_uint "$retries" || die "retries invalido"
    export PM_E2E_PROFILE=macdata PM_E2E_BASE_URL="$base_url" PM_E2E_API_URL="$api_url"
    export PM_E2E_PLANTA="$plant" PM_E2E_TEST_USER="$PM_REMOTE_TEST_USER" PM_E2E_TEST_PASSWORD="$PM_REMOTE_TEST_PASSWORD"
    export "$state_env=$state"
    export PLAYWRIGHT_OUTPUT_DIR="$RESULT_ROOT/$state-test-results"
    export PLAYWRIGHT_HTML_OUTPUT_DIR="$RESULT_ROOT/$state-playwright-report"
    run_with_watchdog "$timeout_s" npx playwright test "$spec_rel" --project "$project" --grep "$grep_expr" --retries "$retries"
    ;;
  *) die "modo desconocido '$MODE'" ;;
esac
