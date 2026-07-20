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

# ---------- I6: fingerprint por unidad + short-circuit/delta (resuelve RISK 1+2) ----------
# Un fingerprint SHA256 (orden estable) por unidad de seed: cada owner Oracle (build/oracle/<owner>/* = .ctl + CSV
# concatenados + *.sql) y la BD LN (build/ln/*). Se comparan contra un marcador POR SLOT en macdata
# (~/goldenslice-bin/seed-fp-wt<N>.tsv, fuera del arbol sembrado; NO en Oracle/LN). Si TODAS las unidades coinciden
# Y el destino conserva datos (sentinela), se SALTA todo el seed -incluido COMPILE_SCHEMA, el costo dominante-
# (ac4 <= 10 s). Si una unidad difiere, se recrea+carga+compila SOLO esa (delta por owner). FORCE=1 re-siembra todo.
FORCE="${FORCE:-0}"
GS_BIN="${GS_BIN:-goldenslice-bin}"                # dir HOME-relative en macdata para los marcadores por slot
FP_MARKER="$GS_BIN/seed-fp-wt${SLOT}.tsv"
SEED_STATUS="$GS_BIN/seed-status-wt${SLOT}"
ora_sql(){ on_intel "docker $ctx exec -i -e ORACLE_HOME='$OH' '$ORA_C' bash -c 'export PATH=\$ORACLE_HOME/bin:\$PATH; sqlplus -S system/oracle@localhost:1521/XE'"; }

# _fp_of <dir>: SHA256 estable del conjunto de archivos del dir (nombre + contenido; excluye .log/.bad de sqlldr).
# Vacio si el dir no existe o no tiene archivos. Corre en la M1 (shasum). Guarda contra el xargs-vacio de BSD.
_fp_of(){  # <dir>
  local dir="$1"
  [ -d "$dir" ] || { printf ''; return 0; }
  ( cd "$dir" || exit 0
    [ -n "$(find . -type f ! -name '*.log' ! -name '*.bad' -print -quit)" ] || { printf ''; exit 0; }
    find . -type f ! -name '*.log' ! -name '*.bad' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 2>/dev/null | shasum -a 256 | awk '{print $1}'
  )
}

# marcador previo (unit -> fp), leido de macdata una sola vez
prev_marker="$(ssh "$PM_REMOTE_SSH" "cat ~/$FP_MARKER 2>/dev/null" || true)"
_prev_fp(){ printf '%s\n' "$prev_marker" | awk -F'\t' -v u="$1" '$1==u{print $2; exit}'; }

# Sentinela de datos del destino: un marcador "match" sobre un Oracle/LN recreado y VACIO haria un skip incorrecto
# (y un destino vacio es una ALARMA, no un estado fiel). Si el sentinela no ve datos, se re-siembra pese al fp.
oracle_has_data=0
if do_ora; then
  # sqlplus justifica el COUNT(*) a la derecha (espacios a la izquierda): se toleran con '^[[:space:]]*' y luego se
  # limpian. El ancla '^' rechaza lineas de error (ORA-#####) para no confundir sus digitos con un conteo real.
  ora_rows="$(printf 'SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF;\nSELECT COUNT(*) FROM PGE_CTRLPISO.TIPGE950;\nEXIT;\n' | ora_sql 2>/dev/null | tr -d '\r' | grep -oE '^[[:space:]]*[0-9]+' | tr -d '[:space:]' | head -1 || true)"
  if [ -n "$ora_rows" ] && [ "$ora_rows" -gt 0 ] 2>/dev/null; then oracle_has_data=1; fi
fi
ln_has_db=0
if do_ln; then
  pw="$(wt_shared_sql_password)" || exit 1     # se reusa en el bloque LN (no se re-resuelve alla)
  wt_shared_sql_check || exit 1
  ln_db_flag="$(wt_shared_query "$pw" "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'$LN_DB') IS NULL THEN 0 ELSE 1 END" "-h -1 -W" 2>/dev/null | tr -d ' \r\n' || true)"
  [ "$ln_db_flag" = 1 ] && ln_has_db=1
fi

