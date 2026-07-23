#!/usr/bin/env bash
# Contrato sin red/slot del runner Playwright y de la seleccion atribuible de solucion.
# Compatible con Bash 3.2.
if [ "$(basename "$0")" = docker ]; then
  log="${DOCKER_SIM_LOG:?}"
  cmd="${1:-}"; shift || true
  case "$cmd" in
    image) exit 0 ;;
    run)
      name=''; cidfile=''
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --name) name="$2"; shift 2 ;;
          --cidfile) cidfile="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      printf 'RUN|%s|%s\n' "$name" "$cidfile" >> "$log"
      [ -z "$cidfile" ] || printf '0123456789abcdef\n' > "$cidfile"
      case "${DOCKER_SIM_BEHAVIOR:-success}" in
        success) exit 0 ;;
        failure) exit 7 ;;
        timeout) sleep 30; exit 0 ;;
        int) kill -INT "$PPID"; sleep 30; exit 0 ;;
        term) kill -TERM "$PPID"; sleep 30; exit 0 ;;
      esac
      ;;
    stop)
      [ "${1:-}" != --time ] || shift 2
      printf 'STOP|%s\n' "${1:-}" >> "$log"; exit 0
      ;;
    rm)
      [ "${1:-}" != -f ] || shift
      printf 'RM|%s\n' "${1:-}" >> "$log"; exit 0
      ;;
    inspect) exit 1 ;;
  esac
  exit 2
fi
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WRAPPER="$(cd "$ROOT/../.." && pwd -P)"
COMMON="$ROOT/lib/common.sh"
E2E="$ROOT/scripts/e2e.sh"
REMOTE="$ROOT/scripts/e2e-playwright-remote.sh"
MAKEFILE="$ROOT/Makefile"
README="$ROOT/README.md"
pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }
contains() {
  local file="$1" literal="$2" label="$3"
  if grep -Fq -- "$literal" "$file" 2>/dev/null; then ok "$label"; else bad "$label (falta: $literal)"; fi
}
not_contains() {
  local file="$1" literal="$2" label="$3"
  if grep -Fq -- "$literal" "$file" 2>/dev/null; then bad "$label (presente: $literal)"; else ok "$label"; fi
}
matrix_case() {
  PM_E2E_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
    . "$1"
    mode="$2"; events=""; off_count=0
    event(){ if [ -n "$events" ]; then events="$events,$1"; else events="$1"; fi; }
    e2e_playwright_bind_slot(){ return 0; }
    e2e_playwright_stage(){ return 0; }
    e2e_playwright_prepare_front(){ return 0; }
    wt_registry_lock(){ return 0; }
    e2e_playwright_collect(){ event collect; return 0; }
    e2e_playwright_set_flag(){
      event "flag:$1"
      if [ "$1" = off ]; then
        off_count=$((off_count + 1))
        [ "$mode" = restore-fail ] && [ "$off_count" -gt 1 ] && return 1
      fi
      return 0
    }
    e2e_playwright_remote(){
      remote_mode="$1"; phase="$2"
      case "$remote_mode" in
        seed) event seed; [ "$mode" = seed-fail ] && return 1 ;;
        test) event "test:$phase"; [ "$mode" = off-fail ] && [ "$phase" = off ] && return 1 ;;
        teardown) event teardown; [ "$mode" = teardown-fail ] && return 1 ;;
      esac
      return 0
    }
    WT=fixture; PLANTA=RES; PW_FLAG_FINAL=off; PW_TIMEOUT=10; PW_SCENARIO=tnuc02
    PW_SEED_PROJECT=seed.csproj; PW_STATE_ENV=PM_E2E_NUCLEOS_FLAG_STATE
    PW_PROJECT=plant-res; PW_GREP=@nucleos-full; PW_SPEC_REL=features/nucleos/specs/tnuc02.spec.ts
    PW_BASE_URL=http://legacy/; PW_API_URL=http://api/
    _cmd_playwright_locked; rc=$?
    printf "%s|%s" "$rc" "$events"
  ' _ "$E2E" "$1"
}
docker_sim_case() {
  local behavior="$1" fixture fake suite result log output rc name stop_name rm_name cid_count
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/pm-i13-docker.XXXXXX")"
  fake="$fixture/docker"; suite="$fixture/suite"; result="$suite/.results/run"; log="$fixture/docker.log"; output="$fixture/output.log"
  mkdir -p "$suite" "$result"; touch "$suite/seed.csproj" "$log"
  ln -s "$ROOT/tests/e2e-playwright-contract.sh" "$fake"
  printf 'planning\0oracle\0' | PM_E2E_REMOTE_TEST_FORCE_DOCKER=1 PM_E2E_REMOTE_TEST_DOCKER_BIN="$fake" \
    DOCKER_SIM_LOG="$log" DOCKER_SIM_BEHAVIOR="$behavior" /bin/bash "$REMOTE" seed "$suite" "$result" '' seed '' image 1 tnuc02 seed.csproj > "$output" 2>&1
  rc=$?
  name="$(awk -F'|' '$1=="RUN"{print $2; exit}' "$log")"
  stop_name="$(awk -F'|' '$1=="STOP"{print $2; exit}' "$log")"
  rm_name="$(awk -F'|' '$1=="RM"{print $2; exit}' "$log")"
  cid_count="$(find "$result" -name '*.cid' -type f -print 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s|%s|%s|%s|%s' "$rc" "$name" "$stop_name" "$rm_name" "$cid_count"
  unlink "$fake" "$suite/seed.csproj" "$log" "$output" "$result/seed.log" 2>/dev/null || true
  rmdir "$result" "$suite/.results" "$suite" "$fixture" 2>/dev/null || true
}
cleanup_child_case() {
  PM_E2E_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
    . "$1"
    test_mode="$2"; events=""; WT=lease-sin-arbol; KEEP_FRONT=0; BRIDGE_DOWN=0
    unset PM_ALLOW_MISSING_WT_LEASE PM_SOLUTION_DIR PM_CONTAINERS_DIR
    event(){ if [ -n "$events" ]; then events="$events,$1"; else events="$1"; fi; }
    elog(){ :; }; ewarn(){ :; }
    wt_slot_lookup(){ [ "$1" = lease-sin-arbol ] && printf 4; }
    wt_derive(){ E2E_SLOT="$1"; WT_SITE_PORT=8104; WT_TUNNEL_PORT=18104; WT_SITE_NAME=pm-wt4; }
    e2e_bridge_down(){ event bridge; return 0; }
    make(){
      local arg target=""
      for arg in "$@"; do case "$arg" in legacy-down|legacy-site-down|wt-down) target="$arg" ;; esac; done
      case "$target" in
        legacy-down) event tunnel; return 0 ;;
        legacy-site-down) event site; return 0 ;;
        wt-down)
          resolve_solution_dir >/dev/null 2>&1; child_rc=$?
          event "child:allow${PM_ALLOW_MISSING_WT_LEASE:-0}:resolve$child_rc"
          [ "$child_rc" -eq 0 ] || return "$child_rc"
          event api; event oracle; event db; event lease
          [ "$test_mode" != child-fail ] || return 7
          return 0
          ;;
      esac
      return 99
    }
    cmd_down; rc=$?
    printf "%s|%s" "$rc" "$events"
  ' _ "$E2E" "$1"
}
resolve() {
  PM_WRAPPER_DIR="$WRAPPER" WT="${1:-}" PM_SOLUTION_DIR="${2:-}" /bin/bash -c \
    '. "$1"; resolve_solution_dir; printf "%s" "$PM_SOLUTION_DIR"' _ "$COMMON" 2>/dev/null
}
resolve_in() {
  local wrapper="$1" wt="$2" solution="${3:-}"
  PM_WRAPPER_DIR="$wrapper" WT="$wt" PM_SOLUTION_DIR="$solution" /bin/bash -c \
    '. "$1"; resolve_solution_dir; printf "%s" "$PM_SOLUTION_DIR"' _ "$COMMON" 2>/dev/null
}

