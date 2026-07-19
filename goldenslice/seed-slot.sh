#!/usr/bin/env bash
# Siembra la golden slice (datos reales de PROD, ventana FY2026 sem 18-25) en un slot YA aprovisionado.
#   Oracle del slot (pm-wt<N>-oracle-1): owners PGE_CTRLPISO + DIS_CTP como esquemas propios + CREATE TABLE +
#     carga bulk sqlldr (CSV concatenado por tabla, un solo header).
#   LN per-slot AISLADA (PM_WT_LN_DB): CREATE DATABASE + CREATE TABLE + BULK INSERT server-side (CSV en /pmdata/gs).
# Reusa los helpers del sidecar (on_intel, wt_derive, wt_shared_query). NO toca containers/.
# Aprendizajes de la corrida viva (macdata slot 0, D20): rsync CSV->macdata antes del docker cp; ORACLE_HOME
# explicito; system/oracle para DDL; CSV concatenado (sqlldr multi-INFILE solo salta el 1er header).
#
# uso (via make goldenslice-up, que fija PM_TARGET=intel REMOTE=macdata):
#   SLOT=<N> [SRC=<dir-extraccion>] [BUILD=<dir-build>] ./goldenslice/seed-slot.sh
set -eo pipefail   # sin -u: los libs del sidecar referencian PM_* que el Makefile exporta (vacios) y aqui no estan
: "${PM_TARGET:=intel}" ; : "${PM_REMOTE_SSH:=macdata}" ; : "${PM_REMOTE_DOCKER_CONTEXT:=}"
export PM_TARGET PM_REMOTE_SSH PM_REMOTE_DOCKER_CONTEXT
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SIDECAR_DIR="${PM_SIDECAR_DIR:-$(cd "$SELF_DIR/.." && pwd)}"          # el worktree ES un checkout del sidecar (lib/, Makefile)
WRAPPER_DIR="$(cd "$SELF_DIR/../../.." && pwd)"                       # pm-cc-wrapper
# shellcheck source=/dev/null
. "$SIDECAR_DIR/lib/common.sh"
# shellcheck source=/dev/null
. "$SIDECAR_DIR/lib/worktrees.sh"
load_env   # igual que wt.sh: fija los defaults PM_WT_* (puertos base, etc.) antes de wt_derive

# los CSV/DDL extraidos viven en el checkout PRINCIPAL del sidecar (gitignored), no en el worktree
SRC="${SRC:-$WRAPPER_DIR/gs-pl-pm-macops-sidecar/artifacts/prod-extract-260718}"
BUILD="${BUILD:-$SELF_DIR/build}"
SLOT="${SLOT:?falta SLOT=<N> del slot aprovisionado (make wt-up WT=... ORACLE=1)}"
ORA_OWNERS="${ORA_OWNERS:-PGE_CTRLPISO DIS_CTP}"
STEP="${STEP:-all}"                             # all|oracle|ln: acota la fase (iteracion / re-seed parcial)
do_ora(){ [ "$STEP" = all ] || [ "$STEP" = oracle ]; }
do_ln(){ [ "$STEP" = all ] || [ "$STEP" = ln ]; }

gs_log(){ printf '== [goldenslice] %s\n' "$*"; }

# _seed_timing registra el wall-clock de una sub-fase del seed: emite 'fase|segundos' a stdout con prefijo
# [timing] y, si up.sh exporto PM_TIMING_LOG, anexa la misma linea a ese artefacto. En corrida directa
# (PM_TIMING_LOG sin setear) degrada a solo stdout sin fallar. Usa date +%s (wall-clock, sin gdate).
_seed_timing(){  # <fase> <t0-epoch>
  local fase="$1"
  local t0="$2"
  local dur=$(( $(date +%s) - t0 ))
  printf '[timing] %s|%s\n' "$fase" "$dur"
  [ -n "${PM_TIMING_LOG:-}" ] && printf '%s|%s\n' "$fase" "$dur" >> "$PM_TIMING_LOG" || true
}