# Decide unidades cambiadas (FORCE, o destino sin datos, o fp distinto)
ORA_CHANGED=""
if do_ora; then
  for owner in $ORA_OWNERS; do
    [ -d "$BUILD/oracle/$owner" ] || continue
    fp="$(_fp_of "$BUILD/oracle/$owner" || true)"; prev="$(_prev_fp "oracle:$owner")"
    if [ "$FORCE" = 1 ] || [ "$oracle_has_data" != 1 ] || [ "$fp" != "$prev" ]; then
      ORA_CHANGED="$ORA_CHANGED $owner"
    fi
  done
  ORA_CHANGED="$(echo $ORA_CHANGED | xargs 2>/dev/null || true)"
fi
LN_CHANGED=0
if do_ln; then
  fp_ln="$(_fp_of "$BUILD/ln" || true)"; prev_ln="$(_prev_fp ln)"
  if [ "$FORCE" = 1 ] || [ "$ln_has_db" != 1 ] || [ "$fp_ln" != "$prev_ln" ]; then LN_CHANGED=1; fi
fi

# _write_seed_marker: reescribe el marcador POR SLOT con el fp ACTUAL de las unidades en STEP y carry-forward del
# resto (no pierde el fp de una unidad fuera de STEP). Sin temp files (regla dura: sin 'rm'): contenido por stdin.
_write_seed_marker(){
  local owner fp
  {
    for owner in $ORA_OWNERS; do
      if do_ora && [ -d "$BUILD/oracle/$owner" ]; then fp="$(_fp_of "$BUILD/oracle/$owner" || true)"; else fp="$(_prev_fp "oracle:$owner")"; fi
      [ -n "$fp" ] && printf 'oracle:%s\t%s\n' "$owner" "$fp"
    done
    if do_ln; then fp="$(_fp_of "$BUILD/ln" || true)"; else fp="$(_prev_fp ln)"; fi
    [ -n "$fp" ] && printf 'ln\t%s\n' "$fp"
  } | ssh "$PM_REMOTE_SSH" "mkdir -p ~/$GS_BIN && cat > ~/$FP_MARKER"
}
# _write_seed_status <units>: registra que unidades se recargaron; up.sh lo lee para su gate de loaders (I7).
_write_seed_status(){  # <units-space-list>
  local units count
  units="$(echo $1 | xargs 2>/dev/null || true)"
  count=0; [ -n "$units" ] && count="$(printf '%s\n' $units | wc -w | tr -d ' ')"
  printf 'SEED_RESEEDED_UNITS="%s"\nSEED_RESEEDED_COUNT=%s\n' "$units" "$count" \
    | ssh "$PM_REMOTE_SSH" "mkdir -p ~/$GS_BIN && cat > ~/$SEED_STATUS"
}

# Short-circuit GLOBAL: nada cambio -> se salta TODO el seed (create-user+tables+sqlldr+COMPILE_SCHEMA+LN).
if [ -z "$ORA_CHANGED" ] && [ "$LN_CHANGED" != 1 ]; then
  gs_log "[skip] seed: extract sin cambio (fp match) — 0 tablas recargadas"
  _seed_timing "seed.rsync" "$(date +%s)"
  do_ora && { _seed_timing "seed.oracle.sqlldr" "$(date +%s)"; _seed_timing "seed.oracle.compile" "$(date +%s)"; }
  do_ln && { _seed_timing "seed.ln.iconv" "$(date +%s)"; _seed_timing "seed.ln.bulk" "$(date +%s)"; }
  _write_seed_marker
  _write_seed_status ""
  gs_log "seed golden slice ($STEP) SIN CAMBIO para slot $SLOT (fingerprint match; COMPILE_SCHEMA omitido)."
  exit 0
fi
gs_log "delta de seed: Oracle owners a recargar=[${ORA_CHANGED:-ninguno}], LN cambiado=$LN_CHANGED (FORCE=$FORCE)"

