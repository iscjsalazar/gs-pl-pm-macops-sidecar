#!/usr/bin/env bash
# Contratos herméticos de RCSI del slot (T-010, D14): no abre SSH, Docker, macdata ni un slot real.
# Verifica por lectura estática que el provisioning de pm_planning_wt<N> alinea READ_COMMITTED_SNAPSHOT /
# ALLOW_SNAPSHOT_ISOLATION con Azure SQL dev/prod, en el punto del pipeline y con las guardas que el análisis
# cerró (fail-closed, sesión única, sin NOLOCK/Skip).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WT="$ROOT/lib/worktrees.sh"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }

# --- la funcion ensure existe ---
grep -q '^wt_ensure_planning_rcsi() {' "$WT" && ok "wt_ensure_planning_rcsi definida" || bad "wt_ensure_planning_rcsi definida"

# Cuerpo de la funcion, aislado (desde su firma hasta el '}' de columna 0 que la cierra) para acotar los
# checks de contenido a ESTE delta y no a todo el archivo (p.ej. el check de ausencia de NOLOCK).
FN_BODY="$(sed -n '/^wt_ensure_planning_rcsi() {/,/^}/p' "$WT")"
[ -n "$FN_BODY" ] && ok "cuerpo de wt_ensure_planning_rcsi extraido" || bad "cuerpo de wt_ensure_planning_rcsi extraido"

# --- activa y verifica el flag real (no un literal de conveniencia) ---
printf '%s\n' "$FN_BODY" | grep -q 'SET READ_COMMITTED_SNAPSHOT ON' && ok "activa READ_COMMITTED_SNAPSHOT ON" || bad "activa READ_COMMITTED_SNAPSHOT ON"
printf '%s\n' "$FN_BODY" | grep -q 'SET ALLOW_SNAPSHOT_ISOLATION ON' && ok "activa ALLOW_SNAPSHOT_ISOLATION ON" || bad "activa ALLOW_SNAPSHOT_ISOLATION ON"
printf '%s\n' "$FN_BODY" | grep -q 'is_read_committed_snapshot_on' && ok "lee is_read_committed_snapshot_on" || bad "lee is_read_committed_snapshot_on"

# --- shell CREATE DATABASE IF NOT EXISTS (D-T010-3) ---
printf '%s\n' "$FN_BODY" | grep -q "IF DB_ID(N'\$PM_PLANNING_DB') IS NULL" && ok "CREATE DATABASE solo si falta" || bad "CREATE DATABASE solo si falta"

# --- idempotencia: SINGLE_USER solo cuando el flag esta OFF (no incondicional) ---
printf '%s\n' "$FN_BODY" | grep -qE 'is_read_committed_snapshot_on = 0' && ok "guarda RCSI OFF antes de mutar (net-cero si ya ON)" || bad "guarda RCSI OFF antes de mutar (net-cero si ya ON)"
printf '%s\n' "$FN_BODY" | grep -q 'SET SINGLE_USER WITH ROLLBACK IMMEDIATE' && ok "sesion unica via SINGLE_USER WITH ROLLBACK IMMEDIATE" || bad "sesion unica via SINGLE_USER WITH ROLLBACK IMMEDIATE"
printf '%s\n' "$FN_BODY" | grep -q 'SET MULTI_USER' && ok "restaura MULTI_USER en el mismo batch" || bad "restaura MULTI_USER en el mismo batch"

# --- ASI tambien es condicional (no exige exclusividad, pero tampoco se re-ejecuta sin necesidad) ---
printf '%s\n' "$FN_BODY" | grep -qE "snapshot_isolation_state_desc <> N'ON'" && ok "ASI condicional por estado" || bad "ASI condicional por estado"

# --- fail-closed: relectura post-ALTER + aborto si no confirma ON ---
printf '%s\n' "$FN_BODY" | grep -q 'wt_die' && ok "fail-closed: wt_die si la relectura no confirma ON" || bad "fail-closed: wt_die si la relectura no confirma ON"
printf '%s\n' "$FN_BODY" | grep -qE 'rcsi.*=.*1|"\$rcsi" = "1"' && ok "condiciona el exito a la relectura ON" || bad "condiciona el exito a la relectura ON"

# --- prohibido band-aid de contencion en el delta (D14/D-T010-7) ---
printf '%s\n' "$FN_BODY" | grep -qiE 'nolock|readuncommitted' && bad "NOLOCK/READUNCOMMITTED prohibido en el ensure" || ok "sin NOLOCK/READUNCOMMITTED en el ensure"

# --- corre contra master: ni wt_shared_exec ni wt_shared_scalar reciben '-d' a la planning en esta funcion ---
printf '%s\n' "$FN_BODY" | grep -E 'wt_shared_(exec|scalar)' | grep -q -- '-d ' && bad "el ensure NO debe fijar -d (corre contra master)" || ok "el ensure corre contra master (sin -d)"

# --- enganche en _cmd_wt_up_locked: invocada, y ANTES de wt_up_api ---
UP_BODY="$(sed -n '/^_cmd_wt_up_locked() {/,/^}/p' "$WT")"
[ -n "$UP_BODY" ] && ok "cuerpo de _cmd_wt_up_locked extraido" || bad "cuerpo de _cmd_wt_up_locked extraido"
printf '%s\n' "$UP_BODY" | grep -q 'wt_ensure_planning_rcsi "\$pw"' && ok "_cmd_wt_up_locked invoca wt_ensure_planning_rcsi" || bad "_cmd_wt_up_locked invoca wt_ensure_planning_rcsi"

rcsi_line="$(printf '%s\n' "$UP_BODY" | grep -n 'wt_ensure_planning_rcsi "\$pw"' | head -1 | cut -d: -f1)"
api_line="$(printf '%s\n' "$UP_BODY" | grep -n 'wt_up_api "\$pw" || return 1' | head -1 | cut -d: -f1)"
if [ -n "$rcsi_line" ] && [ -n "$api_line" ] && [ "$rcsi_line" -lt "$api_line" ]; then
  ok "wt_ensure_planning_rcsi corre ANTES de wt_up_api"
else
  bad "wt_ensure_planning_rcsi corre ANTES de wt_up_api (rcsi_line=${rcsi_line:-?} api_line=${api_line:-?})"
fi

# --- preflight: la API del slot se retira ANTES del ensure (sesion unica; D-T010-3) ---
prestop_line="$(printf '%s\n' "$UP_BODY" | grep -n "docker \$(remote_docker_ctx) rm -f 'pm-wt\${WT_SLOT}-api'" | head -1 | cut -d: -f1)"
if [ -n "$prestop_line" ] && [ -n "$rcsi_line" ] && [ "$prestop_line" -lt "$rcsi_line" ]; then
  ok "preflight retira el contenedor API del slot ANTES del ensure de RCSI"
else
  bad "preflight retira el contenedor API del slot ANTES del ensure de RCSI (prestop_line=${prestop_line:-?} rcsi_line=${rcsi_line:-?})"
fi

# --- alcance: solo pm_planning_wt<N> (PM_PLANNING_DB), no LN ni Nucleos ---
printf '%s\n' "$FN_BODY" | grep -q '\$PM_PLANNING_DB' && ok "opera sobre PM_PLANNING_DB (planning del slot)" || bad "opera sobre PM_PLANNING_DB (planning del slot)"
printf '%s\n' "$FN_BODY" | grep -qE 'PM_WT_LN_DB|PM_NUCLEOS_DB' && bad "el ensure NO debe tocar LN/Nucleos (fuera de alcance)" || ok "el ensure no toca LN/Nucleos"

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
