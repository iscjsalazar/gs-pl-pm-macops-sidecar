#!/usr/bin/env bash
# Contrato hermetico T-701: FORCE no reclama slots ajenos; PM_WT_GC_FORCE si; el legado
# sigue forzandose. Observa efectos (registro falso + logs de dobles), no exit code ni grep
# de Makefile. No abre SSH, Docker, el registro real ni slots vivos.
# Compatible con Bash 3.2.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
REAL_REGISTRY="/Users/jsm1x/dev-prjs/programa-maestro/pm-cc-wrapper/gs-pl-pm-macops-sidecar/.worktrees/slots.tsv"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }

unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES || true
unset FORCE PM_WT_GC_FORCE PM_E2E_FORCE PM_LEGACY_FORCE || true

[ -f "$ROOT/Makefile" ] && [ -f "$ROOT/lib/worktrees.sh" ] && [ -f "$ROOT/scripts/e2e.sh" ] \
  || { echo "faltan fuentes del sidecar en $ROOT" >&2; exit 2; }

STALE_HB="$(TZ=UTC date -u -v-2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || TZ=UTC date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
CREATED_OLD="$(TZ=UTC date -u -v-3H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || TZ=UTC date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
DEAD_PID=99999999
FOREIGN_FOLDER="other-session"
REQUEST_FOLDER="fixture-pm"

count_lines() {
  [ -f "$1" ] || { printf '0'; return 0; }
  awk 'END{print NR+0}' "$1"
}

foreign_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$FOREIGN_FOLDER" "0" "pm-wt0" "0" "$CREATED_OLD" "$DEAD_PID" "$STALE_HB"
}

write_sentinels() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/sentinel" <<'EOF'
#!/bin/sh
printf '%s\t%s\n' "$(basename "$0")" "$*" >> "${PM_T701_EVENTS}/forbidden.tsv"
exit 97
EOF
  chmod +x "$bin/sentinel"
  local n
  for n in ssh docker rsync curl scp colima; do
    cp "$bin/sentinel" "$bin/$n"
    chmod +x "$bin/$n"
  done
}