pm_abs=""
for candidate in "$WRAPPER"/worktrees/*; do
  if [ -f "$candidate/PL.PM.sln" ]; then pm_abs="$(cd "$candidate" && pwd -P)"; break; fi
done
if [ -z "$pm_abs" ]; then
  bad "fixture: no existe un worktree PM con PL.PM.sln"
else
  pm_name="$(basename "$pm_abs")"
  got="$(resolve "$pm_name")"
  [ "$got" = "$pm_abs" ] && ok "WT relativo resuelve su worktree" || bad "WT relativo resolvio '$got'"
  got="$(resolve "$pm_abs")"
  [ "$got" = "$pm_abs" ] && ok "WT absoluto resuelve el mismo worktree" || bad "WT absoluto resolvio '$got'"
  got="$(resolve "$pm_abs" "$pm_abs")"
  [ "$got" = "$pm_abs" ] && ok "WT+SOLUTION coherentes se aceptan" || bad "WT+SOLUTION coherentes resolvieron '$got'"
fi

central="$(cd "$WRAPPER/pl-programa-maestro" && pwd -P)"
got="$(resolve "")"
[ "$got" = "$central" ] && ok "standalone sin WT conserva checkout central" || bad "standalone resolvio '$got'"

outside="$(mktemp -d "${TMPDIR:-/tmp}/pm-i13-outside.XXXXXX")"
touch "$outside/PL.PM.sln"
if resolve "$outside" >/dev/null; then bad "WT exterior falla cerrado"; else ok "WT exterior falla cerrado"; fi
if resolve "$WRAPPER/worktrees/no-existe-i13" >/dev/null; then bad "WT inexistente falla cerrado"; else ok "WT inexistente falla cerrado"; fi
if [ -n "$pm_abs" ] && resolve "$pm_abs" "$central" >/dev/null; then
  bad "WT+SOLUTION divergentes fallan cerrado"
else
  ok "WT+SOLUTION divergentes fallan cerrado"
fi
rmdir "$outside" 2>/dev/null || true

# DL-149: el input debe ser seguro tanto lexical como fisicamente; resolver al arbol correcto no basta.
path_fixture="$(mktemp -d "${TMPDIR:-/tmp}/pm-i13-paths.XXXXXX")"
path_fixture="$(cd "$path_fixture" && pwd -P)"
mkdir -p "$path_fixture/gs-pl-pm-macops-sidecar" "$path_fixture/pl-programa-maestro" "$path_fixture/worktrees/real"
touch "$path_fixture/pl-programa-maestro/PL.PM.sln" "$path_fixture/worktrees/real/PL.PM.sln"
outside_link="${path_fixture}-outside-link"
ln -s "$path_fixture/worktrees/real" "$outside_link"
ln -s "$path_fixture/worktrees/real" "$path_fixture/worktrees/inside-link"
if resolve_in "$path_fixture" "$path_fixture/worktrees/real/../real" >/dev/null; then bad "WT con componente .. falla cerrado"; else ok "WT con componente .. falla cerrado"; fi
if resolve_in "$path_fixture" "$outside_link" >/dev/null; then bad "symlink exterior hacia dentro falla cerrado"; else ok "symlink exterior hacia dentro falla cerrado"; fi
if resolve_in "$path_fixture" "$path_fixture/worktrees/inside-link" >/dev/null; then bad "symlink interior falla cerrado"; else ok "symlink interior falla cerrado"; fi
unlink "$outside_link"; unlink "$path_fixture/worktrees/inside-link"
unlink "$path_fixture/pl-programa-maestro/PL.PM.sln"; unlink "$path_fixture/worktrees/real/PL.PM.sln"
rmdir "$path_fixture/worktrees/real" "$path_fixture/worktrees" "$path_fixture/pl-programa-maestro" "$path_fixture/gs-pl-pm-macops-sidecar" "$path_fixture"

contains "$MAKEFILE" 'e2e-playwright:' "target publico e2e-playwright"
contains "$MAKEFILE" 'PWSCENARIO  ?= tnuc02' "default focal tnuc02"
contains "$MAKEFILE" 'PWGREP      ?= @nucleos-full' "tag focal exacto"
contains "$MAKEFILE" 'PWPROJECT   ?= plant-res' "proyecto focal exacto"
contains "$MAKEFILE" 'PWFLAGKEY   ?= subordinate-nucleos-backend' "flag focal exacto"
contains "$MAKEFILE" 'PWSTATEENV  ?= PM_E2E_NUCLEOS_FLAG_STATE' "variable de estado exacta"

contains "$E2E" 'e2e_playwright_validate_inputs' "validacion local previa del runner"
contains "$E2E" 'PW_SCENARIO="${PM_E2E_PW_SCENARIO:-tnuc02}"' "runner conserva tnuc02"
contains "$E2E" 'PW_GREP="${PM_E2E_PW_GREP:-@nucleos-full}"' "runner conserva tag exacto"
contains "$E2E" 'PW_PROJECT="${PM_E2E_PW_PROJECT:-plant-res}"' "runner conserva proyecto exacto"
contains "$E2E" 'PW_FLAG_KEY="${PM_E2E_PW_FLAG_KEY:-subordinate-nucleos-backend}"' "runner conserva flag exacto"
contains "$E2E" 'PW_STATE_ENV="${PM_E2E_PW_STATE_ENV:-PM_E2E_NUCLEOS_FLAG_STATE}"' "runner conserva variable exacta"
contains "$E2E" 'for state in off on' "orden de sub-runs OFF y ON"
contains "$E2E" 'sub-run $state fallo' "un sub-run fallido se acumula"
contains "$E2E" 'e2e_playwright_cleanup || cleanup_rc=$?' "cleanup fallido conserva rojo"
contains "$E2E" 'fallo la restauracion del flag' "restauracion fallida conserva rojo"
contains "$E2E" 'no se ejecuta navegador y se entra a cleanup' "seed fallido entra a cleanup"
contains "$E2E" 'scenarios.manifest.json' "manifest se valida antes del slot"
contains "$E2E" 'spec.ts' "spec exacto se valida antes del slot"
contains "$E2E" 'PWRETRIES debe ser entero >=0' "retries falla cerrado"
contains "$E2E" 'PWTIMEOUT debe ser entero positivo' "timeout falla cerrado"
contains "$E2E" 'PWPROJECT' "proyecto se valida"
contains "$E2E" 'PLANTA invalida' "planta se valida"

contains "$REMOTE" 'run_with_watchdog' "runner remoto limita comandos largos"
contains "$REMOTE" 'npx playwright test "$spec_rel"' "runner remoto ejecuta spec exacto"
contains "$REMOTE" '--retries "$retries"' "runner remoto aplica retries explicitos"
cloud_cli_token='a''z '
cloud_turn_token='deploy''-turn'
not_contains "$REMOTE" "$cloud_cli_token" "runner sin Azure CLI"
not_contains "$E2E" "$cloud_turn_token" "runner no toca deploy Prolec dev"
contains "$README" 'legacy-launch' "README conserva frontera de deploy local"
contains "$README" 'Prolec dev' "README distingue Prolec dev"

quote_rejection="$(PM_E2E_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
  . "$1"
  ssh_called=0; ssh(){ ssh_called=1; }
  PW_REMOTE_ROOT="stage/root"; PW_REMOTE_RESULT="stage/root/.results/run"; PW_NODE_BIN="/tmp/node'"'"'bin"
  PM_REMOTE_DOCKER_CONTEXT="ctx'"'"'quoted"; PW_DOTNET_IMAGE="image'"'"'quoted"; PM_REMOTE_SSH=fixture
  e2e_playwright_remote preflight "phase'"'"'quoted" >/dev/null 2>&1; rc=$?
  printf "%s|%s" "$rc" "$ssh_called"
' _ "$E2E")"
[ "$quote_rejection" = '2|0' ] && ok "comilla simple en PWNODEBIN se rechaza antes de SSH" || bad "PWNODEBIN con comilla alcanzo SSH: $quote_rejection"

lease_cleanup="$(PM_E2E_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
  . "$1"
  WT=lease-sin-arbol
  wt_slot_lookup(){ [ "$1" = lease-sin-arbol ] && printf 3; }
  wt_derive(){ E2E_SLOT="$1"; WT_SITE_PORT=8103; WT_TUNNEL_PORT=18103; }
  e2e_slot_try; printf "%s|%s" "$?" "${E2E_SLOT:-}"
' _ "$E2E" 2>/dev/null)"
[ "$lease_cleanup" = '0|3' ] && ok "lease literal permite cleanup sin arbol" || bad "cleanup sin arbol no resolvio lease: $lease_cleanup"

cleanup_flow="$(cleanup_child_case success)"
[ "$cleanup_flow" = '0|tunnel,site,child:allow1:resolve0,api,oracle,db,lease,bridge' ] \
  && ok "cmd_down propaga excepcion al hijo y completa teardown integral" \
  || bad "flujo cmd_down->wt-down incompleto: $cleanup_flow"
cleanup_failure="$(cleanup_child_case child-fail)"
[ "$cleanup_failure" = '7|tunnel,site,child:allow1:resolve0,api,oracle,db,lease,bridge' ] \
  && ok "fallo de wt-down conserva rojo tras cleanup integral" \
  || bad "cmd_down oculto fallo hijo: $cleanup_failure"

contains "$REMOTE" '--name "$DOTNET_CONTAINER_NAME"' "fallback Docker tiene identidad explicita"
contains "$REMOTE" 'docker_cleanup_container' "fallback Docker centraliza cleanup"
contains "$REMOTE" 'stop' "fallback Docker detiene contenedor"
contains "$REMOTE" 'rm -f' "fallback Docker retira contenedor"

for docker_case in success failure timeout int term; do
  docker_result="$(docker_sim_case "$docker_case")"
  docker_rc="${docker_result%%|*}"; docker_rest="${docker_result#*|}"
  docker_name="${docker_rest%%|*}"; docker_rest="${docker_rest#*|}"
  docker_stop="${docker_rest%%|*}"; docker_rest="${docker_rest#*|}"
  docker_rm="${docker_rest%%|*}"; docker_cids="${docker_rest##*|}"
  case "$docker_case" in success) expected_rc=0 ;; failure) expected_rc=7 ;; timeout) expected_rc=124 ;; int|term) expected_rc=130 ;; esac
  if [ "$docker_rc" = "$expected_rc" ] && [ -n "$docker_name" ] && [ "$docker_stop" = "$docker_name" ] && \
    [ "$docker_rm" = "$docker_name" ] && [ "$docker_cids" = 0 ]; then
    ok "fallback Docker cleanup $docker_case (rc=$docker_rc)"
  else
    bad "fallback Docker $docker_case incompleto: $docker_result"
  fi
done

expected_full='flag:off,seed,test:off,flag:on,test:on,teardown,flag:off,collect'
got="$(matrix_case success)"
[ "$got" = "0|$expected_full" ] && ok "orden dinamico OFF-seed-OFF-ON-teardown-restauracion" || bad "orden dinamico inesperado: $got"
got="$(matrix_case off-fail 2>/dev/null)"
[ "$got" = "1|$expected_full" ] && ok "OFF fallido ejecuta ON y conserva rojo" || bad "acumulacion OFF inesperada: $got"
got="$(matrix_case seed-fail 2>/dev/null)"
[ "$got" = '1|flag:off,seed,teardown,flag:off,collect' ] && ok "seed parcial entra a teardown y conserva rojo" || bad "seed parcial inesperado: $got"
got="$(matrix_case teardown-fail 2>/dev/null)"
[ "$got" = "1|$expected_full" ] && ok "teardown fallido conserva rojo" || bad "teardown inesperado: $got"
got="$(matrix_case restore-fail 2>/dev/null)"
[ "$got" = "1|$expected_full" ] && ok "restauracion fallida conserva rojo" || bad "restauracion inesperada: $got"

# =============================================================================
# T-002 — smoke golden fail-closed (matriz C01-C20 + checks estaticos)
# =============================================================================
GOLDEN_ORCH="$ROOT/scripts/run-e2e-smoke-golden.sh"
GOLDEN_M1="$ROOT/scripts/run-e2e-smoke-golden-m1.sh"
GOLDEN_MAC="$ROOT/scripts/run-e2e-smoke-golden-macdata.sh"
GOLDEN_INNER="$ROOT/scripts/e2e-smoke-golden-remote-inner.sh"
WATCHDOG_LIB="$ROOT/lib/watchdog.sh"

contains "$MAKEFILE" 'run-e2e-smoke-golden:' "target publico run-e2e-smoke-golden"
contains "$MAKEFILE" 'GOLDEN_NPM_TIMEOUT_S' "perilla GOLDEN_NPM_TIMEOUT_S"
contains "$MAKEFILE" 'GOLDEN_CHROMIUM_TIMEOUT_S' "perilla GOLDEN_CHROMIUM_TIMEOUT_S"
contains "$MAKEFILE" 'GOLDEN_PLAYWRIGHT_TIMEOUT_S' "perilla GOLDEN_PLAYWRIGHT_TIMEOUT_S"
contains "$MAKEFILE" 'GOLDEN_RSYNC_TIMEOUT_S' "perilla GOLDEN_RSYNC_TIMEOUT_S"
contains "$MAKEFILE" 'PM_E2E_GOLDEN_NPM_TIMEOUT_S' "export PM_E2E_GOLDEN_NPM_TIMEOUT_S desde Make"

contains "$WATCHDOG_LIB" 'run_with_watchdog' "lib/watchdog.sh define run_with_watchdog"
contains "$WATCHDOG_LIB" 'process_tree' "lib/watchdog.sh define process_tree"
contains "$WATCHDOG_LIB" 'return 124' "watchdog retorna 124 al vencer"
contains "$REMOTE" 'watchdog.sh' "e2e-playwright-remote sourcea watchdog central"
contains "$E2E" 'lib/watchdog.sh' "e2e.sh stagea watchdog junto al runner remoto"

contains "$GOLDEN_ORCH" 'unset PM_E2E_GOLDEN_READY' "orquestador limpia handshake stale"
contains "$GOLDEN_ORCH" 'PM_E2E_GOLDEN_READY=1' "orquestador exporta handshake tras restore"
contains "$GOLDEN_ORCH" 'PREPARATION_FAILED' "orquestador conoce PREPARATION_FAILED"
contains "$GOLDEN_ORCH" 'EVIDENCE_FAILED' "orquestador conoce EVIDENCE_FAILED"
contains "$GOLDEN_ORCH" 'TEST_AND_EVIDENCE_FAILED' "orquestador conoce TEST_AND_EVIDENCE_FAILED"
contains "$GOLDEN_ORCH" 'GOLDEN_EVIDENCE_EXIT=74' "codigo 74 para evidencia fallida"
contains "$GOLDEN_ORCH" 'result.status' "orquestador escribe result.status"
contains "$GOLDEN_ORCH" 'golden_persist_verdict' "orquestador tiene reductor de veredicto"
not_contains "$GOLDEN_ORCH" 'AVISO: intake-load' "restore ya no es AVISO fail-open"

contains "$GOLDEN_M1" 'PM_E2E_GOLDEN_READY' "M1 exige handshake"
contains "$GOLDEN_M1" 'run_with_watchdog' "M1 usa watchdog"
contains "$GOLDEN_M1" '--grep @golden-smoke' "M1 selecciona tag @golden-smoke"
contains "$GOLDEN_M1" '--retries=0' "M1 fuerza retries=0"
contains "$GOLDEN_M1" 'playwright.smoke-golden.config.ts' "M1 usa config smoke-golden"
contains "$GOLDEN_M1" 'PM_E2E_PROFILE=m1' "M1 fija profile m1"
contains "$GOLDEN_M1" 'runner.status' "M1 emite runner.status"

contains "$GOLDEN_MAC" 'PM_E2E_GOLDEN_READY=1' "macdata transmite handshake explicito"
contains "$GOLDEN_MAC" 'run_with_watchdog' "macdata usa watchdog"
contains "$GOLDEN_MAC" '.results/$RUN_ID' "macdata aisla evidencia por RUN_ID"
contains "$GOLDEN_MAC" 'GOLDEN_EVIDENCE_EXIT=74' "macdata usa exit 74 de evidencia"
contains "$GOLDEN_MAC" 'watchdog.sh' "macdata stagea watchdog"

contains "$GOLDEN_INNER" 'PM_E2E_GOLDEN_READY' "remote-inner exige handshake"
contains "$GOLDEN_INNER" 'run_with_watchdog' "remote-inner usa watchdog"
contains "$GOLDEN_INNER" '--grep @golden-smoke' "remote-inner selecciona tag @golden-smoke"
contains "$GOLDEN_INNER" '--retries=0' "remote-inner fuerza retries=0"
contains "$GOLDEN_INNER" 'playwright.smoke-golden.config.ts' "remote-inner usa config smoke-golden"
contains "$GOLDEN_INNER" 'PM_E2E_PROFILE=macdata' "remote-inner fija profile macdata"
contains "$GOLDEN_INNER" 'runner.status' "remote-inner emite runner.status"
if grep -n 'npx playwright test' "$GOLDEN_INNER" | grep -q -- '--headed'; then
  bad "remote-inner npx no debe pasar --headed"
else
  ok "remote-inner npx sin --headed"
fi

# --- helpers de contrato golden ---
golden_source() {
  PM_E2E_GOLDEN_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
    . "$1"
    eval "$2"
  ' _ "$GOLDEN_ORCH" "$1"
}

# C01/C02: restore fallido y handshake stale — via fuente (no invoca dispatch)
c01="$(golden_source '
  # simula restore fallido: el orquestador propaga rc y no exporta handshake
  PREPARE_EXIT=9; TEST_EXIT=-1; EVIDENCE_EXIT=-1; EVIDENCE_COMPLETE=0; HANDSHAKE_EXPORTED=0
  FINAL_PHASE=golden_restore; RUN_ID=c01; RUNNER=m1
  golden_reduce_status
  # handshake debe estar ausente tras unset al sourcear
  hs="${PM_E2E_GOLDEN_READY-UNSET}"
  printf "%s|%s|%s|%s" "$FINAL_STATUS" "$FINAL_EXIT" "$hs" "${HANDSHAKE_EXPORTED}"
')"
[ "$c01" = 'PREPARATION_FAILED|9|UNSET|0' ] && ok "C01 restore fallido => PREPARATION_FAILED exit 9 sin handshake" \
  || bad "C01 inesperado: $c01"

c02="$(PM_E2E_GOLDEN_READY=1 PM_E2E_GOLDEN_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
  . "$1"
  # tras source, el unset del orquestador debe haber eliminado el valor stale
  hs="${PM_E2E_GOLDEN_READY-UNSET}"
  PREPARE_EXIT=9; TEST_EXIT=-1; EVIDENCE_EXIT=-1; EVIDENCE_COMPLETE=0; HANDSHAKE_EXPORTED=0
  golden_reduce_status
  printf "%s|%s|%s" "$FINAL_STATUS" "$FINAL_EXIT" "$hs"
' _ "$GOLDEN_ORCH")"
[ "$c02" = 'PREPARATION_FAILED|9|UNSET' ] && ok "C02 handshake stale se elimina; restore fallido igual que C01" \
  || bad "C02 inesperado: $c02"

# C06: matriz invalida (validacion antes de load_env)
c06a="$(PM_E2E_GOLDEN_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
  . "$1"
  WT=x; LEGACYWT=y; RUNNER=macdata; HEADLESS=0
  WRAPPER_DIR=/tmp
  golden_validate_matrix >/dev/null 2>&1; printf "%s" $?
' _ "$GOLDEN_ORCH" 2>/dev/null)" || c06a=1
# die hace exit 1; capturar
c06a="$(PM_E2E_GOLDEN_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
  . "$1" || true
  WT=x; LEGACYWT=y; RUNNER=macdata; HEADLESS=0; WRAPPER_DIR=/tmp
  ( golden_validate_matrix ) >/dev/null 2>&1
  printf "%s" $?
' _ "$GOLDEN_ORCH")"
[ "$c06a" != 0 ] && ok "C06 macdata+HEADLESS=0 falla antes de load_env" || bad "C06a no rechazo HEADLESS=0: $c06a"

c06b="$(PM_E2E_GOLDEN_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
  . "$1"
  WT=x; LEGACYWT=y; RUNNER=desconocido; HEADLESS=1; WRAPPER_DIR=/tmp
  ( golden_validate_matrix ) >/dev/null 2>&1
  printf "%s" $?
' _ "$GOLDEN_ORCH")"
[ "$c06b" != 0 ] && ok "C06 runner desconocido falla cerrado" || bad "C06b no rechazo runner: $c06b"

# C08/C10/C11/C12 reductor de estados
c08="$(golden_source '
  PREPARE_EXIT=0; TEST_EXIT=7; EVIDENCE_EXIT=0; EVIDENCE_COMPLETE=1; HANDSHAKE_EXPORTED=1
  golden_reduce_status; printf "%s|%s" "$FINAL_STATUS" "$FINAL_EXIT"
')"
[ "$c08" = 'TEST_FAILED|7' ] && ok "C08 Playwright rojo + evidencia completa => TEST_FAILED/7" \
  || bad "C08 inesperado: $c08"

c10="$(golden_source '
  PREPARE_EXIT=0; TEST_EXIT=0; EVIDENCE_EXIT=23; EVIDENCE_COMPLETE=0; HANDSHAKE_EXPORTED=1
  golden_reduce_status; printf "%s|%s" "$FINAL_STATUS" "$FINAL_EXIT"
')"
[ "$c10" = 'EVIDENCE_FAILED|74' ] && ok "C10 test verde + collect falla => EVIDENCE_FAILED/74" \
  || bad "C10 inesperado: $c10"

c11="$(golden_source '
  PREPARE_EXIT=0; TEST_EXIT=7; EVIDENCE_EXIT=23; EVIDENCE_COMPLETE=0; HANDSHAKE_EXPORTED=1
  golden_reduce_status; printf "%s|%s" "$FINAL_STATUS" "$FINAL_EXIT"
')"
[ "$c11" = 'TEST_AND_EVIDENCE_FAILED|7' ] && ok "C11 test y evidencia fallan => TEST_AND_EVIDENCE_FAILED/7" \
  || bad "C11 inesperado: $c11"

c12="$(golden_source '
  PREPARE_EXIT=0; TEST_EXIT=0; EVIDENCE_EXIT=74; EVIDENCE_COMPLETE=0; HANDSHAKE_EXPORTED=1
  golden_reduce_status; printf "%s|%s" "$FINAL_STATUS" "$FINAL_EXIT"
')"
[ "$c12" = 'EVIDENCE_FAILED|74' ] && ok "C12 evidencia incompleta con test verde => final 74" \
  || bad "C12 inesperado: $c12"

# C13: evidencia stale (run_id distinto)
c13_dir="$(mktemp -d "${TMPDIR:-/tmp}/pm-t002-c13.XXXXXX")"
printf 'schema\tpm-e2e-smoke-golden-runner/v1\nrun_id\told-run\nphase\tplaywright\ntest_exit\t0\nhandshake_exported\t1\n' > "$c13_dir/runner.status"
printf 'log\n' > "$c13_dir/test.log"
printf '{}\n' > "$c13_dir/results.json"
mkdir -p "$c13_dir/playwright-report" "$c13_dir/test-results"
printf 'html\n' > "$c13_dir/playwright-report/index.html"
printf 'last\n' > "$c13_dir/test-results/.last-run.json"
c13="$(PM_E2E_GOLDEN_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
  . "$1"
  if golden_validate_evidence "$2" "new-run"; then printf "ok"; else printf "reject"; fi
' _ "$GOLDEN_ORCH" "$c13_dir")"
[ "$c13" = reject ] && ok "C13 evidencia stale (run_id distinto) se rechaza" || bad "C13 inesperado: $c13"
# cleanup sin rm -rf: unlink archivos y rmdir
unlink "$c13_dir/runner.status" "$c13_dir/test.log" "$c13_dir/results.json" \
  "$c13_dir/playwright-report/index.html" "$c13_dir/test-results/.last-run.json" 2>/dev/null || true
rmdir "$c13_dir/playwright-report" "$c13_dir/test-results" "$c13_dir" 2>/dev/null || true

# C20: parser hostil — nunca sourcea; claves duplicadas / rc no numerico fallan
c20a="$(PM_E2E_GOLDEN_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
  . "$1"
  f="$2"
  printf "schema\tpm-e2e-smoke-golden-runner/v1\nrun_id\tr1\nrun_id\tr2\nphase\tp\ntest_exit\t0\n" > "$f"
  if golden_parse_runner_status "$f"; then printf "ok"; else printf "reject"; fi
' _ "$GOLDEN_ORCH" "$(mktemp "${TMPDIR:-/tmp}/pm-t002-c20a.XXXXXX")")"
[ "$c20a" = reject ] && ok "C20 claves duplicadas en runner.status se rechazan" || bad "C20a inesperado: $c20a"

c20b="$(PM_E2E_GOLDEN_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
  . "$1"
  f="$2"
  printf "schema\tpm-e2e-smoke-golden-runner/v1\nrun_id\tr1\nphase\tp\ntest_exit\tNOTNUM\n" > "$f"
  if golden_parse_runner_status "$f"; then printf "ok"; else printf "reject"; fi
' _ "$GOLDEN_ORCH" "$(mktemp "${TMPDIR:-/tmp}/pm-t002-c20b.XXXXXX")")"
[ "$c20b" = reject ] && ok "C20 test_exit no numerico se rechaza" || bad "C20b inesperado: $c20b"

c20c="$(PM_E2E_GOLDEN_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
  . "$1"
  f="$2"
  # sin tabs: formato hostil
  printf "schema=pm-e2e\nrun_id=r1\ntest_exit=0\n" > "$f"
  if golden_parse_runner_status "$f"; then printf "ok"; else printf "reject"; fi
' _ "$GOLDEN_ORCH" "$(mktemp "${TMPDIR:-/tmp}/pm-t002-c20c.XXXXXX")")"
[ "$c20c" = reject ] && ok "C20 status sin TSV se rechaza (nunca se sourcea)" || bad "C20c inesperado: $c20c"

# C20d (S3): guion-basura multi-token (1-2) — el case laxo de r1 lo aceptaba; el estricto lo rechaza.
c20d="$(PM_E2E_GOLDEN_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
  . "$1"
  f="$2"
  printf "schema\tpm-e2e-smoke-golden-runner/v1\nrun_id\tr1\nphase\tp\ntest_exit\t1-2\n" > "$f"
  if golden_parse_runner_status "$f"; then printf "ok"; else printf "reject"; fi
' _ "$GOLDEN_ORCH" "$(mktemp "${TMPDIR:-/tmp}/pm-t002-c20d.XXXXXX")")"
[ "$c20d" = reject ] && ok "C20 test_exit guion-basura (1-2) se rechaza" || bad "C20d inesperado: $c20d"

# C03/C04/C07/C14/C15/C16/C18/C19 — ejecucion sintetica del leaf M1 con PATH fake
golden_m1_sim() {
  local mode="$1" fixture fake_bin suite result out rc headless="${2:-1}"
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/pm-t002-m1.XXXXXX")"
  fake_bin="$fixture/bin"; suite="$fixture/legacy/tests/e2e"; result="$fixture/result"
  mkdir -p "$fake_bin" "$suite" "$result" "$suite/node_modules/playwright"
  # package.json minimo para npm ci
  printf '{ "name": "e2e-fixture" }\n' > "$suite/package.json"
  printf 'lock\n' > "$suite/package-lock.json"
  printf 'export const chromium={executablePath:()=>"/bin/true"}\n' > "$suite/node_modules/playwright/index.js"
  # node fake: responde a --input-type=module (probe chromium) y -p version
  cat > "$fake_bin/node" <<'NODE'
#!/bin/sh
if [ "$1" = "--input-type=module" ] || [ "$1" = "--input-type" ]; then
  # probe chromium: mode force-install => exit 1; else exit 0 (presente)
  case "${GOLDEN_SIM_CHROMIUM:-present}" in
    missing|force-install|hang-install) exit 1 ;;
    *) exit 0 ;;
  esac
fi
if [ "$1" = "-p" ]; then printf '20\n'; exit 0; fi
exit 0
NODE
  chmod +x "$fake_bin/node"
  cat > "$fake_bin/npm" <<'NPM'
#!/bin/sh
printf 'NPM|ci\n' >> "${GOLDEN_SIM_LOG}"
case "${GOLDEN_SIM_NPM:-ok}" in
  hang) sleep 30; exit 0 ;;
  fail) exit 9 ;;
  *) exit 0 ;;
esac
NPM
  chmod +x "$fake_bin/npm"
  cat > "$fake_bin/npx" <<'NPX'
#!/bin/sh
# Delimitador ASCII RS para no chocar con el parser de la suite (usa |).
printf 'NPX\036%s\n' "$*" >> "${GOLDEN_SIM_LOG}"
case " $* " in
  *" playwright install chromium "*)
    case "${GOLDEN_SIM_CHROMIUM:-present}" in
      hang-install) sleep 30; exit 0 ;;
      fail-install) exit 11 ;;
      *) exit 0 ;;
    esac
    ;;
esac
case "${GOLDEN_SIM_PW:-ok}" in
  hang) sleep 30; exit 0 ;;
  fail) exit 7 ;;
  *)
    mkdir -p "${GOLDEN_SIM_RESULT}/playwright-report" "${GOLDEN_SIM_RESULT}/test-results"
    printf '{}\n' > "${GOLDEN_SIM_RESULT}/results.json"
    printf 'html\n' > "${GOLDEN_SIM_RESULT}/playwright-report/index.html"
    printf 'last\n' > "${GOLDEN_SIM_RESULT}/test-results/.last-run.json"
    exit 0
    ;;
esac
NPX
  chmod +x "$fake_bin/npx"
  logf="$fixture/sim.log"; : > "$logf"
  export GOLDEN_SIM_LOG="$logf" GOLDEN_SIM_RESULT="$result"
  case "$mode" in
    hang-npm) export GOLDEN_SIM_NPM=hang GOLDEN_SIM_CHROMIUM=present GOLDEN_SIM_PW=ok ;;
    hang-chromium) export GOLDEN_SIM_NPM=ok GOLDEN_SIM_CHROMIUM=hang-install GOLDEN_SIM_PW=ok ;;
    hang-pw) export GOLDEN_SIM_NPM=ok GOLDEN_SIM_CHROMIUM=present GOLDEN_SIM_PW=hang ;;
    fail-pw) export GOLDEN_SIM_NPM=ok GOLDEN_SIM_CHROMIUM=present GOLDEN_SIM_PW=fail ;;
    ok-headed) export GOLDEN_SIM_NPM=ok GOLDEN_SIM_CHROMIUM=present GOLDEN_SIM_PW=ok; headless=0 ;;
    ok) export GOLDEN_SIM_NPM=ok GOLDEN_SIM_CHROMIUM=present GOLDEN_SIM_PW=ok ;;
    no-handshake) : ;;
  esac
  export PM_E2E_PROFILE=hostile PM_E2E_BASE_URL=http://hostile/ PM_E2E_PLANTA=XXX
  export PM_E2E_OUTPUT_DIR=/tmp/hostile-out PM_E2E_RESULTS_FILE=/tmp/hostile.json
  out="$fixture/out.log"
  rc=0
  if [ "$mode" = no-handshake ]; then
    unset PM_E2E_GOLDEN_READY || true
    printf 'user\0pass\0' | env PATH="$fake_bin:/usr/bin:/bin" \
      PM_E2E_GOLDEN_RUN_ID="run-sim-$$" \
      PM_E2E_GOLDEN_NPM_TIMEOUT_S="${GOLDEN_SIM_NPM_TO:-5}" \
      PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S="${GOLDEN_SIM_CHR_TO:-5}" \
      PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S="${GOLDEN_SIM_PW_TO:-5}" \
      /bin/bash "$GOLDEN_M1" "$fixture/legacy" "$result" "http://fixture-base/" "$headless" \
      >"$out" 2>&1 || rc=$?
  else
    printf 'user\0pass\0' | env PATH="$fake_bin:/usr/bin:/bin" \
      PM_E2E_GOLDEN_READY=1 \
      PM_E2E_GOLDEN_RUN_ID="run-sim-$$" \
      PM_E2E_GOLDEN_NPM_TIMEOUT_S="${GOLDEN_SIM_NPM_TO:-5}" \
      PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S="${GOLDEN_SIM_CHR_TO:-5}" \
      PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S="${GOLDEN_SIM_PW_TO:-5}" \
      /bin/bash "$GOLDEN_M1" "$fixture/legacy" "$result" "http://fixture-base/" "$headless" \
      >"$out" 2>&1 || rc=$?
  fi
  npx_line="$(grep $'^NPX\036' "$logf" 2>/dev/null | grep 'playwright test' | head -1 | sed $'s/^NPX\036//' || true)"
  npx_count="$(grep -c $'^NPX\036' "$logf" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$npx_count" ] || npx_count=0
  st_flag=no_status
  [ -f "$result/runner.status" ] && st_flag=has_status
  # Delimitador de campos de la suite: @@ (no aparece en argv de playwright)
  printf '%s@@%s@@%s@@%s' "$rc" "$npx_line" "$st_flag" "$npx_count"
  unlink "$fake_bin/node" "$fake_bin/npm" "$fake_bin/npx" 2>/dev/null || true
  unlink "$suite/package.json" "$suite/package-lock.json" 2>/dev/null || true
  unlink "$suite/node_modules/playwright/index.js" 2>/dev/null || true
  rmdir "$suite/node_modules/playwright" "$suite/node_modules" 2>/dev/null || true
  find "$result" -type f -print 2>/dev/null | while IFS= read -r f; do unlink "$f" 2>/dev/null || true; done
  find "$result" -depth -type d -print 2>/dev/null | while IFS= read -r d; do rmdir "$d" 2>/dev/null || true; done
  unlink "$logf" "$out" 2>/dev/null || true
  rmdir "$fake_bin" "$suite" "$fixture/legacy/tests" "$fixture/legacy" "$fixture" 2>/dev/null || true
}

# C03 M1 headless
c03="$(golden_m1_sim ok 1)"
c03_rc="$(printf '%s' "$c03" | awk -F'@@' '{print $1}')"
c03_npx="$(printf '%s' "$c03" | awk -F'@@' '{print $2}')"
c03_st="$(printf '%s' "$c03" | awk -F'@@' '{print $3}')"
c03_n="$(printf '%s' "$c03" | awk -F'@@' '{print $4}')"
if [ "$c03_rc" = 0 ] && printf '%s' "$c03_npx" | grep -Fq 'playwright.smoke-golden.config.ts' \
  && printf '%s' "$c03_npx" | grep -Fq '@golden-smoke' \
  && printf '%s' "$c03_npx" | grep -Fq -- '--retries=0' \
  && ! printf '%s' "$c03_npx" | grep -Fq -- '--headed' \
  && [ "$c03_st" = has_status ] && [ "$c03_n" = 1 ]; then
  ok "C03 M1 headless: un npx, config golden, sin --headed, runner.status"
else
  bad "C03 inesperado: $c03"
fi

# C04 M1 visible
c04="$(golden_m1_sim ok-headed 0)"
c04_rc="$(printf '%s' "$c04" | awk -F'@@' '{print $1}')"
c04_npx="$(printf '%s' "$c04" | awk -F'@@' '{print $2}')"
if [ "$c04_rc" = 0 ] && printf '%s' "$c04_npx" | grep -Fq -- '--headed'; then
  ok "C04 M1 visible: un --headed"
else
  bad "C04 inesperado: $c04"
fi

# C07 precedencia productora: profile/url hostiles no aparecen en invocacion; paths son del RESULT
# (el leaf exporta PM_E2E_PROFILE=m1 explicitamente; verificamos en fuente + sim ok)
contains "$GOLDEN_M1" 'export PM_E2E_PROFILE=m1' "C07 M1 fija profile sin :-"
contains "$GOLDEN_M1" 'export PM_E2E_BASE_URL="$BASE_URL"' "C07 M1 fija BASE_URL del orquestador"
contains "$GOLDEN_INNER" 'export PM_E2E_PROFILE=macdata' "C07 remote-inner fija profile macdata"
contains "$GOLDEN_MAC" "--exclude '.env*'" "C07 rsync excluye .env*"

# C08 via M1 sim fail-pw
c08m="$(golden_m1_sim fail-pw 1)"
c08m_rc="$(printf '%s' "$c08m" | awk -F'@@' '{print $1}')"
[ "$c08m_rc" = 7 ] && ok "C08/M1 Playwright rojo propaga rc=7" || bad "C08/M1 rc inesperado: $c08m"

# C14 watchdog npm
c14="$(GOLDEN_SIM_NPM_TO=1 golden_m1_sim hang-npm 1)"
c14_rc="$(printf '%s' "$c14" | awk -F'@@' '{print $1}')"
[ "$c14_rc" = 124 ] && ok "C14 watchdog npm => exit 124" || bad "C14 inesperado: $c14"

# C15 watchdog chromium
c15="$(GOLDEN_SIM_CHR_TO=1 golden_m1_sim hang-chromium 1)"
c15_rc="$(printf '%s' "$c15" | awk -F'@@' '{print $1}')"
[ "$c15_rc" = 124 ] && ok "C15 watchdog chromium => exit 124" || bad "C15 inesperado: $c15"

# C16 watchdog playwright
c16="$(GOLDEN_SIM_PW_TO=1 golden_m1_sim hang-pw 1)"
c16_rc="$(printf '%s' "$c16" | awk -F'@@' '{print $1}')"
[ "$c16_rc" = 124 ] && ok "C16 watchdog playwright => exit 124, un intento" || bad "C16 inesperado: $c16"

# C18 señales INT durante comando (via watchdog helper + hang)
c18_dir="$(mktemp -d "${TMPDIR:-/tmp}/pm-t002-c18.XXXXXX")"
c18_rc=0
/bin/bash -c '
  . "$1"
  RESULT_ROOT="$2"; PHASE=c18; WATCHDOG_RUNNER=contract
  ACTIVE_CMD_PID=""; ACTIVE_WATCHDOG_PID=""
  mkdir -p "$RESULT_ROOT"
  sig(){ local pid tree
    trap - INT TERM
    for pid in ${ACTIVE_CMD_PID:-} ${ACTIVE_WATCHDOG_PID:-}; do
      [ -n "$pid" ] || continue
      tree=$(process_tree "$pid")
      for p in $tree; do kill -TERM "$p" 2>/dev/null || true; done
    done
    exit 130
  }
  trap sig INT TERM
  ( sleep 0.3; kill -INT $$ ) &
  run_with_watchdog 10 sleep 30
' _ "$WATCHDOG_LIB" "$c18_dir" >/dev/null 2>&1 || c18_rc=$?
[ "$c18_rc" = 130 ] && ok "C18 INT/TERM retira hijos y sale 130" || bad "C18 rc inesperado: $c18_rc"
find "$c18_dir" -type f -print 2>/dev/null | while IFS= read -r f; do unlink "$f" 2>/dev/null || true; done
rmdir "$c18_dir" 2>/dev/null || true

# C19 spec exclusivo: config + tag + retries=0 + una invocacion (ya en C03); reforzar never general config
c19="$(golden_m1_sim ok 1)"
c19_npx="$(printf '%s' "$c19" | awk -F'@@' '{print $2}')"
if printf '%s' "$c19_npx" | grep -Fq 'playwright.smoke-golden.config.ts' \
  && ! printf '%s' "$c19_npx" | grep -Fq -- 'playwright.config.ts' \
  && printf '%s' "$c19_npx" | grep -Fq '@golden-smoke' \
  && printf '%s' "$c19_npx" | grep -Fq -- '--retries=0'; then
  ok "C19 spec exclusivo: config golden + @golden-smoke + retries=0 (nunca config general)"
else
  bad "C19 inesperado: $c19"
fi

# sin handshake
c_nh="$(golden_m1_sim no-handshake 1)"
c_nh_rc="$(printf '%s' "$c_nh" | awk -F'@@' '{print $1}')"
[ "$c_nh_rc" != 0 ] && ok "M1 sin handshake falla cerrado" || bad "M1 sin handshake no fallo: $c_nh"

# C05/C09/C10/C17 — hop macdata sintetico con fakes de ssh/rsync
golden_mac_sim() {
  local mode="$1" fixture fake_bin result logf out rc
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/pm-t002-mac.XXXXXX")"
  fake_bin="$fixture/bin"; result="$fixture/result"; logf="$fixture/sim.log"
  mkdir -p "$fake_bin" "$result" "$fixture/legacy/tests/e2e"
  printf '{}\n' > "$fixture/legacy/tests/e2e/package.json"
  : > "$logf"
  cat > "$fake_bin/ssh" <<'SSH'
#!/bin/sh
printf 'SSH\036%s\n' "$*" >> "${GOLDEN_SIM_LOG}"
# El hop del runner siempre lleva PM_E2E_GOLDEN_READY=1 en la linea de comando.
# mkdir/chmod de stage no lo llevan y completan al instante.
case "$*" in
  *PM_E2E_GOLDEN_READY=1*)
    case "${GOLDEN_SIM_SSH:-ok}" in
      hang) sleep 30; exit 0 ;;
      fail) exit 255 ;;
      *)
        case "${GOLDEN_SIM_REMOTE_RC:-0}" in
          7) exit 7 ;;
          124) exit 124 ;;
          *) exit 0 ;;
        esac
        ;;
    esac
    ;;
  *)
    case "${GOLDEN_SIM_SSH:-ok}" in
      hang-stage) sleep 30; exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
esac
SSH
  chmod +x "$fake_bin/ssh"
  cat > "$fake_bin/rsync" <<'RSYNC'
#!/bin/sh
printf 'RSYNC\036%s\n' "$*" >> "${GOLDEN_SIM_LOG}"
case "${GOLDEN_SIM_RSYNC:-ok}" in
  hang) sleep 30; exit 0 ;;
  stage-fail) exit 12 ;;
  collect-fail)
    case "$*" in
      *"$GOLDEN_SIM_RESULT"*) exit 23 ;;
      *) exit 0 ;;
    esac
    ;;
  incomplete)
    exit 0
    ;;
  *)
    case "$*" in
      *"$GOLDEN_SIM_RESULT"*)
        mkdir -p "$GOLDEN_SIM_RESULT/playwright-report" "$GOLDEN_SIM_RESULT/test-results"
        printf 'schema\tpm-e2e-smoke-golden-runner/v1\nrun_id\t%s\nphase\tplaywright\ntest_exit\t%s\nhandshake_exported\t1\n' \
          "${PM_E2E_GOLDEN_RUN_ID}" "${GOLDEN_SIM_REMOTE_RC:-0}" > "$GOLDEN_SIM_RESULT/runner.status"
        printf 'log\n' > "$GOLDEN_SIM_RESULT/test.log"
        printf '{}\n' > "$GOLDEN_SIM_RESULT/results.json"
        printf 'html\n' > "$GOLDEN_SIM_RESULT/playwright-report/index.html"
        printf 'last\n' > "$GOLDEN_SIM_RESULT/test-results/.last-run.json"
        ;;
    esac
    exit 0
    ;;
esac
RSYNC
  chmod +x "$fake_bin/rsync"
  export GOLDEN_SIM_LOG="$logf" GOLDEN_SIM_RESULT="$result"
  sim_ssh=ok; sim_rsync=ok; sim_remote_rc=0
  case "$mode" in
    ok) : ;;
    fail-pw) sim_remote_rc=7 ;;
    collect-fail) sim_rsync=collect-fail ;;
    incomplete) sim_rsync=incomplete ;;
    hang-ssh) sim_ssh=hang-stage ;;
    hang-runner-ssh) sim_ssh=hang ;;
    hang-rsync) sim_rsync=hang ;;
    test-and-collect-fail) sim_rsync=collect-fail; sim_remote_rc=7 ;;
  esac
  out="$fixture/out.log"; rc=0
  _ssh_to="${GOLDEN_SIM_SSH_TO:-5}"
  _rs_to="${GOLDEN_SIM_RSYNC_TO:-5}"
  # Variables del fake van literales (no dependen de export residual del shell padre).
  printf 'user\0pass\0' | env -i \
    PATH="$fake_bin:/usr/bin:/bin" \
    HOME="${HOME:-/tmp}" \
    TMPDIR="${TMPDIR:-/tmp}" \
    PM_E2E_GOLDEN_READY=1 \
    PM_E2E_GOLDEN_RUN_ID="run-mac-$$" \
    PM_E2E_GOLDEN_NPM_TIMEOUT_S=5 \
    PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S=5 \
    PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S=5 \
    PM_E2E_GOLDEN_RSYNC_TIMEOUT_S="$_rs_to" \
    PM_E2E_GOLDEN_SSH_TIMEOUT_S="$_ssh_to" \
    GOLDEN_SIM_SSH="$sim_ssh" \
    GOLDEN_SIM_RSYNC="$sim_rsync" \
    GOLDEN_SIM_REMOTE_RC="$sim_remote_rc" \
    GOLDEN_SIM_LOG="$logf" \
    GOLDEN_SIM_RESULT="$result" \
    PM_REMOTE_SSH=fakehost \
    /bin/bash "$GOLDEN_MAC" "$fixture/legacy" "$result" "http://fixture-base/" "3" \
    >"$out" 2>&1 || rc=$?
  ssh_hs="$(grep $'^SSH\036' "$logf" 2>/dev/null | grep -c 'PM_E2E_GOLDEN_READY=1' || true)"
  rsync_n="$(grep -c $'^RSYNC\036' "$logf" 2>/dev/null || echo 0)"
  printf '%s@@hs=%s@@rsync=%s' "$rc" "$ssh_hs" "$rsync_n"
  unlink "$fake_bin/ssh" "$fake_bin/rsync" 2>/dev/null || true
  find "$result" -type f -print 2>/dev/null | while IFS= read -r f; do unlink "$f" 2>/dev/null || true; done
  find "$result" -depth -type d -print 2>/dev/null | while IFS= read -r d; do rmdir "$d" 2>/dev/null || true; done
  unlink "$logf" "$out" "$fixture/legacy/tests/e2e/package.json" 2>/dev/null || true
  rmdir "$fake_bin" "$fixture/legacy/tests/e2e" "$fixture/legacy/tests" "$fixture/legacy" "$fixture" 2>/dev/null || true
}

c05="$(golden_mac_sim ok)"
c05_rc="$(printf '%s' "$c05" | awk -F'@@' '{print $1}')"
c05_hs="$(printf '%s' "$c05" | sed -n 's/.*hs=\([0-9]*\).*/\1/p')"
if [ "$c05_rc" = 0 ] && [ "${c05_hs:-0}" -ge 1 ]; then
  ok "C05 macdata valido: stage/SSH/collect con handshake explicito (rc=0)"
