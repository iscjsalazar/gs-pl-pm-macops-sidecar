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

# --- C2 (T-012): orden relativo estricto SINGLE_USER -> RCSI ON -> MULTI_USER DENTRO del mismo
#     bloque BEGIN...END condicionado (is_read_committed_snapshot_on = 0). Hallazgo C2 del TL + S2 r1:
#     un MULTI_USER movido antes del ALTER de RCSI, o fuera del batch (siempre, no solo cuando el
#     flag estaba OFF), pasaba el check viejo (solo presencia/orden global en FN_BODY). ---
# Extrae el BEGIN...END que sigue al guard RCSI-OFF (no el de ASI ni otros bloques).
RCSI_BATCH="$(printf '%s\n' "$FN_BODY" | awk '
  /is_read_committed_snapshot_on = 0/ { interested=1 }
  interested && /BEGIN/ { collecting=1; buf=$0; next }
  collecting {
    buf = buf "\n" $0
    if ($0 ~ /^[[:space:]]*END[[:space:]]*$/) {
      if (buf ~ /SET SINGLE_USER WITH ROLLBACK IMMEDIATE/) { print buf; exit }
      collecting=0; interested=0; buf=""
    }
  }
')"
[ -n "$RCSI_BATCH" ] && ok "batch condicionado RCSI-OFF (BEGIN...END con SINGLE_USER) extraido" || bad "batch condicionado RCSI-OFF (BEGIN...END con SINGLE_USER) extraido"
single_user_line="$(printf '%s\n' "$RCSI_BATCH" | grep -n 'SET SINGLE_USER WITH ROLLBACK IMMEDIATE' | head -1 | cut -d: -f1)"
rcsi_on_line="$(printf '%s\n' "$RCSI_BATCH" | grep -n 'SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE' | head -1 | cut -d: -f1)"
multi_user_line="$(printf '%s\n' "$RCSI_BATCH" | grep -n 'SET MULTI_USER' | head -1 | cut -d: -f1)"
if [ -n "$single_user_line" ] && [ -n "$rcsi_on_line" ] && [ -n "$multi_user_line" ] \
  && [ "$single_user_line" -lt "$rcsi_on_line" ] && [ "$rcsi_on_line" -lt "$multi_user_line" ]; then
  ok "restaura MULTI_USER en orden DENTRO del batch: SINGLE_USER -> RCSI ON -> MULTI_USER"
else
  bad "restaura MULTI_USER en orden DENTRO del batch: SINGLE_USER -> RCSI ON -> MULTI_USER (single=${single_user_line:-?} rcsi_on=${rcsi_on_line:-?} multi=${multi_user_line:-?}; si multi=? esta fuera del BEGIN...END)"
fi

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

# --- C1 (T-012): auto-sane de un SINGLE_USER colgado documentado en el comentario de cabecera ---
# Comentario de cabecera = SOLO las lineas contiguas que empiezan con '#' inmediatamente antes de
# la firma de la funcion (S1 r1: el awk previo acumulaba desde L1 del archivo hasta la firma —
# ~663 lineas — y no aislaba la cabecera real).
HEADER_BODY="$(awk '
  {
    if ($0 ~ /^#/) {
      if (in_comments) comments = comments "\n" $0
      else { comments = $0; in_comments = 1 }
    } else if ($0 ~ /^wt_ensure_planning_rcsi\(\) \{/) {
      print comments
      exit
    } else {
      comments = ""
      in_comments = 0
    }
  }
' "$WT")"
[ -n "$HEADER_BODY" ] && ok "cabecera contigua de wt_ensure_planning_rcsi extraida" || bad "cabecera contigua de wt_ensure_planning_rcsi extraida"
printf '%s\n' "$HEADER_BODY" | grep -qiE 'auto-sane' && ok "cabecera documenta el auto-sane (C1)" || bad "cabecera documenta el auto-sane (C1)"
printf '%s\n' "$HEADER_BODY" | grep -qiE 'colgad[oa]' && ok "cabecera describe el escenario de SINGLE_USER colgado" || bad "cabecera describe el escenario de SINGLE_USER colgado"
printf '%s\n' "$HEADER_BODY" | grep -qiE 'siguiente wt-up' && ok "cabecera indica que el siguiente wt-up repara (sin ALTER manual)" || bad "cabecera indica que el siguiente wt-up repara (sin ALTER manual)"

# --- S1 (T-012/D63): wt_require_planning_rcsi existe, es SOLO LECTURA (nunca ALTER) y aborta con wt_die ---
grep -q '^wt_require_planning_rcsi() {' "$WT" && ok "wt_require_planning_rcsi definida" || bad "wt_require_planning_rcsi definida"
REQ_BODY="$(sed -n '/^wt_require_planning_rcsi() {/,/^}/p' "$WT")"
[ -n "$REQ_BODY" ] && ok "cuerpo de wt_require_planning_rcsi extraido" || bad "cuerpo de wt_require_planning_rcsi extraido"
printf '%s\n' "$REQ_BODY" | grep -qi 'ALTER' && bad "wt_require_planning_rcsi NO debe emitir ALTER (solo lectura; romperia el reuso WARM)" || ok "wt_require_planning_rcsi es solo lectura (sin ALTER)"
printf '%s\n' "$REQ_BODY" | grep -q 'is_read_committed_snapshot_on' && ok "wt_require_planning_rcsi relee is_read_committed_snapshot_on" || bad "wt_require_planning_rcsi relee is_read_committed_snapshot_on"
printf '%s\n' "$REQ_BODY" | grep -q 'wt_die' && ok "wt_require_planning_rcsi aborta con wt_die si no confirma ON" || bad "wt_require_planning_rcsi aborta con wt_die si no confirma ON"

# --- S1: enganche en pm_gate_run_integration_physical (rama WARM reuso), ANTES de pm_ef_migrate ---
UMD="$ROOT/lib/unit-macdata.sh"
[ -f "$UMD" ] && ok "unit-macdata.sh exists (para el enganche warm)" || bad "unit-macdata.sh exists (para el enganche warm)"
GATE_BODY="$(sed -n '/^pm_gate_run_integration_physical() {/,/^}/p' "$UMD")"
[ -n "$GATE_BODY" ] && ok "cuerpo de pm_gate_run_integration_physical extraido" || bad "cuerpo de pm_gate_run_integration_physical extraido"
printf '%s\n' "$GATE_BODY" | grep -q 'wt_require_planning_rcsi "\$pw"' && ok "pm_gate_run_integration_physical invoca wt_require_planning_rcsi en WARM" || bad "pm_gate_run_integration_physical invoca wt_require_planning_rcsi en WARM"
require_line="$(printf '%s\n' "$GATE_BODY" | grep -n 'wt_require_planning_rcsi "\$pw"' | head -1 | cut -d: -f1)"
migrate_line="$(printf '%s\n' "$GATE_BODY" | grep -n 'pm_ef_migrate' | head -1 | cut -d: -f1)"
if [ -n "$require_line" ] && [ -n "$migrate_line" ] && [ "$require_line" -lt "$migrate_line" ]; then
  ok "wt_require_planning_rcsi corre ANTES de pm_ef_migrate en la rama warm"
else
  bad "wt_require_planning_rcsi corre ANTES de pm_ef_migrate en la rama warm (require=${require_line:-?} migrate=${migrate_line:-?})"
fi

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