# 0) rsync de build/ (loaders + CSV concatenados) y de los CSV LN -> macdata
gs_log "rsync build/ + CSV LN -> $PM_REMOTE_SSH:~/$STAGE ..."
t0=$(date +%s)
ssh "$PM_REMOTE_SSH" "mkdir -p ~/$STAGE/oracle ~/$STAGE/ln-loaders ~/$STAGE/ln-data" >/dev/null
if do_ora && [ -n "$ORA_CHANGED" ]; then rsync -az "$BUILD/oracle/" "$PM_REMOTE_SSH:~/$STAGE/oracle/" >/dev/null; fi
if do_ln && [ "$LN_CHANGED" = 1 ]; then
  rsync -az "$BUILD/ln/" "$PM_REMOTE_SSH:~/$STAGE/ln-loaders/" >/dev/null
  # CSV LN reales (ln/<base>/c*.csv), preservando la estructura <base>/ (el BULK INSERT usa /pmdata/gs/<base>/<file>)
  rsync -az --prune-empty-dirs --include='*/' --include='c*.csv' --exclude='*' "$SRC/ln/" "$PM_REMOTE_SSH:~/$STAGE/ln-data/" >/dev/null
fi
_seed_timing "seed.rsync" "$t0"
if do_ln && [ "$LN_CHANGED" = 1 ]; then
  # LN CSV UTF-8 -> UTF-16LE (con BOM) in situ: BULK INSERT en SQL Server Linux no soporta CODEPAGE; con el CSV
  # en UTF-8 cuenta bytes y trunca los nvarchar(N) acentuados (rechazos -> tabla a 0 con MAXERRORS=10). El
  # 02-bulk-insert.sql usa DATAFILETYPE='widechar' + ROWTERMINATOR='\n', que exige el archivo en UTF-16LE.
  gs_log "LN: convirtiendo CSV a UTF-16LE (acentos) en el staging remoto ..."
  t0=$(date +%s)
  ssh "$PM_REMOTE_SSH" "zsh -lc 'cd ~/$STAGE/ln-data && find . -name \"c*.csv\" -type f | while IFS= read -r f; do { printf \"\\xff\\xfe\"; iconv -f UTF-8 -t UTF-16LE \"\$f\"; } > \"\$f.u16\" && mv -f \"\$f.u16\" \"\$f\"; done'"
  _seed_timing "seed.ln.iconv" "$t0"
elif do_ln; then _seed_timing "seed.ln.iconv" "$(date +%s)"; fi