else
  bad "C05 inesperado: $c05"
fi

c09="$(golden_mac_sim fail-pw)"
c09_rc="$(printf '%s' "$c09" | awk -F'@@' '{print $1}')"
[ "$c09_rc" = 7 ] && ok "C09 Playwright rojo macdata propaga rc=7" || bad "C09 inesperado: $c09"

c10m="$(golden_mac_sim collect-fail)"
c10m_rc="$(printf '%s' "$c10m" | awk -F'@@' '{print $1}')"
[ "$c10m_rc" = 74 ] && ok "C10/mac collect falla tras verde => exit 74" || bad "C10/mac inesperado: $c10m"

c12m="$(golden_mac_sim incomplete)"
c12m_rc="$(printf '%s' "$c12m" | awk -F'@@' '{print $1}')"
[ "$c12m_rc" = 74 ] && ok "C12/mac descarga incompleta (rc0 rsync) => exit 74" || bad "C12/mac inesperado: $c12m"

# hang-stage cuelga el primer ssh (mkdir); el techo es RSYNC_TIMEOUT (misma perilla del stage).
unset GOLDEN_SIM_SSH GOLDEN_SIM_RSYNC GOLDEN_SIM_REMOTE_RC GOLDEN_SIM_SSH_TO GOLDEN_SIM_RSYNC_TO 2>/dev/null || true
c17a="$(GOLDEN_SIM_RSYNC_TO=1 golden_mac_sim hang-ssh)"
case "$c17a" in
  124@@*) ok "C17 watchdog SSH (stage) => exit 124" ;;
  *) bad "C17/ssh inesperado: $c17a" ;;
