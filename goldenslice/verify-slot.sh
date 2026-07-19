#!/usr/bin/env bash
# Verifica la golden slice cargada en un slot: conteos Oracle (owners) + packages INVALID + conteos LN aislada.
set -eo pipefail
: "${PM_TARGET:=intel}" ; : "${PM_REMOTE_SSH:=macdata}" ; : "${PM_REMOTE_DOCKER_CONTEXT:=}"
export PM_TARGET PM_REMOTE_SSH PM_REMOTE_DOCKER_CONTEXT
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SIDECAR_DIR="$(cd "$SELF_DIR/.." && pwd)"
. "$SIDECAR_DIR/lib/common.sh"
. "$SIDECAR_DIR/lib/worktrees.sh"
load_env
SLOT="${SLOT:?falta SLOT=<N>}"
wt_derive "$SLOT"
ctx="$(remote_docker_ctx)"; OH="$PM_WT_ORACLE_HOME"; ORA_C="$WT_ORACLE_CONTAINER"
LN_DB="${PM_WT_LN_DB_GS:-pm_gs_ln_wt${SLOT}}"

ora(){ on_intel "docker $ctx exec -i -e ORACLE_HOME='$OH' '$ORA_C' bash -c 'export PATH=\$ORACLE_HOME/bin:\$PATH; sqlplus -S system/oracle@localhost:1521/XE'" 2>/dev/null | tr -d '\r'; }

echo "== Oracle PGE_CTRLPISO (slot $SLOT) =="
printf "set head off pages 0 feed off lines 200\n%s\n" \
"select rpad(t,26)||n from (
  select 'TIPGE950' t, count(*) n from PGE_CTRLPISO.TIPGE950 union all
  select 'PLAN_MAESTRO', count(*) from PGE_CTRLPISO.PLAN_MAESTRO union all
  select 'TIPGE021', count(*) from PGE_CTRLPISO.TIPGE021 union all
  select 'REF_ORDEN_FAB_LN', count(*) from PGE_CTRLPISO.REF_ORDEN_FAB_LN union all
  select 'ORDENES', count(*) from PGE_CTRLPISO.ORDENES union all
  select 'INFODIS', count(*) from PGE_CTRLPISO.INFODIS union all
  select 'BACKLOG_T', count(*) from PGE_CTRLPISO.BACKLOG_T
);" | ora | grep -vE '^\s*$'
echo "== packages/objetos INVALID en PGE_CTRLPISO (esperado: recompilan) =="
printf "set head off pages 0 feed off\nselect count(*)||' INVALID' from all_objects where owner='PGE_CTRLPISO' and status='INVALID';\n" | ora | grep -vE '^\s*$'

echo "== LN pm_gs_ln_wt0 (BD aislada) =="
pw="$(wt_shared_sql_password)"
wt_shared_query "$pw" "SET NOCOUNT ON;
SELECT CAST(t AS varchar(24))+' '+CAST(n AS varchar(12)) FROM (
 SELECT 'twhinp100116' t, COUNT(*) n FROM twhinp100116 UNION ALL
 SELECT 'ttisfc001116', COUNT(*) FROM ttisfc001116 UNION ALL
 SELECT 'ttibom010116', COUNT(*) FROM ttibom010116 UNION ALL
 SELECT 'ttdsls401116', COUNT(*) FROM ttdsls401116 UNION ALL
 SELECT 'ttccom100115', COUNT(*) FROM ttccom100115 UNION ALL
 SELECT 'ttcibd420116', COUNT(*) FROM ttcibd420116) q;" "-h -1 -W -d $LN_DB" 2>/dev/null | tr -d '\r' | grep -vE '^\s*$'