write_shadow_wt() {
  local dest="$1"
  cat > "$dest" <<'EOF'
#!/usr/bin/env bash
# Doble de wt.sh: sourcea el cmd_wt_up real y dobla solo planos externos.
set -euo pipefail

: "${PM_T701_TEST_ROOT:?}"
: "${PM_T701_WRAPPER:?}"
: "${PM_T701_REGISTRY:?}"
: "${PM_T701_EVENTS:?}"
: "${PM_T701_SIDECAR_ROOT:?}"
: "${PM_T701_ENV_FILE:?}"

T701_REAL_REGISTRY="/Users/jsm1x/dev-prjs/programa-maestro/pm-cc-wrapper/gs-pl-pm-macops-sidecar/.worktrees/slots.tsv"

t701_symlink_under_root() {
  local root_phys input current rest part old_ifs
  root_phys="$(cd "$1" && pwd -P)" || return 0
  [ -e "$2" ] || [ -L "$2" ] || [ -d "$(dirname "$2")" ] || return 0
  if [ -d "$2" ]; then
    input="$(cd "$2" && pwd -P)" || return 0
  else
    input="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")" || return 0
  fi
  case "$input" in
    "$root_phys") return 1 ;;
    "$root_phys"/*) ;;
    *) return 0 ;;
  esac
  rest="${input#$root_phys/}"
  current="$root_phys"
  old_ifs="$IFS"; IFS=/
  # shellcheck disable=SC2086
  set -- $rest
  IFS="$old_ifs"
  for part in "$@"; do
    [ -n "$part" ] || continue
    current="$current/$part"
    [ -L "$current" ] && return 0
  done
  return 1
}

t701_guard_registry() {
  local got want root_phys phys
  got="${PM_WT_REGISTRY:-}"
  want="${PM_T701_REGISTRY:-}"
  [ -n "$got" ] && [ -n "$want" ] || return 97
  [ "$got" != "$T701_REAL_REGISTRY" ] || return 97
  [ "$got" = "$want" ] || return 97
  root_phys="$(cd "${PM_T701_TEST_ROOT}" && pwd -P)" || return 97
  t701_symlink_under_root "$PM_T701_TEST_ROOT" "$got" && return 97
  t701_symlink_under_root "$PM_T701_TEST_ROOT" "$want" && return 97
  [ -d "$(dirname "$got")" ] || return 97
  phys="$(cd "$(dirname "$got")" && pwd -P)/$(basename "$got")" || return 97
  case "$phys" in
    "$root_phys"/*) ;;
    *) return 97 ;;
  esac
  [ "$phys" != "$T701_REAL_REGISTRY" ] || return 97
  return 0
}

if [ "${PM_T701_GUARD_PROBE:-0}" = 1 ]; then
  PM_WT_REGISTRY="$T701_REAL_REGISTRY"
  t701_guard_registry
  exit $?
fi

export PM_WRAPPER_DIR="$PM_T701_WRAPPER"
export PM_WT_REGISTRY="$PM_T701_REGISTRY"
export PM_ENV_FILE="$PM_T701_ENV_FILE"

t701_guard_registry || exit 97

# shellcheck disable=SC1090
. "$PM_T701_SIDECAR_ROOT/lib/common.sh"

pm_path_contains_symlink() {
  t701_symlink_under_root "$PM_T701_TEST_ROOT" "$1"
}

wrap_phys="$(cd "$WRAPPER_DIR" && pwd -P)" || exit 97
want_wrap="$(cd "$PM_T701_WRAPPER" && pwd -P)" || exit 97
root_phys="$(cd "$PM_T701_TEST_ROOT" && pwd -P)" || exit 97
[ "$wrap_phys" = "$want_wrap" ] || exit 97
case "$wrap_phys" in
  "$root_phys"/*) ;;
  *) exit 97 ;;
esac
[ "$PM_WT_REGISTRY" = "$PM_T701_REGISTRY" ] || exit 97
t701_guard_registry || exit 97

# shellcheck disable=SC1090
. "$PM_T701_SIDECAR_ROOT/lib/worktrees.sh"

eval "$(declare -f wt_lock | sed '1s/^wt_lock/_orig_wt_lock/')"

wt_lock() {
  local name="$1"; shift
  t701_guard_registry || return 97
  if [ "${1:-}" = "_cmd_wt_up_locked" ]; then
    return 0
  fi
  _orig_wt_lock "$name" "$@"
}

_cmd_wt_up_locked() {
  printf '_cmd_wt_up_locked\t%s\t%s\n' "${1:-}" "${2:-}" >> "$PM_T701_EVENTS/forbidden.tsv"
  return 97
}

_wt_reclaim_slot() {
  local slot="$1" folder="$2"
  t701_guard_registry || return 97
  printf '%s\t%s\n' "$slot" "$folder" >> "$PM_T701_EVENTS/reclaim.tsv"
  wt_registry_lock wt_slot_release "$folder"
}

wt_disk_gate() { return 0; }
wt_mem_gate() { return 0; }
wt_probe_live_slots() { WT_LIVE_SLOTS=""; WT_LIVE_SLOTS_OK=0; return 0; }

on_intel() {
  printf 'on_intel\t%s\n' "$*" >> "$PM_T701_EVENTS/forbidden.tsv"
  return 97
}
ssh() {
  printf 'ssh\t%s\n' "$*" >> "$PM_T701_EVENTS/forbidden.tsv"
  return 97
}
docker() {
  printf 'docker\t%s\n' "$*" >> "$PM_T701_EVENTS/forbidden.tsv"
  return 97
}
rsync() {
  printf 'rsync\t%s\n' "$*" >> "$PM_T701_EVENTS/forbidden.tsv"
  return 97
}
curl() {
  printf 'curl\t%s\n' "$*" >> "$PM_T701_EVENTS/forbidden.tsv"
  return 97
}

load_env
[ "$PM_WT_REGISTRY" = "$PM_T701_REGISTRY" ] || exit 97
t701_guard_registry || exit 97

case "${1:-}" in
  up) cmd_wt_up ;;
  *) echo "uso: $0 up" >&2; exit 2 ;;
esac
EOF
  chmod +x "$dest"
}

write_shadow_legacy() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
# Doble observable de legacy.sh: registra verbo y PM_LEGACY_FORCE. No sourcea el driver real.
set -u
: "${PM_T701_EVENTS:?}"
printf '%s\t%s\n' "${1:-}" "${PM_LEGACY_FORCE-}" >> "$PM_T701_EVENTS/legacy.tsv"
exit 0
EOF
  chmod +x "$1"
}

write_shadow_e2e() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
# Driver de frontera de e2e-up: submake wt-up real del shadow + e2e_legacy_launch real.
set -u
SHADOW="$(cd "$(dirname "$0")/.." && pwd -P)"
: "${PM_T701_SIDECAR_ROOT:?}"
: "${PM_T701_WRAPPER:?}"
: "${WT:?}"

make -C "$SHADOW" wt-up WT="$WT" ORACLE=1 || exit $?

export PM_E2E_CONTRACT_SOURCE_ONLY=1
export PM_WRAPPER_DIR="$PM_T701_WRAPPER"
# shellcheck disable=SC1090
. "$PM_T701_SIDECAR_ROOT/scripts/e2e.sh"

BASE_DIR="$SHADOW"
BACKEND_URL="${BACKEND_URL:-http://127.0.0.1:9}"
SQL_PM_HOST="${SQL_PM_HOST:-127.0.0.1,9}"
PM_PLANNING_DB="${PM_PLANNING_DB:-pm_planning_wt1}"
E2E_SQL_PW="${E2E_SQL_PW:-x}"
LEGACY_SRC="${PM_E2E_LEGACY_SRC:-$SHADOW/legacy-src}"
E2E_SLOT="${E2E_SLOT:-1}"
SITEPORT="${SITEPORT:-8101}"
TUNNEL="${TUNNEL:-18101}"
E2E_ORACLE_PORT="${E2E_ORACLE_PORT:-15211}"
PM_GUEST_GATEWAY="${PM_GUEST_GATEWAY:-172.16.128.1}"

e2e_legacy_launch
EOF
  chmod +x "$1"
}

setup_sandbox() {
  local mutant="${1:-}"
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/t701-force-reclaim.XXXXXX")"
  SHADOW="$SANDBOX/shadow-sidecar"
  WRAPPER="$SANDBOX/wrapper"
  EVENTS="$SANDBOX/events"
  REG="$WRAPPER/gs-pl-pm-macops-sidecar/.worktrees/slots.tsv"
  ENVFILE="$SANDBOX/sandbox.env"
  mkdir -p "$SHADOW/scripts" "$WRAPPER/gs-pl-pm-macops-sidecar/.worktrees" \
    "$WRAPPER/worktrees/$REQUEST_FOLDER" "$EVENTS" "$SHADOW/legacy-src" "$SANDBOX/bin"
  : > "$WRAPPER/worktrees/$REQUEST_FOLDER/PL.PM.sln"
  : > "$SHADOW/legacy-src/ProgramaMaestroPT.sln"
  : > "$ENVFILE"
  : > "$EVENTS/reclaim.tsv"
  : > "$EVENTS/legacy.tsv"
  : > "$EVENTS/forbidden.tsv"
  FOREIGN_LINE="$(foreign_row)"
  FOREIGN_LINE="${FOREIGN_LINE%$'\n'}"
  printf '%s\n' "$FOREIGN_LINE" > "$REG"
  BEFORE_REG="$(cat "$REG")"
  cp "$ROOT/Makefile" "$SHADOW/Makefile"
  if [ "$mutant" = "DROP_LEGACY_FORCE" ]; then
    awk '
      {
        gsub(/PM_E2E_FORCE=\$\(FORCE\)/, "PM_E2E_FORCE=0")
        print
      }
    ' "$ROOT/Makefile" > "$SHADOW/Makefile"
  fi
  write_shadow_wt "$SHADOW/wt.sh"
  write_shadow_legacy "$SHADOW/legacy.sh"
  write_shadow_e2e "$SHADOW/scripts/e2e.sh"
  write_sentinels "$SANDBOX/bin"
  export PM_T701_TEST_ROOT="$SANDBOX"
  export PM_T701_WRAPPER="$WRAPPER"
  export PM_T701_REGISTRY="$REG"
  export PM_T701_EVENTS="$EVENTS"
  export PM_T701_SIDECAR_ROOT="$ROOT"
  export PM_T701_ENV_FILE="$ENVFILE"
  export PATH="$SANDBOX/bin:$PATH"
}

registry_slot_for() {
  awk -F'\t' -v f="$1" '$1==f{print $2; exit}' "$REG"
}

registry_has_exact() {
  awk -v line="$1" 'BEGIN{ok=0} $0==line{ok=1} END{exit ok?0:1}' "$REG"
}

run_e2e_up() {
  local force="$1" gc="$2"
  local out rc
  rc=0
  out="$(
    cd "$SHADOW" && make e2e-up \
      WT="$REQUEST_FOLDER" \
      FORCE="$force" \
      PM_WT_GC_FORCE="$gc" \
      WRAPPER="$WRAPPER" \
      SLOTS=2 \
      2>&1
  )" || rc=$?
  MAKE_OUT="$out"
  MAKE_RC="$rc"
  printf '%s\n' "$out" > "$SANDBOX/make.log"
}

assert_empty_forbidden() {
  local n
  n="$(count_lines "$EVENTS/forbidden.tsv")"
  if [ "$n" = "0" ]; then
    ok "$1: events/forbidden.tsv vacio"
  else
    bad "$1: events/forbidden.tsv vacio (lineas=$n: $(tr '\n' '|' < "$EVENTS/forbidden.tsv"))"
  fi
}

assert_registry_is_fixture() {
  local label="$1"
  if [ "$PM_T701_REGISTRY" = "$REG" ] && [ "$REG" != "$REAL_REGISTRY" ]; then
    ok "$label: PM_WT_REGISTRY es el fixture"
  else
    bad "$label: PM_WT_REGISTRY es el fixture (reg=$REG real=$REAL_REGISTRY)"
  fi
  case "$REG" in
    "$SANDBOX"/*) ok "$label: registro fisico bajo el sandbox" ;;
    *) bad "$label: registro fisico bajo el sandbox ($REG)" ;;
  esac
}

# --- G: el guard rehúsa el registro real sin abrirlo ---
setup_sandbox
probe_out="$(cd "$SHADOW" && PM_T701_GUARD_PROBE=1 ./wt.sh up 2>&1)" || probe_rc=$?
probe_rc="${probe_rc:-0}"
if [ "$probe_rc" = "97" ]; then
  ok "G: guard rehúsa el path del registro real (rc=97)"
else
  bad "G: guard rehúsa el path del registro real (rc=$probe_rc out=$probe_out)"
fi
assert_empty_forbidden "G"

# --- R1: FORCE=1 no reclama ---
setup_sandbox
run_e2e_up 1 0
n_reclaim="$(count_lines "$EVENTS/reclaim.tsv")"
req_slot="$(registry_slot_for "$REQUEST_FOLDER")"
if [ "$n_reclaim" = "0" ]; then
  ok "R1: FORCE=1 no llama teardown (reclaim.tsv vacio)"
else
  bad "R1: FORCE=1 no llama teardown (reclaim.tsv lineas=$n_reclaim: $(tr '\n' '|' < "$EVENTS/reclaim.tsv"))"
fi
if registry_has_exact "$FOREIGN_LINE"; then
  ok "R1: la fila ajena conserva sus siete columnas"
else
  bad "R1: la fila ajena conserva sus siete columnas (antes=$(printf '%s' "$BEFORE_REG" | tr '\t' '|') despues=$(tr '\t' '|' < "$REG"))"
fi
if [ "$req_slot" = "1" ]; then
  ok "R1: el solicitante recibe el slot libre 1"
else
  bad "R1: el solicitante recibe el slot libre 1 (slot=${req_slot:-vacio} rc=$MAKE_RC)"
fi
assert_empty_forbidden "R1"
assert_registry_is_fixture "R1"

# --- R2a: PM_WT_GC_FORCE=1 si reclama ---
setup_sandbox
run_e2e_up 0 1
n_reclaim="$(count_lines "$EVENTS/reclaim.tsv")"
req_slot="$(registry_slot_for "$REQUEST_FOLDER")"
foreign_now="$(registry_slot_for "$FOREIGN_FOLDER")"
if [ "$n_reclaim" = "1" ] && awk -F'\t' '$1=="0" && $2=="other-session"{found=1} END{exit found?0:1}' "$EVENTS/reclaim.tsv"; then
  ok "R2a: PM_WT_GC_FORCE=1 produce exactamente un teardown de la fila ajena"
else
  bad "R2a: PM_WT_GC_FORCE=1 produce exactamente un teardown de la fila ajena (lineas=$n_reclaim contenido=$(tr '\n' '|' < "$EVENTS/reclaim.tsv"))"
fi
if [ -z "$foreign_now" ]; then
  ok "R2a: la fila ajena desaparece del registro falso"
else
  bad "R2a: la fila ajena desaparece del registro falso (slot=$foreign_now)"
fi
if [ "$req_slot" = "0" ]; then
  ok "R2a: el solicitante recibe el slot 0 liberado"
else
  bad "R2a: el solicitante recibe el slot 0 liberado (slot=${req_slot:-vacio} rc=$MAKE_RC)"
fi
assert_empty_forbidden "R2a"

# --- R2b: control causal PM_WT_GC_FORCE=0 no reclama ---
setup_sandbox
run_e2e_up 0 0
n_reclaim="$(count_lines "$EVENTS/reclaim.tsv")"
req_slot="$(registry_slot_for "$REQUEST_FOLDER")"
if [ "$n_reclaim" = "0" ]; then
  ok "R2b: PM_WT_GC_FORCE=0 no llama teardown"
else
  bad "R2b: PM_WT_GC_FORCE=0 no llama teardown (lineas=$n_reclaim: $(tr '\n' '|' < "$EVENTS/reclaim.tsv"))"
fi
if registry_has_exact "$FOREIGN_LINE"; then
  ok "R2b: la fila ajena se conserva (unica diferencia: PM_WT_GC_FORCE)"
else
  bad "R2b: la fila ajena se conserva (despues=$(tr '\t' '|' < "$REG"))"
fi
if [ "$req_slot" = "1" ]; then
  ok "R2b: el solicitante recibe el slot libre 1"
else
  bad "R2b: el solicitante recibe el slot libre 1 (slot=${req_slot:-vacio})"
fi
assert_empty_forbidden "R2b"

# --- R3: FORCE=1 sigue forzando el legado y no reclama ---
setup_sandbox
run_e2e_up 1 0
n_reclaim="$(count_lines "$EVENTS/reclaim.tsv")"
n_legacy="$(count_lines "$EVENTS/legacy.tsv")"
legacy_force="$(awk -F'\t' '$1=="launch"{print $2; exit}' "$EVENTS/legacy.tsv")"
if [ "$n_legacy" = "1" ] && [ "$legacy_force" = "1" ]; then
  ok "R3: legacy.sh recibe exactamente un launch con PM_LEGACY_FORCE=1"
else
  bad "R3: legacy.sh recibe exactamente un launch con PM_LEGACY_FORCE=1 (lineas=$n_legacy force=${legacy_force:-vacio} contenido=$(tr '\n' '|' < "$EVENTS/legacy.tsv"))"
fi
if [ "$n_reclaim" = "0" ]; then
  ok "R3: el mismo FORCE=1 no produce teardown"
else
  bad "R3: el mismo FORCE=1 no produce teardown (lineas=$n_reclaim)"
fi
assert_empty_forbidden "R3"

# --- R3 mutante: DROP_LEGACY_FORCE hace fallar la observacion de PM_LEGACY_FORCE=1 ---
setup_sandbox DROP_LEGACY_FORCE
run_e2e_up 1 0
legacy_force="$(awk -F'\t' '$1=="launch"{print $2; exit}' "$EVENTS/legacy.tsv")"
if [ "$legacy_force" = "0" ]; then
  ok "R3-mutante: DROP_LEGACY_FORCE registra PM_LEGACY_FORCE=0 (observacion causal)"
else
  bad "R3-mutante: DROP_LEGACY_FORCE registra PM_LEGACY_FORCE=0 (force=${legacy_force:-vacio} contenido=$(tr '\n' '|' < "$EVENTS/legacy.tsv"))"
fi
assert_empty_forbidden "R3-mutante"

echo "----"
echo "PASS=$pass FAIL=$fail"
echo "SANDBOX_LAST=$SANDBOX"
[ "$fail" -eq 0 ]