wt_require_intel || exit 1
[ -d "$BUILD/oracle" ] || { gs_log "falta $BUILD (corre: python3 goldenslice/generate.py --src $SRC --out build)"; exit 2; }
wt_derive "$SLOT"                              # WT_ORACLE_CONTAINER, PM_WT_ORACLE_*, PM_SHARED_SQL_*, PM_WT_LN_DB
ctx="$(remote_docker_ctx)"
ORA_C="$WT_ORACLE_CONTAINER"
OH="$PM_WT_ORACLE_HOME"
LN_DB="${PM_WT_LN_DB_GS:-pm_gs_ln_wt${SLOT}}"   # LN aislada por slot (no el pm_erpln106 compartido)
STAGE="goldenslice-staging/wt${SLOT}"
gs_log "slot $SLOT -> Oracle=$ORA_C (ORACLE_HOME=$OH), LN aislada=$LN_DB, engine SQL=$PM_SHARED_SQL_CONTAINER"

# 0) rsync de build/ (loaders + CSV concatenados) y de los CSV LN -> macdata
gs_log "rsync build/ + CSV LN -> $PM_REMOTE_SSH:~/$STAGE ..."
t0=$(date +%s)
ssh "$PM_REMOTE_SSH" "mkdir -p ~/$STAGE/oracle ~/$STAGE/ln-loaders ~/$STAGE/ln-data" >/dev/null
if do_ora; then rsync -az "$BUILD/oracle/" "$PM_REMOTE_SSH:~/$STAGE/oracle/" >/dev/null; fi
if do_ln; then
  rsync -az "$BUILD/ln/" "$PM_REMOTE_SSH:~/$STAGE/ln-loaders/" >/dev/null
  # CSV LN reales (ln/<base>/c*.csv), preservando la estructura <base>/ (el BULK INSERT usa /pmdata/gs/<base>/<file>)
  rsync -az --prune-empty-dirs --include='*/' --include='c*.csv' --exclude='*' "$SRC/ln/" "$PM_REMOTE_SSH:~/$STAGE/ln-data/" >/dev/null
fi
_seed_timing "seed.rsync" "$t0"
if do_ln; then
  # LN CSV UTF-8 -> UTF-16LE (con BOM) in situ: BULK INSERT en SQL Server Linux no soporta CODEPAGE; con el CSV
  # en UTF-8 cuenta bytes y trunca los nvarchar(N) acentuados (rechazos -> tabla a 0 con MAXERRORS=10). El
  # 02-bulk-insert.sql usa DATAFILETYPE='widechar' + ROWTERMINATOR='\n', que exige el archivo en UTF-16LE.
  gs_log "LN: convirtiendo CSV a UTF-16LE (acentos) en el staging remoto ..."
  t0=$(date +%s)
  ssh "$PM_REMOTE_SSH" "zsh -lc 'cd ~/$STAGE/ln-data && find . -name \"c*.csv\" -type f | while IFS= read -r f; do { printf \"\\xff\\xfe\"; iconv -f UTF-8 -t UTF-16LE \"\$f\"; } > \"\$f.u16\" && mv -f \"\$f.u16\" \"\$f\"; done'"
  _seed_timing "seed.ln.iconv" "$t0"
fi