# ---------- Oracle: owners + tablas + sqlldr (I6: solo los owners con fp cambiado) ----------
# ora_sql definido en el bloque de decision I6 (arriba).
if do_ora && [ -n "$ORA_CHANGED" ]; then t0=$(date +%s); for owner in $ORA_CHANGED; do
  [ -d "$BUILD/oracle/$owner" ] || continue
  gs_log "Oracle $owner: docker cp + create user/tables + sqlldr ..."
  on_intel "docker $ctx exec '$ORA_C' bash -c 'rm -rf /goldenslice/$owner && mkdir -p /goldenslice/$owner'"
  on_intel "docker $ctx cp \$HOME/$STAGE/oracle/$owner/. '$ORA_C:/goldenslice/$owner/'"
  printf '@/goldenslice/%s/00-create-user.sql\n' "$owner" | ora_sql | tr -d '\r' | tail -2
  printf '@/goldenslice/%s/01-create-tables.sql\n' "$owner" | ora_sql >/dev/null 2>&1 || true
  # direct=true (direct-path): las tablas de la slice son heap sin PK/indices/constraints/triggers (ver
  # 01-create-tables.sql), por lo que el direct-path carga por encima del high-water mark sin rebuild de indices
  # ni validaciones diferidas. La expresion SQL de conversion de fechas ("TO_DATE(SUBSTR(:col,1,19),...)") que
  # emite generate.py referencia solo el bind de su propio campo, caso que el direct-path de Oracle XE 11.2 SI
  # acepta (verificado en slot 2: log "Path used: Direct" con las columnas DATE cargadas y 0 data errors).
  on_intel "docker $ctx exec -i -e ORACLE_HOME='$OH' -e NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS' '$ORA_C' bash -c '
    export PATH=\$ORACLE_HOME/bin:\$PATH; cd /goldenslice/$owner; ok=0; err=0
    for ctl in *.ctl; do
      sqlldr userid=system/oracle@localhost:1521/XE control=\"\$ctl\" log=\"\${ctl%.ctl}.log\" bad=\"\${ctl%.ctl}.bad\" errors=100000 direct=true silent=header,feedback >/dev/null 2>&1 || true
      n=\$(grep -oE \"[0-9]+ Rows successfully loaded\" \"\${ctl%.ctl}.log\" | grep -oE \"^[0-9]+\") ; ok=\$((ok + \${n:-0}))
    done
    echo \"[goldenslice] $owner: \$ok filas cargadas (sqlldr)\"'"
done
  _seed_timing "seed.oracle.sqlldr" "$t0"
  # El DROP+CREATE de tablas invalida los packages/funciones del esquema (dependen de esas tablas). Se recompila
  # (2 pasadas por el orden de dependencias) para dejar VALIDO el camino del intake (PGE950RT/MPSRT). Quedan
  # INVALID los objetos que referencian tablas/esquemas FUERA de la golden slice RES (reportes, PGE_SCMFA2, etc.):
  # es esperado en un subset y no toca el intake.
  gs_log "Oracle: recompilando esquemas cambiados (DBMS_UTILITY.COMPILE_SCHEMA x2) ..."
  t0=$(date +%s)
  for owner in $ORA_CHANGED; do
    printf "BEGIN DBMS_UTILITY.COMPILE_SCHEMA('%s', FALSE); END;\n/\nBEGIN DBMS_UTILITY.COMPILE_SCHEMA('%s', FALSE); END;\n/\n" "$owner" "$owner" | ora_sql >/dev/null 2>&1 || true
  done
  _seed_timing "seed.oracle.compile" "$t0"
elif do_ora; then _seed_timing "seed.oracle.sqlldr" "$(date +%s)"; _seed_timing "seed.oracle.compile" "$(date +%s)"; fi

# ---------- LN: BD aislada + tablas + BULK INSERT (I6: solo si el fp LN cambio) ----------
if do_ln && [ "$LN_CHANGED" = 1 ]; then
gs_log "LN: creando BD aislada $LN_DB + push CSV al motor + BULK INSERT ..."
t0=$(date +%s)
# pw ya resuelto en el bloque de decision I6 (sin re-resolver ni re-checar el motor).
wt_shared_query "$pw" "IF DB_ID(N'$LN_DB') IS NULL CREATE DATABASE [$LN_DB];" >/dev/null
# CSV LN -> /pmdata/gs del motor (BULK INSERT server-side los lee de ahi)
on_intel "docker $ctx exec -u 0 '$PM_SHARED_SQL_CONTAINER' mkdir -p /pmdata/gs && docker $ctx cp \$HOME/$STAGE/ln-data/. '$PM_SHARED_SQL_CONTAINER:/pmdata/gs/'"
# create tables (en la BD aislada)
wt_shared_query "$pw" "$(cat "$BUILD/ln/01-create-tables.sql")" "-d $LN_DB" >/dev/null
# bulk insert (LN_CSV_DIR -> /pmdata/gs; el generador referencia /pmdata/gs/<base>/<file>)
sed 's#\$(LN_CSV_DIR)#/pmdata/gs#g' "$BUILD/ln/02-bulk-insert.sql" | wt_shared_query "$pw" "$(cat)" "-d $LN_DB" >/dev/null
_seed_timing "seed.ln.bulk" "$t0"
elif do_ln; then _seed_timing "seed.ln.bulk" "$(date +%s)"; fi

# I6: actualiza el marcador de fingerprints + el status (unidades recargadas) para la proxima corrida.
_write_seed_marker
reseeded_units=""
for owner in $ORA_CHANGED; do reseeded_units="$reseeded_units oracle:$owner"; done
[ "$LN_CHANGED" = 1 ] && reseeded_units="$reseeded_units ln"
_write_seed_status "$reseeded_units"

gs_log "seed golden slice ($STEP) COMPLETO para slot $SLOT. Verifica: make wt-oracle WT=<f> SQL='select count(*) from PGE_CTRLPISO.TIPGE950' | make wt-sql (LN=$LN_DB)."