esac
# hang del hop runner completo
unset GOLDEN_SIM_SSH GOLDEN_SIM_RSYNC GOLDEN_SIM_REMOTE_RC GOLDEN_SIM_SSH_TO GOLDEN_SIM_RSYNC_TO 2>/dev/null || true
c17c="$(GOLDEN_SIM_SSH_TO=1 golden_mac_sim hang-runner-ssh)"
case "$c17c" in
  124@@*) ok "C17 watchdog SSH (runner hop) => exit 124" ;;
  *) bad "C17/runner-ssh inesperado: $c17c" ;;
esac

unset GOLDEN_SIM_SSH GOLDEN_SIM_RSYNC GOLDEN_SIM_REMOTE_RC GOLDEN_SIM_SSH_TO GOLDEN_SIM_RSYNC_TO 2>/dev/null || true
c17b="$(GOLDEN_SIM_RSYNC_TO=1 golden_mac_sim hang-rsync)"
case "$c17b" in
  124@@*) ok "C17 watchdog rsync => exit 124" ;;
  *) bad "C17/rsync inesperado: $c17b" ;;
esac

# C11: test 7 + collect 23 (mac) — collect si se intenta; final=7
c11m="$(golden_mac_sim test-and-collect-fail)"
c11m_rc="$(printf '%s' "$c11m" | awk -F'@@' '{print $1}')"
[ "$c11m_rc" = 7 ] && ok "C11 test7+collect23 => final 7 (collect si se intenta)" || bad "C11/mac inesperado: $c11m"

