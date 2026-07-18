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

printf '\nContrato I13: %s PASS / %s FAIL\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