# ---------- Oracle: owners + tablas + sqlldr ----------
ora_sql(){ on_intel "docker $ctx exec -i -e ORACLE_HOME='$OH' '$ORA_C' bash -c 'export PATH=\$ORACLE_HOME/bin:\$PATH; sqlplus -S system/oracle@localhost:1521/XE'"; }
if do_ora; then t0=$(date +%s); for owner in $ORA_OWNERS; do
  [ -d "$BUILD/oracle/$owner" ] || continue
  gs_log "Oracle $owner: docker cp + create user/tables + sqlldr ..."
  on_intel "docker $ctx exec '$ORA_C' bash -c 'rm -rf /goldenslice/$owner && mkdir -p /goldenslice/$owner'"
  on_intel "docker $ctx cp \$HOME/$STAGE/oracle/$owner/. '$ORA_C:/goldenslice/$owner/'"
  printf '@/goldenslice/%s/00-create-user.sql\n' "$owner" | ora_sql | tr -d '\r' | tail -2
  printf '@/goldenslice/%s/01-create-tables.sql\n' "$owner" | ora_sql >/dev/null 2>&1 || true
  on_intel "docker $ctx exec -i -e ORACLE_HOME='$OH' -e NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS' '$ORA_C' bash -c '
    export PATH=\$ORACLE_HOME/bin:\$PATH; cd /goldenslice/$owner; ok=0; err=0
    for ctl in *.ctl; do
      sqlldr userid=system/oracle@localhost:1521/XE control=\"\$ctl\" log=\"\${ctl%.ctl}.log\" bad=\"\${ctl%.ctl}.bad\" errors=100000 direct=false silent=header,feedback >/dev/null 2>&1 || true
      n=\$(grep -oE \"[0-9]+ Rows successfully loaded\" \"\${ctl%.ctl}.log\" | grep -oE \"^[0-9]+\") ; ok=\$((ok + \${n:-0}))
    done
    echo \"[goldenslice] $owner: \$ok filas cargadas (sqlldr)\"'"
done
  _seed_timing "seed.oracle.sqlldr" "$t0"
  # El DROP+CREATE de tablas invalida los packages/funciones del esquema (dependen de esas tablas). Se recompila
  # (2 pasadas por el orden de dependencias) para dejar VALIDO el camino del intake (PGE950RT/MPSRT). Quedan
  # INVALID los objetos que referencian tablas/esquemas FUERA de la golden slice RES (reportes, PGE_SCMFA2, etc.):
  # es esperado en un subset y no toca el intake.
  gs_log "Oracle: recompilando esquemas (DBMS_UTILITY.COMPILE_SCHEMA x2) ..."
  t0=$(date +%s)
  for owner in $ORA_OWNERS; do
    printf "BEGIN DBMS_UTILITY.COMPILE_SCHEMA('%s', FALSE); END;\n/\nBEGIN DBMS_UTILITY.COMPILE_SCHEMA('%s', FALSE); END;\n/\n" "$owner" "$owner" | ora_sql >/dev/null 2>&1 || true
  done
  _seed_timing "seed.oracle.compile" "$t0"
fi

# ---------- LN: BD aislada + tablas + BULK INSERT ----------
if do_ln; then
gs_log "LN: creando BD aislada $LN_DB + push CSV al motor + BULK INSERT ..."
t0=$(date +%s)
pw="$(wt_shared_sql_password)" || exit 1
wt_shared_sql_check || exit 1
wt_shared_query "$pw" "IF DB_ID(N'$LN_DB') IS NULL CREATE DATABASE [$LN_DB];" >/dev/null
# CSV LN -> /pmdata/gs del motor (BULK INSERT server-side los lee de ahi)
on_intel "docker $ctx exec -u 0 '$PM_SHARED_SQL_CONTAINER' mkdir -p /pmdata/gs && docker $ctx cp \$HOME/$STAGE/ln-data/. '$PM_SHARED_SQL_CONTAINER:/pmdata/gs/'"
# create tables (en la BD aislada)
wt_shared_query "$pw" "$(cat "$BUILD/ln/01-create-tables.sql")" "-d $LN_DB" >/dev/null
# bulk insert (LN_CSV_DIR -> /pmdata/gs; el generador referencia /pmdata/gs/<base>/<file>)
sed 's#\$(LN_CSV_DIR)#/pmdata/gs#g' "$BUILD/ln/02-bulk-insert.sql" | wt_shared_query "$pw" "$(cat)" "-d $LN_DB" >/dev/null
_seed_timing "seed.ln.bulk" "$t0"
fi

gs_log "seed golden slice ($STEP) COMPLETO para slot $SLOT. Verifica: make wt-oracle WT=<f> SQL='select count(*) from PGE_CTRLPISO.TIPGE950' | make wt-sql (LN=$LN_DB)."