# Persistencia atomica del veredicto
c_persist="$(PM_E2E_GOLDEN_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
  . "$1"
  d="$2"
  mkdir -p "$d"
  RUN_ID=persist-1; RUNNER=m1; HEADLESS=1; SLOT=1; BASE_URL=http://x/; PM_HEAD=a; LEGACY_HEAD=b
  PREPARE_EXIT=0; TEST_EXIT=0; EVIDENCE_EXIT=0; EVIDENCE_COMPLETE=1; HANDSHAKE_EXPORTED=1
  FINAL_PHASE=verdict
  golden_persist_verdict "$d"
  st=$(awk -F"	" "\$1==\"status\"{print \$2; exit}" "$d/result.status")
  rc=$(tr -d "[:space:]" < "$d/result.rc")
  # comprobar que no es sourceable como shell (contiene tabs, no assignments)
  if grep -Eq "^(schema|status)=" "$d/result.status"; then printf "sourced-form"; exit 0; fi
  printf "%s|%s" "$st" "$rc"
' _ "$GOLDEN_ORCH" "$(mktemp -d "${TMPDIR:-/tmp}/pm-t002-persist.XXXXXX")")"
[ "$c_persist" = 'PASS|0' ] && ok "veredicto atomico result.status PASS + result.rc 0" || bad "persist inesperado: $c_persist"

# =============================================================================
# S1 / r1 — C21/C22: dispatch→reduce end-to-end por carril (falla de fase de runner)
# Antes de M1: M1 daba TEST_AND_EVIDENCE_FAILED|124; macdata daba RUNNER_FAILED|74.
# Tras M1: ambos carriles emiten RUNNER_FAILED|124 (analisis.md §4).
# =============================================================================

# C21 M1: leaf real (npm hang → 124 + runner.status test_exit=-1) → classify → reduce
c21_fixture="$(mktemp -d "${TMPDIR:-/tmp}/pm-t002-c21.XXXXXX")"
c21_fake="$c21_fixture/bin"; c21_suite="$c21_fixture/legacy/tests/e2e"; c21_result="$c21_fixture/result"
mkdir -p "$c21_fake" "$c21_suite" "$c21_result" "$c21_suite/node_modules/playwright"
printf '{ "name": "e2e-fixture" }\n' > "$c21_suite/package.json"
printf 'lock\n' > "$c21_suite/package-lock.json"
printf 'export const chromium={executablePath:()=>"/bin/true"}\n' > "$c21_suite/node_modules/playwright/index.js"
cat > "$c21_fake/node" <<'NODE'
#!/bin/sh
if [ "$1" = "--input-type=module" ] || [ "$1" = "--input-type" ]; then exit 0; fi
if [ "$1" = "-p" ]; then printf '20\n'; exit 0; fi
exit 0
NODE
chmod +x "$c21_fake/node"
cat > "$c21_fake/npm" <<'NPM'
#!/bin/sh
sleep 30
exit 0
NPM
chmod +x "$c21_fake/npm"
cat > "$c21_fake/npx" <<'NPX'
#!/bin/sh
exit 0
NPX
chmod +x "$c21_fake/npx"
c21_leaf_rc=0
printf 'user\0pass\0' | env PATH="$c21_fake:/usr/bin:/bin" \
  PM_E2E_GOLDEN_READY=1 \
  PM_E2E_GOLDEN_RUN_ID="c21-m1-run" \
  PM_E2E_GOLDEN_NPM_TIMEOUT_S=1 \
  PM_E2E_GOLDEN_CHROMIUM_TIMEOUT_S=5 \
  PM_E2E_GOLDEN_PLAYWRIGHT_TIMEOUT_S=5 \
  /bin/bash "$GOLDEN_M1" "$c21_fixture/legacy" "$c21_result" "http://fixture-base/" 1 \
  >/dev/null 2>&1 || c21_leaf_rc=$?
c21="$(PM_E2E_GOLDEN_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
  . "$1"
  RESULT_DIR="$2"
  RUN_ID=c21-m1-run
  RUNNER=m1
  SMOKE_RC="$3"
  PREPARE_EXIT=0
  HANDSHAKE_EXPORTED=1
  golden_classify_after_dispatch
  golden_reduce_status
  printf "%s|%s|te=%s|re=%s" "$FINAL_STATUS" "$FINAL_EXIT" "$TEST_EXIT" "$RUNNER_EXIT"
' _ "$GOLDEN_ORCH" "$c21_result" "$c21_leaf_rc")"
case "$c21" in
  RUNNER_FAILED\|124\|te=-1\|re=124)
    ok "C21 M1 dispatch→reduce npm-timeout => RUNNER_FAILED/124 (test_exit=-1)"
    ;;
  *)
    bad "C21 M1 inesperado (leaf_rc=$c21_leaf_rc): $c21"
    ;;
esac
unlink "$c21_fake/node" "$c21_fake/npm" "$c21_fake/npx" 2>/dev/null || true
unlink "$c21_suite/package.json" "$c21_suite/package-lock.json" 2>/dev/null || true
unlink "$c21_suite/node_modules/playwright/index.js" 2>/dev/null || true
rmdir "$c21_suite/node_modules/playwright" "$c21_suite/node_modules" 2>/dev/null || true
find "$c21_result" -type f -print 2>/dev/null | while IFS= read -r f; do unlink "$f" 2>/dev/null || true; done
find "$c21_result" -depth -type d -print 2>/dev/null | while IFS= read -r d; do rmdir "$d" 2>/dev/null || true; done
rmdir "$c21_fake" "$c21_suite" "$c21_fixture/legacy/tests" "$c21_fixture/legacy" "$c21_fixture" 2>/dev/null || true

# C22 macdata: hop real (SSH hang del runner → 124) → classify → reduce
# El hop macdata con hang-runner-ssh sale 124 sin manifiesto completo; el orquestador
# debe emitir RUNNER_FAILED/124 (no 74 ni TEST_AND_EVIDENCE_FAILED).
c22_mac="$(GOLDEN_SIM_SSH_TO=1 golden_mac_sim hang-runner-ssh)"
c22_mac_rc="$(printf '%s' "$c22_mac" | awk -F'@@' '{print $1}')"
c22_dir="$(mktemp -d "${TMPDIR:-/tmp}/pm-t002-c22.XXXXXX")"
# Sin runner.status (caida de transporte SSH antes de materializar evidencia remota)
c22="$(PM_E2E_GOLDEN_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
  . "$1"
  RESULT_DIR="$2"
  RUN_ID=c22-mac-run
  RUNNER=macdata
  SMOKE_RC="$3"
  PREPARE_EXIT=0
  HANDSHAKE_EXPORTED=1
  golden_classify_after_dispatch
  golden_reduce_status
  printf "%s|%s|te=%s|re=%s" "$FINAL_STATUS" "$FINAL_EXIT" "$TEST_EXIT" "$RUNNER_EXIT"
' _ "$GOLDEN_ORCH" "$c22_dir" "$c22_mac_rc")"
case "$c22" in
  RUNNER_FAILED\|124\|te=-1\|re=124)
    ok "C22 macdata dispatch→reduce SSH-timeout => RUNNER_FAILED/124 (test_exit=-1)"
    ;;
  *)
    bad "C22 macdata inesperado (hop_rc=$c22_mac_rc): $c22"
    ;;
esac
rmdir "$c22_dir" 2>/dev/null || true

# C22b macdata: runner.status con test_exit=-1 (npm remoto) + hop rc 124 + evidencia incompleta
c22b_dir="$(mktemp -d "${TMPDIR:-/tmp}/pm-t002-c22b.XXXXXX")"
printf 'schema\tpm-e2e-smoke-golden-runner/v1\nrun_id\tc22b-run\nphase\tnpm-ci\ntest_exit\t-1\nhandshake_exported\t1\n' \
  > "$c22b_dir/runner.status"
c22b="$(PM_E2E_GOLDEN_CONTRACT_SOURCE_ONLY=1 /bin/bash -c '
  . "$1"
  RESULT_DIR="$2"
  RUN_ID=c22b-run
  RUNNER=macdata
  SMOKE_RC=124
  PREPARE_EXIT=0
  HANDSHAKE_EXPORTED=1
  golden_classify_after_dispatch
  golden_reduce_status
  printf "%s|%s|te=%s|re=%s|ee=%s" "$FINAL_STATUS" "$FINAL_EXIT" "$TEST_EXIT" "$RUNNER_EXIT" "$EVIDENCE_EXIT"
' _ "$GOLDEN_ORCH" "$c22b_dir")"
case "$c22b" in
  RUNNER_FAILED\|124\|te=-1\|re=124\|ee=74)
    ok "C22b macdata npm-timeout (status test_exit=-1) => RUNNER_FAILED/124 (no 74)"
    ;;
  *)
    bad "C22b macdata inesperado: $c22b"
    ;;
esac
unlink "$c22b_dir/runner.status" 2>/dev/null || true
rmdir "$c22b_dir" 2>/dev/null || true

# Reductor aislado: RUNNER_EXIT propaga 124 (regresion de la rama RUNNER_FAILED)
c_rf="$(golden_source '
  PREPARE_EXIT=0; TEST_EXIT=-1; RUNNER_EXIT=124; EVIDENCE_EXIT=74; EVIDENCE_COMPLETE=0; HANDSHAKE_EXPORTED=1
  golden_reduce_status; printf "%s|%s" "$FINAL_STATUS" "$FINAL_EXIT"
')"
[ "$c_rf" = 'RUNNER_FAILED|124' ] && ok "reductor RUNNER_FAILED propaga RUNNER_EXIT=124 (no EVIDENCE_EXIT)" \
  || bad "reductor RUNNER_FAILED inesperado: $c_rf"

printf '\nContrato I13+T002: %s PASS / %s FAIL\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
