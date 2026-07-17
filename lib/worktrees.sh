#!/usr/bin/env bash
# Aprovisionamiento aislado por worktree para el data tier + API de PM.
# Compatible con bash 3.2 (el /bin/bash de macOS): sin arrays asociativos, lock por mkdir.
# La logica vive aqui; wt.sh es la capa fina y el Makefile expone los verbos.
#
# Modelo "slot": un slot (0..N-1) es la unica perilla por worktree; de el se derivan proyecto, offset de
# puertos, nombre de BD y prefijo de bus. Capas:
#   - Singletons compartidos (una vez): SQL de nvoslabs (reusado), referencia LN propia pm_erpln106
#     (seed-once guarded), bus PM-owned (emulador + SQL Edge), puente SQL del guest.
#   - Per-worktree: BD pm_planning_wt<N> en el SQL compartido + contenedor de la API (build desde el worktree)
#     + Oracle ControlPiso propio (pm-wt<N>-oracle-1, lazy: solo con PM_WT_ORACLE=1) + site IIS del legado
#     (pm-wt<N>, lo aprovisiona legacy.sh; ver README, tabla canonica por slot).
# El Oracle per-slot es LAZY porque solo lo necesita un slot con frontend: el camino con el feature flag OFF
# escribe en ControlPiso (PGE950RT) y contaminaria a las demas sesiones si el Oracle fuese singleton.
#
# Frontera wrapper/solucion: este orquestador NO escribe dentro de pl-programa-maestro; reusa sus scripts/CSV
# por bind-mount/copia y pasa todo por entorno. El SQL compartido es de otra solucion (nvoslabs): las BD de PM
# en el son desechables/reseedables (acoplamiento aceptado).

# Tablas que la ACL LN de PM consulta en su referencia (pm_erpln106): definen la verificacion de completitud.
WT_LN_TABLES="ttcibd001115 ttxpcf930116 ttxpcf925116 ttibom010116 twhinp100116 ttdsls400116 ttdsls401116 ttirou101116"

wt_log() { echo "[wt] $*" >&2; }
wt_die() { echo "[wt] ERROR: $*" >&2; return 1; }

# Exige target intel: el SQL compartido (nvoslabs), el bus y la API viven en el docker de macdata.
wt_require_intel() {
  [ "$PM_TARGET" = "intel" ] || wt_die "los verbos wt-* requieren PM_TARGET=intel (REMOTE=macdata): el SQL compartido y el bus viven en macdata" || return 1
  [ -n "$PM_REMOTE_SSH" ] || wt_die "falta PM_REMOTE_SSH (host de la Intel, p.ej. macdata)" || return 1
  # El data tier de PM debe correr en el MISMO docker que el SQL compartido para compartir su red.
  [ -n "$PM_REMOTE_DOCKER_CONTEXT" ] || PM_REMOTE_DOCKER_CONTEXT="colima-nlc3runner"
}

# Escapa comillas simples para incrustar un valor en un comando remoto entre comillas simples.
wt_esc() { local s="$1"; printf "%s" "${s//\'/\'\\\'\'}"; }

# --- Lock por mkdir (portable en macOS, sin flock): serializa una seccion critica entre procesos wt-* del
# mismo orquestador. uso: wt_lock <nombre> <cmd...> ---
#
# El 'trap RETURN' libera el lock cuando la funcion retorna, pero NO cuando el proceso muere por senal
# (Ctrl-C, SIGTERM): sin mas red de seguridad, un Ctrl-C durante un 'wt-up' dejaba el lock huerfano y wedgeaba
# todos los wt-up futuros. Se añaden: (a) trap de senal a nivel de proceso; (b) marca de dueno con el pid;
# (c) reclamo del lock cuyo dueno ya no existe.
#
# El dueno se marca con un SUBDIRECTORIO 'pid.<pid>', no con un archivo: asi todas las transiciones del lock
# son mkdir/rmdir y el script nunca ejecuta 'rm' (regla dura del proyecto para los scripts de lock).
WT_LOCK_TTL="${PM_WT_LOCK_TTL:-1800}"     # un lock sin dueno legible y mas viejo que esto se reclama

_wt_lock_dir_age() { local m; m=$(stat -f %m "$1" 2>/dev/null) || m=0; echo $(( $(date +%s) - m )); }
# pid del dueno de un lock (vacio si no hay marca).
_wt_lock_owner_pid() { local p; p="$(ls -1 "$1" 2>/dev/null | sed -n 's/^pid\.//p' | head -1)"; printf '%s' "$p"; }
# Suelta un lock concreto si es de este proceso. Idempotente.
_wt_lock_drop() { rmdir "$1/pid.$$" 2>/dev/null || true; rmdir "$1" 2>/dev/null || true; }

# Suelta TODOS los locks de este proceso. La invoca el trap de senal (Ctrl-C / SIGTERM).
wt_lock_release_all() {
  local d dir; dir="$(dirname "$PM_WT_REGISTRY")"
  for d in "$dir"/.*.lock; do
    [ -d "$d/pid.$$" ] || continue
    _wt_lock_drop "$d"
  done
}
trap 'wt_lock_release_all' INT TERM

wt_lock() {
  local name="$1"; shift
  local dir; dir="$(dirname "$PM_WT_REGISTRY")"
  local lock="$dir/.${name}.lock" i=0 opid rc
  mkdir -p "$dir"
  until mkdir "$lock" 2>/dev/null; do
    opid="$(_wt_lock_owner_pid "$lock")"
    if [ -n "$opid" ] && ! kill -0 "$opid" 2>/dev/null; then
      wt_log "lock '$name' de un proceso muerto (pid $opid): se reclama"
      rmdir "$lock/pid.$opid" 2>/dev/null || true; rmdir "$lock" 2>/dev/null || true
      continue
    fi
    if [ -z "$opid" ] && [ "$(_wt_lock_dir_age "$lock")" -gt "$WT_LOCK_TTL" ]; then
      wt_log "lock '$name' sin dueno legible y con $(_wt_lock_dir_age "$lock")s de edad: se reclama"
      rmdir "$lock" 2>/dev/null || true
      continue
    fi
    i=$((i+1)); [ "$i" -gt 180 ] && { wt_die "timeout esperando el lock '$name' (lo tiene el pid ${opid:-?})"; return 1; }
    sleep 1
  done
  mkdir "$lock/pid.$$" 2>/dev/null || true
  # shellcheck disable=SC2064
  trap "_wt_lock_drop '$lock'" RETURN
  rc=0; "$@" || rc=$?
  return "$rc"
}

# Serializa lecturas/escrituras del registro de slots (folder -> slot), gitignored.
wt_registry_lock() { wt_lock registry "$@"; }

# Slot asignado a un folder (sin asignar uno nuevo); vacio si no existe.
wt_slot_lookup() {  # uso: wt_slot_lookup <folder>
  [ -f "$PM_WT_REGISTRY" ] || return 0
  awk -F'\t' -v f="$1" '$1==f{print $2; exit}' "$PM_WT_REGISTRY"
}

# Asigna (o reusa) el slot libre mas bajo para un folder y lo persiste. Imprime el slot. Vacio + rc!=0 si el pool
# esta lleno (el llamador decide: reclamar arrendamientos muertos o rendirse).
# El registro tiene 7 columnas: folder, slot, project, offset, created, owner_pid, heartbeat. owner_pid+heartbeat
# forman el arrendamiento del slot (ver wt_lease_reclaimable); las filas viejas de 5 columnas se leen como
# arrendamiento sin pid (muerto) y sin heartbeat (cae a 'created' para la edad).
wt_slot_assign() {  # uso: wt_slot_assign <folder>   (correr bajo wt_registry_lock)
  local folder="$1" existing n used now
  existing="$(wt_slot_lookup "$folder")"
  if [ -n "$existing" ]; then printf '%s' "$existing"; return 0; fi
  [ -f "$PM_WT_REGISTRY" ] || : > "$PM_WT_REGISTRY"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for n in $(seq 0 $(( PM_WT_SLOTS - 1 ))); do
    used="$(awk -F'\t' -v s="$n" '$2==s{print 1; exit}' "$PM_WT_REGISTRY")"
    if [ -z "$used" ]; then
      # owner_pid = pid de este proceso; heartbeat = ahora (la asignacion es el primer latido del arrendamiento).
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$folder" "$n" "pm-wt${n}" "$(( n * 10 ))" "$now" "$$" "$now" >> "$PM_WT_REGISTRY"
      printf '%s' "$n"; return 0
    fi
  done
  return 1   # pool lleno: sin wt_die (el llamador reclama arrendamientos muertos o reporta el error final)
}

# Libera el slot de un folder (borra su linea del registro).
wt_slot_release() {  # uso: wt_slot_release <folder>   (correr bajo wt_registry_lock)
  [ -f "$PM_WT_REGISTRY" ] || return 0
  local tmp="${PM_WT_REGISTRY}.tmp"
  awk -F'\t' -v f="$1" '$1!=f' "$PM_WT_REGISTRY" > "$tmp" && mv "$tmp" "$PM_WT_REGISTRY"
}

# Refresca el arrendamiento (owner_pid=este pid, heartbeat=ahora) del folder. Idempotente. Corre bajo
# wt_registry_lock. Una fila vieja de 5 columnas se migra en sitio a 7 al refrescarla. Lo llaman los verbos que
# operan sobre el slot (wt-up, wt-info, wt-heartbeat, e2e-url): un slot en uso activo nunca queda reclamable.
wt_slot_touch() {  # uso: wt_slot_touch <folder>   (correr bajo wt_registry_lock)
  [ -f "$PM_WT_REGISTRY" ] || return 0
  local tmp="${PM_WT_REGISTRY}.tmp" now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  awk -F'\t' -v OFS='\t' -v f="$1" -v pid="$$" -v hb="$now" '
    $1==f { $6=pid; $7=hb }
    { print }
  ' "$PM_WT_REGISTRY" > "$tmp" && mv "$tmp" "$PM_WT_REGISTRY"
}

# Verdadero si un arrendamiento es reclamable: su proceso dueno murio (kill -0 falla, o no hay pid) Y su heartbeat
# (o 'created' si la fila es vieja) es mas viejo que PM_WT_LEASE_TTL. Un pid VIVO o un heartbeat FRESCO => NUNCA
# reclamable (espeja guest-turn: no se roba el turno a una duena viva aunque el heartbeat este rancio). El kill -0
# solo es valido en esta M1 (el registro y los pids son locales; limitacion documentada).
wt_lease_reclaimable() {  # uso: wt_lease_reclaimable <owner_pid> <heartbeat> <created>
  local pid="$1" hb="$2" cr="$3" ref age
  if wt_is_num "$pid" && kill -0 "$pid" 2>/dev/null; then return 1; fi   # pid vivo: protegido
  ref="$hb"; [ -n "$ref" ] || ref="$cr"                                  # sin heartbeat (fila vieja) -> created
  age="$(wt_age_secs "$ref")"
  wt_is_num "$age" || return 1                                           # edad ilegible -> conservador: no reclamar
  [ "$age" -gt "$PM_WT_LEASE_TTL" ]
}

# Resuelve el folder del worktree de CODIGO: WT explicito, o autodeteccion por el toplevel git SOLO si el CWD
# es un worktree de codigo (bajo worktrees/* con PL.PM.sln), mismo criterio que resolve_solution_dir. Sin el
# guard, correr desde el checkout central del sidecar (o un worktree del propio sidecar) devolveria el basename
# del sidecar y consumiria un slot bajo una clave que no es un worktree de codigo (registro compartido).
wt_resolve_folder() {
  if [ -n "${WT:-}" ]; then printf '%s' "$WT"; return 0; fi
  local top; top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  case "$top" in
    "$WRAPPER_DIR/worktrees/"*) [ -f "$top/PL.PM.sln" ] && { basename "$top"; return 0; } ;;
  esac
  wt_die "falta WT=<folder> (la autodeteccion por CWD solo aplica dentro de un worktree de codigo bajo worktrees/* con PL.PM.sln)"; return 1
}

# Deriva todos los parametros por slot y recalcula puertos.
# Conviven dos strides deliberados: N*10 para la API (herencia de PM_PORT_OFFSET) y +1 para site/tunel/Oracle
# (bloques dedicados). Unificarlos romperia los slots vivos.
wt_derive() {  # uso: wt_derive <slot>
  WT_SLOT="$1"
  PM_PROJECT="pm-wt${WT_SLOT}"
  PM_PORT_OFFSET=$(( WT_SLOT * 10 ))
  PM_PLANNING_DB="pm_planning_wt${WT_SLOT}"
  WT_SB_PREFIX="wt${WT_SLOT}"
  PM_PROFILE="full"; PROFILE_FLAG="--profile full"
  compute_ports
  # Oracle del slot: base dedicada, NO 1521+offset (colisiona con pm-local-oracle-1 y pm-arts-rt-oracle-1).
  # Pisa el PM_ORACLE_HOST_PORT que compute_ports acaba de derivar: es el puerto que publica el compose del
  # slot y el que consume pm_ctrlpiso_connstr.
  WT_ORACLE_PORT=$(( PM_WT_ORACLE_PORT_BASE + WT_SLOT ))
  PM_ORACLE_HOST_PORT="$WT_ORACLE_PORT"
  WT_ORACLE_CONTAINER="pm-wt${WT_SLOT}-oracle-1"
  WT_ORACLE_VOLUME="pm-wt${WT_SLOT}_pm-oracle-data"
  WT_ORACLE_NETWORK="pm-wt${WT_SLOT}_default"
  # Frontend legado del slot (lo aprovisiona legacy.sh; aqui solo se derivan para wt-info/wt-gc).
  WT_SITE_NAME="pm-wt${WT_SLOT}"
  WT_SITE_PORT=$(( PM_WT_SITE_PORT_BASE + WT_SLOT ))
  WT_TUNNEL_PORT=$(( PM_WT_TUNNEL_PORT_BASE + WT_SLOT ))
}

# --- SQL compartido (nvoslabs) ---

# Password SA del SQL compartido: el explicito (PM_SHARED_SQL_PASSWORD) o autodescubierto del contenedor.
wt_shared_sql_password() {
  if [ -n "$PM_SHARED_SQL_PASSWORD" ]; then printf '%s' "$PM_SHARED_SQL_PASSWORD"; return 0; fi
  local ctx pw; ctx="$(remote_docker_ctx)"
  pw="$(on_intel "docker $ctx exec '$PM_SHARED_SQL_CONTAINER' printenv SA_PASSWORD 2>/dev/null" 2>/dev/null | tr -d '\r\n')"
  [ -n "$pw" ] || pw="$(on_intel "docker $ctx exec '$PM_SHARED_SQL_CONTAINER' printenv MSSQL_SA_PASSWORD 2>/dev/null" 2>/dev/null | tr -d '\r\n')"
  [ -n "$pw" ] || { wt_die "no se autodescubrio el SA del SQL compartido ($PM_SHARED_SQL_CONTAINER); fija PM_SHARED_SQL_PASSWORD"; return 1; }
  printf '%s' "$pw"
}

# Verifica que la red y el contenedor del SQL compartido existan en el docker de macdata.
wt_shared_sql_check() {
  local ctx; ctx="$(remote_docker_ctx)"
  on_intel "docker $ctx network inspect '$PM_SHARED_SQL_NETWORK' >/dev/null 2>&1" \
    || { wt_die "la red del SQL compartido '$PM_SHARED_SQL_NETWORK' no existe en $PM_REMOTE_SSH (nvoslabs apagado?)"; return 1; }
  on_intel "[ \"\$(docker $ctx inspect -f '{{.State.Running}}' '$PM_SHARED_SQL_CONTAINER' 2>/dev/null)\" = true ]" \
    || { wt_die "el contenedor del SQL compartido '$PM_SHARED_SQL_CONTAINER' no esta corriendo en $PM_REMOTE_SSH"; return 1; }
  wt_log "SQL compartido OK: red '$PM_SHARED_SQL_NETWORK', contenedor '$PM_SHARED_SQL_CONTAINER' (alias $PM_SHARED_SQL_HOST:$PM_SHARED_SQL_PORT)"
}

# Ejecuta una consulta T-SQL desde un contenedor de herramientas DEDICADO (tools18), separado del motor: se
# une a la red del SQL compartido y conecta por alias de red (no 'docker exec' dentro del motor; mismo patron
# que sirve contra un motor remoto/gestionado). El SQL viaja por STDIN (-i /dev/stdin) -> sin quoting de
# metacaracteres; la password por env ($SAPW) la expande el bash del contenedor. --entrypoint /bin/bash evita
# el entrypoint del image (que arrancaria el motor).
# uso: wt_shared_query <password> <sql> [flags-extra-de-sqlcmd]
wt_shared_query() {
  local pw="$1" sql="$2" flags="${3:-}"
  local ctx; ctx="$(remote_docker_ctx)"
  printf '%s' "$sql" | on_intel "docker $ctx run --rm -i --network '$PM_SHARED_SQL_NETWORK' -e SAPW='$(wt_esc "$pw")' --entrypoint /bin/bash '$PM_SQLTOOLS_IMAGE' -c '/opt/mssql-tools18/bin/sqlcmd -S \"$PM_SHARED_SQL_HOST,$PM_SHARED_SQL_PORT\" -U sa -P \"\$SAPW\" -C $flags -i /dev/stdin'"
}
# Escalar (sin encabezado): retorna el valor trimmeado.
wt_shared_scalar() { wt_shared_query "$1" "$2" "-h -1 -W" 2>/dev/null | tr -d ' \r\n'; }
# DDL/idempotente: corta en error (-b).
wt_shared_exec()   { wt_shared_query "$1" "$2" "-b"; }

# Copia los CSV de seed AL motor del SQL compartido (sql/data -> /pmdata, oracle/data -> /seed-ctrlpiso): el
# BULK INSERT corre server-side EN EL MOTOR, que lee los CSV de su filesystem. Los scripts (.sql) NO se copian
# aqui: el contenedor de tools dedicado los monta por -v desde el arbol rsync'eado (wt_seed_group). Idempotente.
# Los CSV van a /pmdata (overlay del contenedor), NO a /data: ese path es bind-mount al arbol fuente del SQL de
# nvoslabs, y escribir ahi sobreescribiria sus CSV homonimos (p. ej. ttxpcf925116.csv).
wt_push_seed_assets() {  # uso: wt_push_seed_assets   (requiere WT_REMOTE_CONTAINERS_ABS)
  local ctx; ctx="$(remote_docker_ctx)"
  wt_log "copiando CSV de seed al motor del SQL compartido (/pmdata, /seed-ctrlpiso; BULK INSERT server-side) ..."
  # mkdir como root (-u 0): el contenedor corre como 'mssql', que no puede crear dirs en /. docker cp ya
  # escribe como root; los archivos quedan world-readable -> el proceso de SQL (BULK INSERT server-side) los lee.
  on_intel "docker $ctx exec -u 0 '$PM_SHARED_SQL_CONTAINER' mkdir -p /pmdata /seed-ctrlpiso \
    && docker $ctx cp '$WT_REMOTE_CONTAINERS_ABS/sql/data/.' '$PM_SHARED_SQL_CONTAINER:/pmdata' \
    && docker $ctx cp '$WT_REMOTE_CONTAINERS_ABS/oracle/data/.' '$PM_SHARED_SQL_CONTAINER:/seed-ctrlpiso'" \
    || { wt_die "fallo al copiar los CSV de seed al motor del SQL compartido"; return 1; }
}

# Aplica en orden los *.sql de un grupo (/pmseed/<group>) desde un contenedor de herramientas DEDICADO
# (tools18, --entrypoint bash), separado del motor: los scripts se montan por -v desde el arbol rsync'eado en
# macdata; sqlcmd conecta al motor por alias de red. El BULK INSERT corre server-side EN EL MOTOR, que lee los
# CSV de su filesystem (copiados por wt_push_seed_assets: ln -> /pmdata, planning -> /seed-ctrlpiso). El loop
# viaja por STDIN (bash -s) para evitar el quoting anidado; los nombres de BD van como sqlcmd vars.
wt_seed_group() {  # uso: wt_seed_group <password> <ln|planning> <planning_db> <ln_db>
  local pw="$1" group="$2" pdb="$3" ldb="$4" ctx; ctx="$(remote_docker_ctx)"
  printf '%s\n' \
    'set -e' \
    "for f in \$(ls /pmseed/$group/*.sql | sort); do" \
    '  echo "[seed] aplica $(basename "$f")"' \
    "  /opt/mssql-tools18/bin/sqlcmd -S \"$PM_SHARED_SQL_HOST,$PM_SHARED_SQL_PORT\" -U sa -P \"\$SAPW\" -C -b -v PLANNING_DB=$pdb LN_DB=$ldb LN_CSV_DIR=/pmdata -i \"\$f\"" \
    'done' \
  | on_intel "docker $ctx run --rm -i --network '$PM_SHARED_SQL_NETWORK' -v '$WT_REMOTE_CONTAINERS_ABS/sql/init:/pmseed:ro' -e SAPW='$(wt_esc "$pw")' --entrypoint /bin/bash '$PM_SQLTOOLS_IMAGE' -s"
}

# Asegura la referencia LN propia de PM (pm_erpln106) en el SQL compartido. Guarded seed-once: solo siembra
# si la BD no existe o esta incompleta; nunca re-siembra si ya esta completa (los scripts ln/ hacen DROP+CREATE
# y re-sembrar disruptaria worktrees en vuelo que la leen).
wt_ensure_ln_singleton() {  # uso: wt_ensure_ln_singleton <password>
  local pw="$1" have need dbok ctx; ctx="$(remote_docker_ctx)"
  need=$(printf '%s\n' $WT_LN_TABLES | grep -c .)
  local inlist; inlist="$(printf "'%s'," $WT_LN_TABLES)"; inlist="${inlist%,}"
  # En dos pasos: una referencia cross-DB (FROM [db].sys.tables) a una BD inexistente falla al COMPILAR aun en
  # la rama no tomada; primero se comprueba existencia, luego se cuenta. Lecturas tolerantes a fallo (|| ...).
  dbok="$(wt_shared_scalar "$pw" "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'$PM_WT_LN_DB') IS NULL THEN 0 ELSE 1 END")" || dbok=0
  if [ "${dbok:-0}" = "1" ]; then
    have="$(wt_shared_scalar "$pw" "SET NOCOUNT ON; SELECT COUNT(*) FROM [$PM_WT_LN_DB].sys.tables WHERE name IN ($inlist)")" || have=0
  else
    have=0
  fi
  have="${have:-0}"
  if [ "$have" = "$need" ]; then
    wt_log "referencia LN '$PM_WT_LN_DB' completa ($have/$need tablas): se reusa (no re-seed)"
    return 0
  fi
  wt_log "referencia LN '$PM_WT_LN_DB' ausente/incompleta ($have/$need): sembrando una vez (grupo ln) ..."
  # El grupo ln crea $PM_WT_LN_DB con sus tablas (BULK INSERT lee /pmdata en el SQL compartido). PLANNING_DB es
  # un placeholder: los scripts ln solo usan $(LN_DB).
  wt_seed_group "$pw" ln "_pm_unused" "$PM_WT_LN_DB" \
    || { wt_die "fallo el seed de la referencia LN '$PM_WT_LN_DB'"; return 1; }
  wt_log "referencia LN '$PM_WT_LN_DB' sembrada"
}

# Siembra los datos de referencia de la BD de producto del worktree (pm_planning_wt<N>): grupo planning
# data-only (el DDL ya lo creo la migracion EF al arrancar la API). Reusa la referencia LN pm_erpln106.
wt_seed_planning() {  # uso: wt_seed_planning <password>
  local pw="$1"
  wt_log "seed data-only de '$PM_PLANNING_DB' en el SQL compartido (grupo planning; reusa $PM_WT_LN_DB) ..."
  wt_seed_group "$pw" planning "$PM_PLANNING_DB" "$PM_WT_LN_DB" \
    || { wt_die "fallo el seed de '$PM_PLANNING_DB'"; return 1; }
}

# --- Bus PM-owned (singleton compartido entre worktrees) ---

# Renderiza la topologia del emulador compartido con las entidades de TODOS los slots del techo
# (canonicas + wt0..wt<PM_WT_SLOTS_MAX-1>): el emulador solo carga entidades ESTATICAS de Config.json y la
# API de cada slot resuelve nombres prefijados wt<N>-*, asi que todas deben existir de antemano. Deriva el
# resultado de la topologia base (containers/servicebus/Config.json) para no duplicar la lista de topics.
# Escribe a $HOME/<PM_WT_BUS_CONFIG_DIR>/Config.slots.json en macdata (ruta estable, no per-slot).
wt_render_bus_config() {
  local jq_prog jq_b64 dir="$PM_WT_BUS_CONFIG_DIR"
  # Expande cada topic base a la variante canonica y a wt<N>- para N en [0, MAX); idem en las subscriptions.
  jq_prog='($MAX|tonumber) as $n | ([""] + [range(0;$n) | "wt\(.)"]) as $pfx | .UserConfig.Namespaces[0].Topics as $base | .UserConfig.Namespaces[0].Topics = [ $pfx[] as $p | $base[] | .Name = (if $p == "" then .Name else "\($p)-\(.Name)" end) | .Subscriptions = [ .Subscriptions[] | .Name = (if $p == "" then .Name else "\($p)-\(.Name)" end) ] ]'
  jq_b64="$(printf '%s' "$jq_prog" | base64 | tr -d '\n')"
  wt_log "renderizando topologia de bus por-slot (canonica + wt0..wt$((PM_WT_SLOTS_MAX-1))) en $dir/Config.slots.json ..."
  # base64 evita el infierno de comillas al llevar el programa jq por ssh; el jq lee la base staged del slot.
  on_intel "set -e; mkdir -p \"\$HOME/$dir\"; printf '%s' '$jq_b64' | base64 -d > \"\$HOME/$dir/render.jq\"; jq --arg MAX '$PM_WT_SLOTS_MAX' -f \"\$HOME/$dir/render.jq\" '$PM_REMOTE_DIR/servicebus/Config.json' > \"\$HOME/$dir/Config.slots.json\"" \
    || { wt_die "fallo al renderizar la topologia de bus por-slot"; return 1; }
}

# Levanta el bus (sbsqledge + servicebus emulador) como proyecto compose dedicado, una sola vez.
wt_ensure_bus() {
  local ctx; ctx="$(remote_docker_ctx)"
  # Declara estaticamente en el emulador las entidades de todos los slots del techo antes del cold-start.
  wt_render_bus_config || return 1
  local recreate=""
  # Cold-start unico. Si el emulador ya corre, verifica que monte la topologia por-slot; una instancia stale
  # (canonica, previa a este cambio) se recrea para que existan las entidades wt<N>-*.
  if on_intel "[ \"\$(docker $ctx inspect -f '{{.State.Running}}' '${PM_WT_BUS_PROJECT}-servicebus-1' 2>/dev/null)\" = true ]" 2>/dev/null; then
    if on_intel "docker $ctx inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' '${PM_WT_BUS_PROJECT}-servicebus-1' 2>/dev/null | grep -q '/$PM_WT_BUS_CONFIG_DIR/Config.slots.json\$'" 2>/dev/null; then
      wt_log "bus PM-owned ya arriba con topologia por-slot (proyecto $PM_WT_BUS_PROJECT)"; return 0
    fi
    wt_log "bus PM-owned arriba con topologia stale (canonica): recreando el emulador con entidades por-slot ..."
    recreate="--force-recreate"
  fi
  wt_log "levantando bus PM-owned (proyecto $PM_WT_BUS_PROJECT: sbsqledge + servicebus; host :$PM_WT_BUS_HOST_PORT) ..."
  on_intel "export PATH=/usr/local/bin:\$PATH PM_SB_SA_PASSWORD='$(wt_esc "$PM_SB_SA_PASSWORD")' PM_SB_HOST_PORT='$PM_WT_BUS_HOST_PORT' PM_SB_CONFIG_FILE=\"\$HOME/$PM_WT_BUS_CONFIG_DIR/Config.slots.json\"; cd '$PM_REMOTE_DIR/compose' && docker $ctx compose -p '$PM_WT_BUS_PROJECT' -f '$COMPOSE_FILE' --profile bus up -d $recreate sbsqledge servicebus" \
    || { wt_die "fallo al levantar el bus PM-owned"; return 1; }
}

# --- Puente SQL compartido (socat: macdata:<port> -> shared SQL:1433) ---

# Singleton administrado (mismo trato que el bus). Publica el SQL compartido (nvoslabs) en un puerto de macdata
# para que lo alcancen el guest (pasarela NAT 172.16.128.1:<port>) y la M1 (macbook-pro-de-diana.local:<port>).
# Lo comparten la via e2e (scripts/e2e.sh) y el gate por slot (pm.sh test-clean). Config por entorno, compatible
# con la via e2e: PM_E2E_BRIDGE_PORT / _NAME / _IMAGE.
wt_bridge_port()  { printf '%s' "${PM_E2E_BRIDGE_PORT:-60211}"; }
wt_bridge_name()  { printf '%s' "${PM_E2E_BRIDGE_NAME:-pm-e2e-sqlbridge}"; }
wt_bridge_image() { printf '%s' "${PM_E2E_BRIDGE_IMAGE:-alpine/socat}"; }

# Idempotente, adopt-if-present, bajo 'wt_lock bridge'. El puente es COMPARTIDO: un 'docker rm -f' incondicional
# mataria el puente recien creado por otra sesion (blip del 60211 -> los demas frontends leen el flag como OFF).
# Se crea SOLO si esta ausente y ante 'name already in use' se adopta el ajeno.
_wt_bridge_up_locked() {
  local ctx port name image; ctx="$(remote_docker_ctx)"
  port="$(wt_bridge_port)"; name="$(wt_bridge_name)"; image="$(wt_bridge_image)"
  if on_intel "[ \"\$(docker $ctx inspect -f '{{.State.Running}}' '$name' 2>/dev/null)\" = true ]" 2>/dev/null; then
    wt_log "puente SQL ya arriba ($name en :$port)"; return 0
  fi
  # Existe pero no corre (o quedo a medias): recrearlo es seguro, nadie lo esta usando.
  on_intel "docker $ctx inspect '$name' >/dev/null 2>&1 && docker $ctx rm -f '$name' >/dev/null 2>&1; true"
  wt_log "puente SQL: asegurando imagen $image ..."
  on_intel "docker $ctx image inspect '$image' >/dev/null 2>&1 || docker $ctx pull '$image'" \
    || { wt_die "no se pudo obtener la imagen del puente ($image); macdata sin internet? fija PM_E2E_BRIDGE_IMAGE a una imagen socat presente"; return 1; }
  wt_log "puente SQL: $name (red $PM_SHARED_SQL_NETWORK; publica $port -> $PM_SHARED_SQL_HOST:$PM_SHARED_SQL_PORT) ..."
  if ! on_intel "docker $ctx run -d --name '$name' --network '$PM_SHARED_SQL_NETWORK' -p '$port:1433' --restart unless-stopped '$image' TCP-LISTEN:1433,fork,reuseaddr TCP:$PM_SHARED_SQL_HOST:$PM_SHARED_SQL_PORT >/dev/null"; then
    # Carrera con otra sesion: si el suyo quedo corriendo, se adopta en vez de fallar.
    if on_intel "[ \"\$(docker $ctx inspect -f '{{.State.Running}}' '$name' 2>/dev/null)\" = true ]" 2>/dev/null; then
      wt_log "puente SQL lo creo otra sesion en paralelo; se adopta ($name)"; return 0
    fi
    wt_die "fallo al levantar el puente SQL ($name)"; return 1
  fi
}
wt_bridge_up() { wt_lock bridge _wt_bridge_up_locked; }

# Opt-in (PM_E2E_BRIDGE_DOWN=1): por default el puente queda arriba como singleton administrado. Bajarlo desde
# un e2e-down/gate cortaria la lectura del flag de TODOS los demas slots.
wt_bridge_down() {
  local ctx name; name="$(wt_bridge_name)"
  if [ "${PM_E2E_BRIDGE_DOWN:-0}" != "1" ]; then
    wt_log "puente SQL conservado ($name; singleton compartido). PM_E2E_BRIDGE_DOWN=1 para bajarlo."; return 0
  fi
  ctx="$(remote_docker_ctx)"
  on_intel "docker $ctx rm -f '$name' >/dev/null 2>&1; true" && wt_log "puente SQL bajado ($name)"
}

# --- Oracle ControlPiso por worktree (lazy: solo con PM_WT_ORACLE=1) ---

# La imagen wnameless/oracle-xe-11g-r2 no exporta ORACLE_HOME ni sqlplus en el PATH del contenedor.
PM_WT_ORACLE_HOME="${PM_WT_ORACLE_HOME:-/u01/app/oracle/product/11.2.0/xe}"
PM_WT_ORACLE_USER="${PM_WT_ORACLE_USER:-pge_ctrlpiso}"
PM_WT_ORACLE_PASS="${PM_WT_ORACLE_PASS:-ctrlpiso}"

wt_oracle_exists() {
  local ctx; ctx="$(remote_docker_ctx)"
  on_intel "docker $ctx inspect '$WT_ORACLE_CONTAINER' >/dev/null 2>&1" 2>/dev/null
}
wt_oracle_running() {
  local ctx; ctx="$(remote_docker_ctx)"
  on_intel "[ \"\$(docker $ctx inspect -f '{{.State.Running}}' '$WT_ORACLE_CONTAINER' 2>/dev/null)\" = true ]" 2>/dev/null
}

# Escalar desde el Oracle del slot. El SQL viaja por STDIN (mismo patron que wt_shared_query): sin quoting de
# metacaracteres a traves de ssh -> docker exec -> bash -> sqlplus.
# sqlplus justifica el valor a la derecha rellenando con ESPACIOS Y TABULADORES: se limpia todo el espacio en
# blanco, no solo ' ' y '\r', o el escalar sale con tabs delante y ningun consumidor lo reconoce como numero.
wt_oracle_scalar() {  # uso: wt_oracle_scalar <sql>
  local sql="$1" ctx; ctx="$(remote_docker_ctx)"
  printf 'set head off feed off pages 0;\n%s\n' "$sql" \
    | on_intel "docker $ctx exec -i -e ORACLE_HOME='$PM_WT_ORACLE_HOME' '$WT_ORACLE_CONTAINER' bash -c 'export PATH=\$ORACLE_HOME/bin:\$PATH; exec sqlplus -S $PM_WT_ORACLE_USER/$PM_WT_ORACLE_PASS@localhost:1521/XE'" 2>/dev/null \
    | tr -d '[:blank:]\r' | grep -v '^$' | tail -1
}

# Readiness del Oracle del slot. Corre SIEMPRE, aunque el contenedor ya estuviera arriba: un guard de
# "Running -> return 0" deja pasar en silencio un init abortado a medias (schema incompleto).
#
# La sonda NO puede ser solo 'maquinas_pm': esa tabla la carga 2027-maquinas_pm.csv.ctl a MITAD del
# 3001-sqloader.sh, asi que da > 0 mucho antes de que terminen los ~30 loaders restantes y los seeds
# 9002-login-access.sql / 9003-menu-wiring.sql. Se exige el ULTIMO artefacto de datos del init: las filas de
# USUARIO_MODULO (9002), que corre despues de todo sqlldr. Con ambas poblado, el init llego al final.
wt_oracle_ready() {
  local ctx port n deadline menu; ctx="$(remote_docker_ctx)"
  # El puerto realmente publicado es la fuente de verdad: un contenedor viejo del mismo nombre pudo quedar
  # atado a otro puerto y el frontend del slot apuntaria a la instancia equivocada.
  port="$(on_intel "docker $ctx port '$WT_ORACLE_CONTAINER' 1521/tcp 2>/dev/null" 2>/dev/null | head -1 | sed 's/.*://' | tr -d '\r')"
  [ "$port" = "$WT_ORACLE_PORT" ] || { wt_die "el Oracle del slot publica :${port:-<ninguno>} y se esperaba :$WT_ORACLE_PORT; recrealo con 'make wt-down WT=<folder>' + 'make wt-up ... ORACLE=1'"; return 1; }
  wt_log "esperando readiness del Oracle del slot ($WT_ORACLE_CONTAINER; init completo ~91 s en frio, timeout ${PM_WT_ORACLE_READY_TIMEOUT}s) ..."
  deadline=$(( $(date +%s) + PM_WT_ORACLE_READY_TIMEOUT ))
  while :; do
    # LEAST(...) > 0 exige que AMBAS esten pobladas: el catalogo (mitad del sqlldr) y el acceso (fin del init).
    n="$(wt_oracle_scalar 'select least((select count(*) from maquinas_pm),(select count(*) from usuario_modulo)) from dual;')"
    case "$n" in
      ''|*[!0-9]*) : ;;
      *) if [ "$n" -gt 0 ]; then
           wt_log "Oracle del slot listo (:$WT_ORACLE_PORT; catalogo y accesos sembrados)"
           # Evidencia del cableado de menu (seed 9003 de la solucion); informativo, no bloquea.
           menu="$(wt_oracle_scalar "select count(*) from menu_contenido where pagina in ('CentroTrabajo.aspx','LineaFabricacion.aspx');")"
           case "$menu" in
             ''|*[!0-9]*) : ;;
             0) wt_log "aviso: el Oracle del slot no trae las rutas de menu de work-centers/manufacturing-lines (seed 9003 ausente en el arbol de la solucion)" ;;
             *) wt_log "menu: $menu ruta(s) de work-centers/manufacturing-lines presentes (seed 9003)" ;;
           esac
           return 0
         fi ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      wt_die "el Oracle del slot no quedo listo en ${PM_WT_ORACLE_READY_TIMEOUT}s (ultima respuesta: '${n:-<vacia>}'); logs: ssh $PM_REMOTE_SSH docker $ctx logs $WT_ORACLE_CONTAINER"
      return 1
    fi
    sleep 5
  done
}

_wt_ensure_oracle_locked() {
  local ctx; ctx="$(remote_docker_ctx)"
  # El check de puerto solo aplica si el contenedor aun no existe: si existe, el puerto ya es suyo.
  if ! wt_oracle_exists; then
    wt_check_port_free "$WT_ORACLE_PORT" "$WT_ORACLE_CONTAINER" "Oracle del slot" || return 1
  fi
  if wt_oracle_running; then
    wt_log "Oracle del slot ya corriendo ($WT_ORACLE_CONTAINER)"
  else
    wt_log "levantando Oracle del slot ($WT_ORACLE_CONTAINER -> :$WT_ORACLE_PORT; el init de un volumen nuevo tarda minutos) ..."
    compose up -d oracle || { wt_die "fallo el 'compose up' del Oracle del slot"; return 1; }
    # restart=no a proposito: con 'unless-stopped' un Oracle de un slot ya liberado resucita tras reboot del
    # docker y ocupa el puerto del siguiente dueno. La recuperacion es re-correr 'wt-up ... ORACLE=1'.
    on_intel "docker $ctx update --restart=no '$WT_ORACLE_CONTAINER' >/dev/null 2>&1" || true
  fi
  wt_oracle_ready || return 1
}

# Una invocacion por slot a la vez: dos wt-up del mismo slot en frio harian dos 'compose up' concurrentes.
wt_ensure_oracle() {
  wt_lock "oracle-wt${WT_SLOT}" _wt_ensure_oracle_locked
}

# Destruye contenedor + volumen + red del Oracle del slot y VERIFICA la ausencia. El camino es por NOMBRE, no
# por 'compose down': este ultimo depende del arbol remoto del worktree (que pudo cambiar) y su fallo se
# tragaria en silencio, liberando el slot con el Oracle vivo.
# El volumen se destruye a proposito: el slot se recicla y el camino con flag OFF (PGE950RT) muta los datos.
wt_oracle_down() {
  local ctx left_c left_v; ctx="$(remote_docker_ctx)"
  wt_log "retirando Oracle del slot ($WT_ORACLE_CONTAINER + volumen $WT_ORACLE_VOLUME) ..."
  on_intel "docker $ctx rm -f '$WT_ORACLE_CONTAINER' >/dev/null 2>&1; true"
  on_intel "docker $ctx volume rm '$WT_ORACLE_VOLUME' >/dev/null 2>&1; true"
  on_intel "docker $ctx network rm '$WT_ORACLE_NETWORK' >/dev/null 2>&1; true"
  left_c="$(on_intel "docker $ctx ps -a --filter 'name=^${WT_ORACLE_CONTAINER}\$' --format '{{.Names}}' 2>/dev/null" 2>/dev/null | tr -d '\r')"
  left_v="$(on_intel "docker $ctx volume ls --filter 'name=^${WT_ORACLE_VOLUME}\$' --format '{{.Name}}' 2>/dev/null" 2>/dev/null | tr -d '\r')"
  if [ -n "$left_c" ] || [ -n "$left_v" ]; then
    wt_die "el Oracle del slot no se elimino por completo (contenedor='$left_c' volumen='$left_v'); el slot NO se libera"
    return 1
  fi
  wt_log "Oracle del slot eliminado y verificado (contenedor y volumen ausentes)"
}

# --- API por worktree ---

# Verifica TEMPRANO (antes del rsync/build) que un puerto host este libre en macdata: falla claro si otro
# contenedor (distinto del propio, que el verbo recrea) ya lo publica. Sin esto el conflicto de bind solo
# aflora del 'docker run' tras el build completo (minutos).
wt_check_port_free() {  # uso: wt_check_port_free <puerto> <contenedor-propio> <etiqueta>
  local port="$1" own="$2" label="$3" ctx names rc holder; ctx="$(remote_docker_ctx)"
  # Falla-CERRADO: el rc del on_intel (ssh/docker) se captura ANTES de filtrar, sin que el pipe ni un '|| true'
  # lo enmascaren. Si la consulta falla, no se puede afirmar que el puerto este libre -> se aborta, no se procede.
  rc=0; names="$(on_intel "docker $ctx ps --filter 'publish=$port' --format '{{.Names}}' 2>/dev/null")" || rc=$?
  [ "$rc" -eq 0 ] || { wt_die "no se pudo verificar el puerto :$port en $PM_REMOTE_SSH (ssh/docker); no se procede (falla-cerrado)"; return 1; }
  holder="$(printf '%s' "$names" | tr -d '\r' | grep -v -x "$own" | head -n1 || true)"
  [ -z "$holder" ] || { wt_die "el puerto de $label :$port ya lo publica el contenedor '$holder' en $PM_REMOTE_SSH; baja ese stack o usa otro slot"; return 1; }
}

# uso: requiere PM_API_PORT + WT_SLOT.
wt_check_api_port_free() {
  wt_check_port_free "$PM_API_PORT" "pm-wt${WT_SLOT}-api" "API" || return 1
}

# Construye la imagen de la API desde el CODIGO DEL WORKTREE y corre su contenedor unido al SQL compartido
# y al bus. Connstrings por entorno; aislamiento del bus por prefijo de instancia wt<N>.
wt_up_api() {  # uso: wt_up_api <password>
  local pw="$1" ctx; ctx="$(remote_docker_ctx)"
  local cname="pm-wt${WT_SLOT}-api" img="pm-wt-api:wt${WT_SLOT}"
  local hl="http://127.0.0.1:$PM_API_PORT/health/live"
  # build desde el contexto del worktree (rsync de la solucion del worktree a su dir remoto).
  sync_solution_to_intel
  wt_log "build imagen $img (contexto $PM_REMOTE_SSH:$PM_REMOTE_SOLUTION_DIR; primera vez ~varios min) ..."
  on_intel "cd '$PM_REMOTE_SOLUTION_DIR' && docker $ctx build -t '$img' -f- ." < "$BASE_DIR/e2e/Dockerfile" \
    || { wt_die "fallo el build de la imagen de la API del worktree"; return 1; }
  # Retira las capas dangling que el rebuild del mismo tag deja huerfanas; evita que el disco del VM se sature.
  on_intel "docker $ctx image prune -f" || true
  # connstrings vistas desde el contenedor: SQL por alias de la red compartida; bus por alias del singleton.
  local cs ln sbcs
  cs="Server=$PM_SHARED_SQL_HOST,$PM_SHARED_SQL_PORT;Database=$PM_PLANNING_DB;User Id=sa;Password=$pw;TrustServerCertificate=True"
  ln="Server=$PM_SHARED_SQL_HOST,$PM_SHARED_SQL_PORT;Database=$PM_WT_LN_DB;User Id=sa;Password=$pw;TrustServerCertificate=True"
  sbcs="Endpoint=sb://servicebus:5672;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;"
  cs="$(wt_esc "$cs")"; ln="$(wt_esc "$ln")"; sbcs="$(wt_esc "$sbcs")"
  # Con el Oracle del slot activo la API lee ControlPiso de EL (alias 'oracle' dentro de pm-wt<N>_default) y la
  # fuente viva de paridad pasa de csv a oracle. Sin el, el comportamiento queda intacto (csv, sin CtrlPiso).
  local psrc oracle_env="" oracle_net=""
  if [ "${WT_ORACLE_ACTIVE:-0}" = "1" ]; then
    # Destino Oracle del slot: alias de red 'oracle' + sid XE (espeja el sid=XE de pm_ctrlpiso_connstr,
    # lib/common.sh:190). Fuente unica en wt_up_api para el connstring de CtrlPiso y para la allowlist del
    # guard, de modo que un cambio del destino del slot arrastre ambos.
    local ora_host=oracle ora_sid=XE
    local ctrlcs; ctrlcs="$(wt_esc "$(pm_ctrlpiso_connstr "$ora_host" 1521)")"
    psrc="${PM_PARITY_LEGACY_SOURCE:-oracle}"
    oracle_env=" -e ConnectionStrings__CtrlPiso='$ctrlcs'"
    # Kill-switch global de mutacion Oracle (nivel 0, ADR-0010): default OFF. Se enciende SOLO cuando el slot
    # cablea su propio Oracle XE desechable (WT_ORACLE_ACTIVE=1), el destino DEV sancionado, de modo que el gate
    # y el E2E (seed/replica del flag OFF) escriban en el XE del slot; dev arranca sin la var (replica apagada).
    oracle_env="$oracle_env -e Oracle__WriteGuard__DmlEnabled=true"
    # Allowlist DEV del guard Oracle derivada del destino LEGITIMO del slot (XE): no relaja el guard, lo
    # habilita para el contenedor de la API. host=alias de red del slot; dbName=sid del slot. AllowedServerHosts
    # se pasa vacio a proposito: ReadStringArray filtra la cadena vacia y ese sub-chequeo se omite por diseno
    # (el Oracle del slot es XE y no expone el server-host que si tiene Prolec), igual que el molde test-side
    # BuildDevAllowlist. Docker interpreta '-e KEY=' como variable con valor vacio (no como herencia del host).
    oracle_env="$oracle_env -e Oracle__WriteGuard__AllowedHosts__0='$ora_host'"
    oracle_env="$oracle_env -e Oracle__WriteGuard__AllowedDbNames__0='$ora_sid'"
    oracle_env="$oracle_env -e Oracle__WriteGuard__AllowedServerHosts__0=''"
    oracle_net=" && docker $ctx network connect '$WT_ORACLE_NETWORK' '$cname'"
  else
    psrc="${PM_PARITY_LEGACY_SOURCE:-csv}"
  fi
  wt_log "run contenedor $cname (redes: $PM_SHARED_SQL_NETWORK + ${PM_WT_BUS_PROJECT}_default$([ "${WT_ORACLE_ACTIVE:-0}" = "1" ] && printf ' + %s' "$WT_ORACLE_NETWORK"); sql $PM_SHARED_SQL_HOST/$PM_PLANNING_DB; bus prefix $WT_SB_PREFIX; paridad $psrc; publica $PM_API_PORT->8080) ..."
  # create + connect (redes adicionales) + start: evita la ventana en que la API arranca antes de unir el bus.
  # FeatureManagement__FlagCacheTtlSeconds=0 desactiva el caché en-proceso del lector de flags (default prod
  # 45 s): en el slot un flag fijado por UPDATE SQL directo se ve en la lectura siguiente, dando determinismo
  # a los tests de API física con flag (I3/I4/I8). Se inyecta en TODO slot, no solo con Oracle activo.
  on_intel "docker $ctx rm -f '$cname' >/dev/null 2>&1; \
    docker $ctx create --name '$cname' --network '$PM_SHARED_SQL_NETWORK' -p '$PM_API_PORT:8080' \
      -e ASPNETCORE_ENVIRONMENT=IntegrationTest \
      -e ConnectionStrings__Planning='$cs' -e ConnectionStrings__Ln='$ln' \
      -e ServiceBus__ConnectionString='$sbcs' -e ServiceBus__SubscriptionPrefix='$WT_SB_PREFIX' \
      -e FeatureManagement__FlagCacheTtlSeconds=0 \
      -e Parity__LegacySource='$psrc'$oracle_env $(pm_parity_env_flags) '$img' >/dev/null \
    && docker $ctx network connect '${PM_WT_BUS_PROJECT}_default' '$cname'$oracle_net \
    && docker $ctx start '$cname' >/dev/null" \
    || { wt_die "fallo el create/run del contenedor de la API"; return 1; }
  # espera /health/live (corte temprano si el contenedor muere).
  local i rc; for i in $(seq 1 150); do
    rc=0; on_intel "curl -fsS -o /dev/null '$hl' 2>/dev/null && exit 0; [ \"\$(docker $ctx inspect -f '{{.State.Running}}' '$cname' 2>/dev/null)\" = true ] && exit 1; exit 2" || rc=$?
    case "$rc" in
      0) wt_log "API up en $PM_REMOTE_SSH (~${i}s)"; return 0 ;;
      2) wt_die "el contenedor $cname murio; logs: ssh $PM_REMOTE_SSH docker $ctx logs $cname"; return 1 ;;
    esac
    sleep 1
  done
  wt_die "la API no respondio /health/live; logs: ssh $PM_REMOTE_SSH docker $ctx logs $cname"; return 1
}

# Baja la BD de producto del worktree del SQL compartido (mata conexiones; idempotente).
wt_drop_planning() {  # uso: wt_drop_planning <password>
  local pw="$1"
  wt_log "dropeando BD de producto '$PM_PLANNING_DB' del SQL compartido ..."
  local sql="IF DB_ID(N'$PM_PLANNING_DB') IS NOT NULL BEGIN ALTER DATABASE [$PM_PLANNING_DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$PM_PLANNING_DB]; END"
  wt_shared_exec "$pw" "$sql" || wt_log "aviso: no se pudo dropear '$PM_PLANNING_DB' (quiza ya no existe)"
}

# --- Presupuesto de aprovisionamiento (topes reales: disco/RAM de la VM colima, docker, guest, slots) ---
# El limite efectivo del aprovisionamiento NO es el disco del host (6.7 TiB) sino el disco de la VM colima
# (/dev/vdb1, 80 GiB) donde viven imagenes y volumenes: se lleno en D6 (2026-07-05, CREATE DATABASE al 100%).
# Toda medicion remota va por on_intel (el contexto docker vive en macdata, no resuelve desde la M1) y es
# best-effort: sin REMOTE o con colima sin responder cada metrica degrada a vacio, nunca aborta el verbo que la
# consulta.

# Perfil colima remoto derivado del contexto docker (colima-<perfil>); fallback nlc3runner.
wt_colima_profile() { local p="${PM_REMOTE_DOCKER_CONTEXT#colima-}"; [ -n "$p" ] || p="nlc3runner"; printf '%s' "$p"; }

# Verdadero si el argumento es un entero decimal no vacio.
wt_is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Formatea bytes -> "N.N" (GB, una decimal). Vacio si la entrada no es numerica.
wt_gb() { wt_is_num "${1:-}" || return 0; awk -v b="$1" 'BEGIN{printf "%.1f", b/1073741824}'; }

# Edad (segundos, sobre 'created') sobre la cual wt-ls/wt-info marcan un slot como "viejo": aviso informativo de
# antiguedad, independiente del reclaim. El reclaim automatico por arrendamiento (pid muerto + heartbeat >
# PM_WT_LEASE_TTL) SI se implementa (wt_lease_reclaimable / wt_reclaim_dead_leases); wt-ls tambien marca
# "[reclamable]" el slot cuyo arrendamiento wt-gc retiraria. Default 24 h.
WT_AGE_WARN_SECS="${PM_WT_AGE_WARN_SECS:-86400}"

# Edad transcurrida (segundos) de un timestamp ISO-8601 UTC (p. ej. 2026-07-15T00:57:59Z). Vacio si no parsea.
# date de macOS/BSD: -j -f parsea sin fijar reloj; TZ=UTC interpreta el string como UTC (sin el se leeria local).
wt_age_secs() {  # uso: wt_age_secs <iso-utc>
  local iso="${1:-}" epoch
  [ -n "$iso" ] || return 0
  epoch="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null)" || return 0
  wt_is_num "$epoch" || return 0
  printf '%s' "$(( $(date +%s) - epoch ))"
}

# Formatea segundos -> edad compacta (45m, 3h4m, 2d5h). Vacio si la entrada no es numerica.
wt_age_fmt() {  # uso: wt_age_fmt <segundos>
  wt_is_num "${1:-}" || return 0
  local s="$1" d h m
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

# Valor de la clave 'clave=valor' en un blob multilinea (vacio si ausente).
wt_kv() { printf '%s\n' "${1:-}" | awk -F= -v k="${2:-}" '$1==k{print $2; exit}'; }

# Disco /dev/vdb1 de la VM colima -> "totalBytes availBytes usePct" (vacio si no se pudo medir). Se ancla por
# device (no por mount, que es /var/lib/cni, no /). Fail-open.
wt_colima_disk_line() {
  [ -n "$PM_REMOTE_SSH" ] || return 0
  local prof; prof="$(wt_colima_profile)"
  on_intel "colima ssh -p '$prof' -- df -B1 /dev/vdb1" 2>/dev/null | awk '$1 ~ /vdb1/ {print $2, $4, $5; exit}' || true
}

# RAM de la VM colima -> "totalBytes availBytes" (vacio si no se pudo medir). Fail-open.
wt_colima_ram_line() {
  [ -n "$PM_REMOTE_SSH" ] || return 0
  local prof; prof="$(wt_colima_profile)"
  on_intel "colima ssh -p '$prof' -- free -b" 2>/dev/null | awk '/^Mem:/{print $2, $NF; exit}' || true
}

# docker system df del docker remoto: reclaimable por tipo en una linea (informativo, NO entra en la aritmetica
# del umbral; el prune-hook de wt_up_api retira las capas dangling). Vacio si no se pudo medir. Fail-open.
wt_docker_reclaimable() {
  [ -n "$PM_REMOTE_SSH" ] || return 0
  on_intel "docker $(remote_docker_ctx) system df --format '{{.Type}}={{.Reclaimable}}'" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' || true
}

# Contadores del guest Windows via guest-mem.sh (mismo path remoto que sites-status.sh en cmd_wt_gc). Blob
# clave=valor; vacio si el guest no responde. Fail-open (best-effort).
wt_guest_mem_line() {
  [ -n "$PM_REMOTE_SSH" ] || return 0
  on_intel "bash ~/pm-host-windows/scripts/guest-mem.sh" 2>/dev/null || true
}

# N de slots vivos = renglones del registro (folder->slot; el archivo no lleva encabezado).
wt_live_slots() {
  [ -f "$PM_WT_REGISTRY" ] || { printf '0'; return 0; }
  awk 'END{print NR+0}' "$PM_WT_REGISTRY" 2>/dev/null || printf '0'
}

# Gate de disco de wt-up: rechaza aprovisionar si el disco de la VM colima esta por debajo de PM_WT_MIN_DISK_GB,
# ANTES de gastar rsync/build (en D6 el fallo aparecia a mitad del seed). Fail-open: si la medicion FALLA (colima
# sin responder, parse vacio) avisa y continua; SOLO aborta con una medicion exitosa por debajo del umbral.
wt_disk_gate() {
  local free min_bytes
  free="$(wt_colima_disk_line | awk '{print $2}')"
  if ! wt_is_num "$free"; then
    wt_log "aviso: no se pudo medir el disco de la VM colima (colima sin responder o parse vacio); se continua sin gate de disco"
    return 0
  fi
  min_bytes=$(( PM_WT_MIN_DISK_GB * 1073741824 ))
  if [ "$free" -lt "$min_bytes" ]; then
    # Antes de rechazar, intenta recuperar disco reclamando arrendamientos muertos (pid muerto + heartbeat vencido):
    # su Oracle+volumen+BD liberan el /dev/vdb1 de la VM colima. Solo reclama abandonados; no toca duenas vivas.
    local reclaimed
    wt_log "disco bajo umbral ($(wt_gb "$free") GB < $PM_WT_MIN_DISK_GB GB): reclamando arrendamientos muertos antes de rechazar ..."
    reclaimed="$(wt_reclaim_dead_leases 0)"
    if [ "${reclaimed:-0}" -gt 0 ]; then
      free="$(wt_colima_disk_line | awk '{print $2}')"
      if wt_is_num "$free" && [ "$free" -ge "$min_bytes" ]; then
        wt_log "disco recuperado tras reclamar $reclaimed slot(s): $(wt_gb "$free") GB libres >= umbral $PM_WT_MIN_DISK_GB GB"
        return 0
      fi
    fi
    wt_log "ERROR: disco de la VM colima por debajo del umbral: $(wt_gb "$free") GB libres < $PM_WT_MIN_DISK_GB GB (PM_WT_MIN_DISK_GB)."
    wt_log "       Es el disco /dev/vdb1 de la VM colima (NO el host de 6.7 TiB). Baja worktrees (make wt-down) o corre make wt-gc FORCE=1; sube PM_WT_MIN_DISK_GB para forzar."
    return 1
  fi
  wt_log "disco de la VM colima OK: $(wt_gb "$free") GB libres >= umbral $PM_WT_MIN_DISK_GB GB"
}

# Gate de RAM de wt-up: rechaza aprovisionar si la RAM disponible de la VM colima esta por debajo de
# PM_WT_MIN_MEM_GB, ANTES de gastar rsync/build. Espejo de wt_disk_gate. Motivo: con la RAM saturada por varios
# slots, el store del bus compartido (pm-shared-sbsqledge-1) hace OOM (Error 701) y tumba pruebas de OTRAS
# sesiones. Fail-open: si la medicion FALLA (colima sin responder, parse vacio) avisa y continua; SOLO aborta con
# una medicion exitosa por debajo del umbral. Reclama arrendamientos muertos antes de rechazar (usualmente no-op
# porque cmd_wt_up ya reclamo al tope por I1; se conserva por robustez si ese orden cambia).
wt_mem_gate() {
  local avail min_bytes
  avail="$(wt_colima_ram_line | awk '{print $2}')"
  if ! wt_is_num "$avail"; then
    wt_log "aviso: no se pudo medir la RAM de la VM colima (colima sin responder o parse vacio); se continua sin gate de RAM"
    return 0
  fi
  min_bytes=$(( PM_WT_MIN_MEM_GB * 1073741824 ))
  if [ "$avail" -lt "$min_bytes" ]; then
    local reclaimed
    wt_log "RAM disponible bajo umbral ($(wt_gb "$avail") GB < $PM_WT_MIN_MEM_GB GB): reclamando arrendamientos muertos antes de rechazar ..."
    reclaimed="$(wt_reclaim_dead_leases 0)"
    if [ "${reclaimed:-0}" -gt 0 ]; then
      avail="$(wt_colima_ram_line | awk '{print $2}')"
      if wt_is_num "$avail" && [ "$avail" -ge "$min_bytes" ]; then
        wt_log "RAM recuperada tras reclamar $reclaimed slot(s): $(wt_gb "$avail") GB disponibles >= umbral $PM_WT_MIN_MEM_GB GB"
        return 0
      fi
    fi
    wt_log "ERROR: RAM disponible de la VM colima por debajo del umbral: $(wt_gb "$avail") GB < $PM_WT_MIN_MEM_GB GB (PM_WT_MIN_MEM_GB)."
    wt_log "       El store del bus compartido puede OOMear (Error 701). Baja worktrees (make wt-down) o espera a que liberen; sube PM_WT_MIN_MEM_GB para forzar."
    return 1
  fi
  wt_log "RAM de la VM colima OK: $(wt_gb "$avail") GB disponibles >= umbral $PM_WT_MIN_MEM_GB GB"
}

# Seccion "Presupuesto" de wt-info: topes reales del aprovisionamiento. Best-effort (cada metrica no medible
# degrada a 'n/d'); las lecturas remotas van por on_intel. Imprime las lineas ya indentadas para el heredoc.
wt_budget_lines() {
  local dl rl recl gm total free pct ram_total ram_avail g_av g_pg g_w3 live min_bytes status
  dl="$(wt_colima_disk_line)"
  rl="$(wt_colima_ram_line)"
  recl="$(wt_docker_reclaimable)"
  gm="$(wt_guest_mem_line)"
  total="$(printf '%s' "$dl" | awk '{print $1}')"
  free="$(printf '%s' "$dl" | awk '{print $2}')"
  pct="$(printf '%s' "$dl" | awk '{print $3}')"
  ram_total="$(printf '%s' "$rl" | awk '{print $1}')"
  ram_avail="$(printf '%s' "$rl" | awk '{print $2}')"
  g_av="$(wt_kv "$gm" availableMB)"
  g_pg="$(wt_kv "$gm" pagesPerSec)"
  g_w3="$(wt_kv "$gm" w3wpCount)"
  live="$(wt_live_slots)"
  min_bytes=$(( PM_WT_MIN_DISK_GB * 1073741824 ))
  status="OK"
  if wt_is_num "$free" && [ "$free" -lt "$min_bytes" ]; then status="BAJO UMBRAL"; fi

  echo "  Presupuesto (topes reales del aprovisionamiento)"
  if wt_is_num "$free"; then
    echo "    disco VM colima   $(wt_gb "$free") GB libres / $(wt_gb "$total") GB (${pct} usado)   umbral wt-up: ${PM_WT_MIN_DISK_GB} GB   [${status}]"
  else
    echo "    disco VM colima   n/d (sin REMOTE=macdata o colima sin responder)   umbral wt-up: ${PM_WT_MIN_DISK_GB} GB"
  fi
  echo "    docker reclamable ${recl:-n/d}"
  if wt_is_num "$ram_avail"; then
    echo "    RAM VM colima     $(wt_gb "$ram_avail") GB disponibles / $(wt_gb "$ram_total") GB"
  else
    echo "    RAM VM colima     n/d"
  fi
  echo "    guest Windows     availableMB=${g_av:-n/d} pagesPerSec=${g_pg:-n/d} w3wp=${g_w3:-n/d}"
  echo "    slots vivos       ${live} / ${PM_WT_SLOTS} (PM_WT_SLOTS)"
}

# --- Verbos ---

cmd_wt_up() {
  wt_require_intel || return 1
  # Higiene incondicional (I1): reclama arrendamientos MUERTOS (pid muerto por kill -0 + heartbeat > PM_WT_LEASE_TTL)
  # en CADA wt-up, no solo con pool lleno (:759) o disco bajo (:690). Un zombi sangra RAM/volumen hasta el OOM del
  # bus compartido aunque haya numeros de slot libres y disco sano; asi cualquier sesion que aprovisiona lo limpia.
  # wt_lease_reclaimable protege a las duenas VIVAS (kill -0); el conteo va a stdout -> se descarta con >/dev/null.
  wt_reclaim_dead_leases 0 >/dev/null || true
  # Gate de disco de la VM colima ANTES de asignar el slot (D44): solo mide disco de colima (no depende del slot),
  # asi un rechazo por umbral NO consume una fila de slots.tsv. Fail-open ante error de medicion (req5). Queda
  # FUERA del up-lock (no toca el slot); no confundir con el falla-cerrado de wt_check_port_free.
  wt_disk_gate || return 1
  wt_mem_gate || return 1
  local folder slot reclaimed
  folder="$(wt_resolve_folder)" || return 1
  # La asignacion de slot se serializa por el registro (aparte del up-lock): folders distintos no compiten.
  slot="$(wt_registry_lock wt_slot_assign "$folder")" || slot=""
  if [ -z "$slot" ]; then
    # Pool lleno: en vez de abortar, recupera arrendamientos muertos (pid muerto + heartbeat > PM_WT_LEASE_TTL) y
    # reintenta. Un pool lleno de slots abandonados se auto-recupera; los slots de duenas vivas no se tocan.
    wt_log "sin slots libres: reclamando arrendamientos muertos (pid muerto + heartbeat > ${PM_WT_LEASE_TTL}s) ..."
    # max=1: basta liberar UN slot (el mas viejo muerto, por oldest-first) para reintentar la asignacion.
    reclaimed="$(wt_reclaim_dead_leases 0 1)"
    if [ "${reclaimed:-0}" -gt 0 ]; then
      wt_log "reclamados $reclaimed slot(s); reintentando la asignacion"
      slot="$(wt_registry_lock wt_slot_assign "$folder")" || slot=""
    fi
    [ -n "$slot" ] || { wt_die "sin slots libres (PM_WT_SLOTS=$PM_WT_SLOTS) y sin arrendamientos reclamables; baja un worktree (make wt-down) o sube PM_WT_SLOTS"; return 1; }
  fi
  # Refresca el arrendamiento (pid+heartbeat) del slot: cubre el reuso (wt_slot_assign no lo toca al reusar) y
  # marca el slot como en uso activo para que no lo reclame otra sesion durante esta corrida.
  wt_registry_lock wt_slot_touch "$folder"
  # Exclusion por slot (D29-2): dos wt-up del MISMO folder resuelven el mismo slot y se pisan rsync/build/run. El
  # aprovisionamiento se serializa por 'wt_lock up-<slot>'; el segundo espera (o reclama si el dueno murio). Los
  # locks internos (ln/bus/seed/bridge/oracle-wt<N>) llevan otros nombres: sin deadlock. wt_lock corre el helper
  # como llamada NUEVA -> folder/slot viajan por args (los locals de cmd_wt_up no cruzan; los globals de wt_derive si).
  # El anidamiento de wt_lock hace que el 'trap RETURN' de cada helper interno dispare un drop del up-lock; es
  # idempotente (_wt_lock_drop es no-op si el lock ya se solto), asi que los drops NO son 1:1 con los acquires.
  wt_lock "up-${slot}" _cmd_wt_up_locked "$folder" "$slot"
}

# Cuerpo de aprovisionamiento de un slot, serializado por 'wt_lock up-<slot>' (ver cmd_wt_up). Corre como llamada
# nueva: recibe folder ($1) y slot ($2) por args (los locals de cmd_wt_up no cruzan); los globals que fija
# wt_derive (WT_SLOT, PM_*, WT_ORACLE_*) SI cruzan a las funciones que invoca.
_cmd_wt_up_locked() {
  local folder="$1" slot="$2"
  wt_derive "$slot"
  wt_log "worktree '$folder' -> slot $slot (proyecto $PM_PROJECT, offset $PM_PORT_OFFSET, API :$PM_API_PORT, BD $PM_PLANNING_DB, bus $WT_SB_PREFIX)"

  # Codigo de la API (build): override explicito por PM_WT_SOLUTION_DIR; si no, el worktree de codigo
  # worktrees/<folder> SOLO si es la solucion .NET (marcador PL.PM.sln, mismo criterio que resolve_solution_dir);
  # si no, el default de load_env (la solucion central) -> util para smoke sin un worktree git aparte.
  if [ -n "${PM_WT_SOLUTION_DIR:-}" ]; then
    PM_SOLUTION_DIR="$PM_WT_SOLUTION_DIR"
  elif [ -f "$WRAPPER_DIR/worktrees/$folder/PL.PM.sln" ]; then
    PM_SOLUTION_DIR="$WRAPPER_DIR/worktrees/$folder"
  fi
  # Falla temprana y clara si la solucion resuelta no es pl-programa-maestro (evita un build de Docker confuso
  # cuando 'folder' es un worktree de la legacy o del propio sidecar, que tienen .git pero no PL.PM.sln).
  [ -f "$PM_SOLUTION_DIR/PL.PM.sln" ] || { wt_die "la solucion '$PM_SOLUTION_DIR' (worktree '$folder') no contiene PL.PM.sln; wt-up es para pl-programa-maestro: corre dentro de su worktree o fija SOLUTION=<path>"; return 1; }
  # Re-deriva containers/compose del PM_SOLUTION_DIR resuelto (invariante containers==solution/containers):
  # asi el seed (sync_to_intel) y el build de la API (sync_solution_to_intel) salen del MISMO arbol.
  PM_CONTAINERS_DIR="$PM_SOLUTION_DIR/containers"; COMPOSE_DIR="$PM_CONTAINERS_DIR/compose"
  # Dir remoto por slot en macdata (aisla el contexto de build entre worktrees).
  PM_REMOTE_SOLUTION_DIR="pm-solution-wt${slot}"
  # Dir remoto de containers/ POR SLOT (no el compartido 'pm-containers'): el seed enumera loaders de
  # <este dir>/sql/init; un dir compartido lo repuebla un worktree concurrente basado en un commit viejo
  # durante la ventana del build de la API, colando loaders stale (p. ej. 0204/0205 pre-C6). Aislar por slot
  # garantiza que la enumeracion refleje SIEMPRE el arbol desplegado de ESTE worktree.
  PM_REMOTE_DIR="pm-containers-wt${slot}"
  wt_log "codigo de la API: $PM_SOLUTION_DIR -> $PM_REMOTE_SSH:$PM_REMOTE_SOLUTION_DIR; containers -> $PM_REMOTE_SSH:$PM_REMOTE_DIR"

  # Falla temprana si el puerto de API del slot ya esta ocupado en macdata (antes del rsync/build).
  wt_check_api_port_free || return 1

  local pw; pw="$(wt_shared_sql_password)" || return 1

  # 1) rsync de containers/ (scripts + CSV de seed) a macdata; resuelve su ruta absoluta para docker -v/cp.
  sync_to_intel || return 1
  WT_REMOTE_CONTAINERS_ABS="$(on_intel "cd '$PM_REMOTE_DIR' && pwd" | tr -d '\r')" || WT_REMOTE_CONTAINERS_ABS=""
  [ -n "$WT_REMOTE_CONTAINERS_ABS" ] || { wt_die "no se resolvio la ruta remota de containers"; return 1; }

  # 2) singletons compartidos
  wt_shared_sql_check || return 1
  # Lock dedicado del seed (F2 de 260702-2244): wt_push_seed_assets hace 'docker cp' de los CSV a rutas
  # COMPARTIDAS del motor SQL (/pmdata, /seed-ctrlpiso); dos wt-up concurrentes en slots distintos se
  # sobreescribirian. Serializa el push (distinto del up-lock, que aisla por slot). No usa el lock del registro.
  wt_lock seed wt_push_seed_assets || return 1
  # Lock dedicado del seed LN: serializa el check-then-act (DROP+CREATE de pm_erpln106) entre wt-up
  # concurrentes en frio; sin el, dos verian la referencia ausente y la sembrarian en paralelo (corrupcion).
  wt_lock ln wt_ensure_ln_singleton "$pw" || return 1
  # Lock dedicado del bus: serializa el check-then-act entre wt-up concurrentes (solo uno hace el cold-start
  # del singleton; los demas esperan y lo ven arriba). No usa el lock del registro para no serializar el seed/build.
  wt_lock bus wt_ensure_bus || return 1

  # 3) Oracle ControlPiso del slot (lazy). Autodeteccion: si el contenedor del slot ya corre y llega ORACLE=0,
  # se adopta el wiring Oracle en vez de recrear la API en modo csv (divergencia silenciosa: el frontend del
  # slot seguiria apuntando al Oracle del slot mientras el backend leeria snapshots CSV).
  WT_ORACLE_ACTIVE=0
  if [ "${PM_WT_ORACLE:-0}" = "1" ]; then
    WT_ORACLE_ACTIVE=1
  elif wt_oracle_running; then
    wt_log "AVISO: '$WT_ORACLE_CONTAINER' esta corriendo y ORACLE=0 -> se adopta el wiring Oracle del slot."
    wt_log "       Para volver a csv: 'make wt-down WT=$folder' (retira el Oracle) y re-aprovisiona sin ORACLE=1."
    WT_ORACLE_ACTIVE=1
  fi
  if [ "$WT_ORACLE_ACTIVE" = "1" ]; then
    wt_ensure_oracle || return 1
  fi

  # 4) per-worktree: API ANTES del seed. La API aplica las migraciones EF al arrancar (entorno
  # IntegrationTest => !Production): crea la BD por-slot y el DDL de todos los schemas. Recien entonces
  # corre el seed data-only de la BD de producto (los loaders requieren las tablas ya creadas por EF).
  wt_up_api "$pw" || return 1
  wt_seed_planning "$pw" || return 1

  echo ""
  echo "[wt] worktree '$folder' (slot $slot) ARRIBA:"
  echo "[wt]   API      -> http://$PM_REMOTE_SSH:$PM_API_PORT/health/live"
  echo "[wt]   SQL      -> $PM_SHARED_SQL_HOST/$PM_PLANNING_DB (compartido; publicado en $PM_REMOTE_SSH:$PM_SHARED_SQL_PUBLISHED)"
  echo "[wt]   LN ref   -> $PM_WT_LN_DB (compartido, read-only)"
  echo "[wt]   bus      -> $PM_WT_BUS_PROJECT (prefix $WT_SB_PREFIX)"
  if [ "$WT_ORACLE_ACTIVE" = "1" ]; then
    echo "[wt]   Oracle   -> $WT_ORACLE_CONTAINER (propio del slot; $PM_REMOTE_SSH:$WT_ORACLE_PORT, guest 172.16.128.1:$WT_ORACLE_PORT)"
  else
    echo "[wt]   Oracle   -> sin Oracle del slot (ORACLE=1 para aprovisionarlo; paridad en modo csv)"
  fi
  echo "[wt]   frontend -> 'make e2e-up WT=$folder LEGACYSRC=<path>' publica el site $WT_SITE_NAME :$WT_SITE_PORT (tunel $WT_TUNNEL_PORT)"
}

cmd_wt_down() {
  wt_require_intel || return 1
  local folder slot ctx; ctx="$(remote_docker_ctx)"
  folder="$(wt_resolve_folder)" || return 1
  slot="$(wt_slot_lookup "$folder")"
  [ -n "$slot" ] || { wt_log "worktree '$folder' no esta en el registro; nada que bajar"; return 0; }
  wt_derive "$slot"
  wt_log "bajando worktree '$folder' (slot $slot) ..."
  on_intel "docker $ctx rm -f 'pm-wt${slot}-api' >/dev/null 2>&1; true"
  # El Oracle del slot se retira ANTES de liberar el slot y su ausencia se VERIFICA: si sobreviviera, el
  # siguiente dueno del slot heredaria los datos que el camino con flag OFF (PGE950RT) haya mutado.
  if wt_oracle_exists; then
    wt_oracle_down || { wt_die "el slot $slot NO se libera: revisa '$WT_ORACLE_CONTAINER' en $PM_REMOTE_SSH"; return 1; }
  fi
  local pw; pw="$(wt_shared_sql_password)" && wt_drop_planning "$pw" || wt_log "aviso: no se dropeo la BD (sin password del SQL compartido)"
  wt_registry_lock wt_slot_release "$folder"
  wt_log "worktree '$folder' bajado y slot $slot liberado (singletons compartidos intactos)"
  wt_log "nota: el site del legado no lo baja este verbo; usa 'make e2e-down WT=$folder' (o 'make legacy-site-down SLOT=$slot')"
}

cmd_wt_ls() {
  # Resumen de presupuesto (disco libre VM colima + slots vivos): best-effort, degrada sin abortar. Este verbo
  # no exige remoto (no llama wt_require_intel); sin REMOTE=macdata el disco sale 'n/d'.
  local free disk_txt live
  free="$(wt_colima_disk_line | awk '{print $2}')"
  if wt_is_num "$free"; then disk_txt="$(wt_gb "$free") GB libres"; else disk_txt="n/d (sin REMOTE=macdata)"; fi
  live="$(wt_live_slots)"
  if [ ! -s "$PM_WT_REGISTRY" ]; then
    echo "[wt] registro vacio ($PM_WT_REGISTRY)"
  else
    printf 'folder\tslot\tproject\toffset\tcreated\tage\n'
    local f s pr off cr pid hb secs age
    while IFS=$'\t' read -r f s pr off cr pid hb; do
      [ -n "$f" ] || continue
      secs="$(wt_age_secs "$cr")"; age="$(wt_age_fmt "$secs")"; [ -n "$age" ] || age="n/d"
      if wt_is_num "$secs" && [ "$secs" -ge "$WT_AGE_WARN_SECS" ]; then age="$age [viejo]"; fi
      # "[reclamable]": arrendamiento muerto (pid muerto + heartbeat/created > TTL) que wt-gc FORCE=1 retiraria.
      if wt_lease_reclaimable "$pid" "$hb" "$cr"; then age="$age [reclamable]"; fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$f" "$s" "$pr" "$off" "$cr" "$age"
    done < "$PM_WT_REGISTRY"
  fi
  echo "[wt] presupuesto: disco VM colima ${disk_txt}   slots vivos ${live}/${PM_WT_SLOTS} (PM_WT_SLOTS)"
}

cmd_wt_status() {
  wt_require_intel || return 1
  local ctx; ctx="$(remote_docker_ctx)"
  wt_shared_sql_check || true
  echo "[wt] contenedores PM por worktree en $PM_REMOTE_SSH (API y Oracle):"
  on_intel "docker $ctx ps --filter 'name=pm-wt' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" || true
  echo "[wt] bus PM-owned ($PM_WT_BUS_PROJECT):"
  on_intel "docker $ctx ps --filter 'name=${PM_WT_BUS_PROJECT}-' --format 'table {{.Names}}\t{{.Status}}'" || true
}

# "Que slot es mio": imprime la derivacion COMPLETA del slot de un worktree. Es el contrato que consulta una
# sesion antes de operar, para no invadir los puertos ni los contenedores de otra.
cmd_wt_info() {
  local folder slot
  folder="$(wt_resolve_folder)" || return 1
  slot="$(wt_slot_lookup "$folder")"
  if [ -z "$slot" ]; then
    echo "[wt] el worktree '$folder' no tiene slot asignado (corre 'make wt-up WT=$folder')"
    return 1
  fi
  wt_derive "$slot"
  # Consultar el slot propio es señal de vida: refresca el arrendamiento (pid+heartbeat) para que no lo reclame otra
  # sesion mientras esta se apoya en wt-info. Idempotente, bajo lock del registro.
  wt_registry_lock wt_slot_touch "$folder"
  # Presupuesto medido ANTES del heredoc (el heredoc solo interpola $var; no ejecuta subcomandos). Best-effort.
  local budget=""
  budget="$(wt_budget_lines)" || true
  # Edad ('created', informativa) y estado del arrendamiento (pid/heartbeat, cols 6/7). El reclaim por TTL SI se
  # implementa (wt_lease_reclaimable): aqui se refresco el heartbeat, asi que este slot NO figura reclamable.
  local created pid hb secs age old="" lease=""
  created="$(awk -F'\t' -v f="$folder" '$1==f{print $5; exit}' "$PM_WT_REGISTRY" 2>/dev/null)"
  pid="$(awk -F'\t' -v f="$folder" '$1==f{print $6; exit}' "$PM_WT_REGISTRY" 2>/dev/null)"
  hb="$(awk -F'\t' -v f="$folder" '$1==f{print $7; exit}' "$PM_WT_REGISTRY" 2>/dev/null)"
  secs="$(wt_age_secs "$created")"; age="$(wt_age_fmt "$secs")"
  if wt_is_num "$secs" && [ "$secs" -ge "$WT_AGE_WARN_SECS" ]; then old=" [viejo]"; fi
  lease="arrendamiento pid ${pid:-<ninguno>}, heartbeat ${hb:-<created>}, TTL ${PM_WT_LEASE_TTL}s"
  cat <<EOF
[wt] worktree '$folder' -> slot $slot   (creado ${created:-n/d}; edad ${age:-n/d}${old}; ${lease})

  Backend (docker en ${PM_REMOTE_SSH:-macdata})
    contenedor API    pm-wt${slot}-api            puerto host ${PM_API_PORT}   (guest: ${PM_GUEST_GATEWAY}:${PM_API_PORT})
    BD planning       ${PM_PLANNING_DB}                 (SQL compartido ${PM_SHARED_SQL_HOST}:${PM_SHARED_SQL_PORT})
    prefijo de bus    ${WT_SB_PREFIX}                        (broker singleton ${PM_WT_BUS_PROJECT})
    contenedor Oracle ${WT_ORACLE_CONTAINER}    puerto host ${WT_ORACLE_PORT}  (guest: ${PM_GUEST_GATEWAY}:${WT_ORACLE_PORT})
    volumen Oracle    ${WT_ORACLE_VOLUME}
    red compose       ${WT_ORACLE_NETWORK}
    dirs remotos      pm-solution-wt${slot} / pm-containers-wt${slot}

  Frontend legado (guest ${PM_GUEST_WINHOST})
    site y app pool   ${WT_SITE_NAME}                    binding ${WT_SITE_PORT}
    arbol fuente      C:\\wt${slot}\\CargaPlantaPT_LN
    raiz del site     C:\\inetpub\\pmroot-wt${slot}
    vdir              ProgramaMaestroLN            (invariante en todos los sites)
    tunel en esta M1  localhost:${WT_TUNNEL_PORT}          -> ${PM_GUEST_WINHOST}:${WT_SITE_PORT}
    regla de firewall "PM site ${WT_SITE_NAME}"

  Compartidos (NO son del slot)
    SQL Server (motor), bus ${PM_WT_BUS_PROJECT}, puente pm-e2e-sqlbridge:60211, ${PM_WT_LN_DB} (read-only),
    site singleton pm:8080, pm-local-oracle-1:1521

$budget

  URLs
    API      http://${PM_REMOTE_SSH:-macdata}:${PM_API_PORT}/health/live
    Legado   http://localhost:${WT_TUNNEL_PORT}/ProgramaMaestroLN/Login.aspx
EOF
}

# Reclama un slot con arrendamiento muerto: tumba sus recursos POR NOMBRE y, si quedaron ausentes, libera su fila.
# Orden teardown->release (nunca al reves): mientras la fila existe, wt_slot_assign no puede reasignar el slot, asi
# que un wt-up concurrente no puede colisionar con el teardown; solo tras liberar la fila el slot vuelve al pool.
# Retorna != 0 si el Oracle del slot no se pudo retirar (la fila NO se libera: el siguiente dueno heredaria los
# datos que el camino con flag OFF (PGE950RT) muto). Muta los globals de wt_derive: el llamador re-deriva su slot.
_wt_reclaim_slot() {  # uso: _wt_reclaim_slot <slot> <folder>
  local slot="$1" folder="$2" ctx tport tpid pw; ctx="$(remote_docker_ctx)"
  wt_derive "$slot"
  wt_log "reclamando slot $slot ('$folder'): arrendamiento muerto -> teardown de recursos"
  on_intel "docker $ctx rm -f 'pm-wt${slot}-api' >/dev/null 2>&1; true"
  if wt_oracle_exists; then
    wt_oracle_down || { wt_die "reclaim del slot $slot: el Oracle no se retiro por completo; la fila NO se libera"; return 1; }
  fi
  # Site IIS del guest + tunel local del slot: best-effort (no bloquean el reclaim del slot).
  ssh "$PM_REMOTE_SSH" "WINHOST=${PM_GUEST_WINHOST} SLOT=$slot bash ~/pm-host-windows/scripts/site-down.sh" >/dev/null 2>&1 || true
  tport=$(( PM_WT_TUNNEL_PORT_BASE + slot ))
  tpid="$(pgrep -f -- "-L ${tport}:${PM_GUEST_WINHOST}:" 2>/dev/null | head -1)"
  [ -n "$tpid" ] && kill "$tpid" 2>/dev/null || true
  # BD de producto del slot (higiene de disco del /dev/vdb1).
  pw="$(wt_shared_sql_password 2>/dev/null)" && wt_drop_planning "$pw" >/dev/null 2>&1 || true
  wt_registry_lock wt_slot_release "$folder"
  wt_log "slot $slot reclamado (recursos retirados, fila liberada)"
}

# Reclama arrendamientos muertos del registro (pid muerto + heartbeat/created > PM_WT_LEASE_TTL), del mas viejo al
# mas nuevo por 'created' (col 5). Con dry=1 solo los lista; con dry=0 los reclama (teardown + release via
# _wt_reclaim_slot). Con 'max' > 0 detiene el barrido tras reclamar 'max' slots (early-stop, para liberar solo lo
# necesario); sin max (o max<=0) reclama todas. Imprime cuantos reclamo (o cuantos son reclamables, en dry). Toma
# un snapshot bajo lock y NO sostiene el lock durante el teardown remoto.
wt_reclaim_dead_leases() {  # uso: wt_reclaim_dead_leases <dry: 1|0> [max]
  local dry="${1:-1}" max="${2:-0}" snap f s pr off cr pid hb n=0
  [ -f "$PM_WT_REGISTRY" ] || { printf '0'; return 0; }
  snap="$(wt_registry_lock cat "$PM_WT_REGISTRY")" || { wt_log "reclaim: registro no legible; no se reclama"; printf '0'; return 0; }
  # Ordena el snapshot por 'created' (col 5, TAB) ascendente: la reclamacion procede del arrendamiento muerto mas
  # viejo al mas nuevo. Solo reordena las filas; el filtro por wt_lease_reclaimable no cambia.
  snap="$(printf '%s' "$snap" | sort -t"$(printf '\t')" -k5,5)"
  while IFS=$'\t' read -r f s pr off cr pid hb; do
    [ -n "$f" ] || continue
    wt_lease_reclaimable "$pid" "$hb" "$cr" || continue
    if [ "$dry" = "1" ]; then
      wt_log "arrendamiento reclamable: slot $s ('$f'; pid ${pid:-<ninguno>}, heartbeat ${hb:-<created:$cr>})"
      n=$((n+1))
    else
      if _wt_reclaim_slot "$s" "$f"; then
        n=$((n+1))
        # Early-stop: con max > 0, detiene tras reclamar 'max' slots (cmd_wt_up solo necesita liberar uno).
        if [ "$max" -gt 0 ] && [ "$n" -ge "$max" ]; then break; fi
      else
        wt_log "reclaim del slot $s ('$f') fallo; se conserva"
      fi
    fi
  done <<EOF
$snap
EOF
  printf '%s' "$n"
}

# Owner (folder) de un slot segun el SNAPSHOT del registro (una linea 'folder<TAB>slot<TAB>...' por worktree).
# Vacio si el slot esta libre. Consulta la copia en memoria; no re-lee ni re-lockea el archivo por cada plano.
_wt_gc_owner() {  # uso: _wt_gc_owner <slot> <snapshot>
  printf '%s\n' "$2" | awk -F'\t' -v s="$1" '$2==s{print $1; exit}'
}

# Recoleccion de basura: cruza los CUATRO planos (registro / API / Oracle / sites+tuneles) y lista los
# huerfanos. Con FORCE=1 los retira. Sin FORCE solo informa. Sale != 0 si con FORCE=1 no pudo retirar un huerfano.
cmd_wt_gc() {
  wt_require_intel || return 1
  local ctx force="${PM_WT_GC_FORCE:-0}"; ctx="$(remote_docker_ctx)"
  local apis oracles sites slot owner n orphans=0 clean_failures=0 lease_reclaimed=0
  # Snapshot del registro tomado UNA vez bajo wt_registry_lock: el listado y todos los lookups de owner se hacen
  # contra esta copia en memoria, sin sostener el lock durante las llamadas remotas (docker/ssh) de los planos.
  local reg_snap="" reg_readable=1
  if [ -f "$PM_WT_REGISTRY" ]; then
    reg_snap="$(wt_registry_lock cat "$PM_WT_REGISTRY")" || reg_readable=0
  fi
  # Un registro NO legible (lock no adquirido o lectura fallida) es estado DESCONOCIDO, distinto de un registro
  # vacio: un snapshot vacio por fallo de lectura veria todos los slots vivos como huerfanos. Con FORCE=1 se aborta
  # sin retirar nada (evita segar en masa APIs/Oracles/sites/tuneles de sesiones vivas); sin FORCE se avisa y se
  # informa (los huerfanos listados no son fiables).
  if [ "$reg_readable" != "1" ]; then
    if [ "$force" = "1" ]; then
      wt_die "no se pudo leer el registro de slots bajo lock ($PM_WT_REGISTRY); wt-gc con FORCE=1 NO retira nada para no segar slots vivos"
      return 1
    fi
    wt_log "AVISO: no se pudo leer el registro de slots ($PM_WT_REGISTRY); la deteccion de huerfanos NO es fiable (se informa, no se retira)"
  fi

  echo "[wt-gc] registro de slots ($PM_WT_REGISTRY):"
  if [ -n "$reg_snap" ]; then printf '%s\n' "$reg_snap" | awk -F'\t' '{printf "  slot %-3s %s\n", $2, $1}'; else echo "  (vacio)"; fi

  # Plano de arrendamientos: filas cuyo dueno murio (pid muerto) y con heartbeat/created > PM_WT_LEASE_TTL. Con
  # FORCE=1 se reclaman de raiz (teardown de recursos + release de la fila via _wt_reclaim_slot, orden seguro); sin
  # FORCE solo se informan. Corre ANTES de los planos de recursos: sus recursos ya no existen tras el reclaim.
  echo "[wt-gc] plano de arrendamientos (pid muerto + heartbeat > ${PM_WT_LEASE_TTL}s):"
  if [ "$reg_readable" = "1" ] && [ -n "$reg_snap" ]; then
    local lf ls lpr loff lcr lpid lhb
    while IFS=$'\t' read -r lf ls lpr loff lcr lpid lhb; do
      [ -n "$lf" ] || continue
      wt_lease_reclaimable "$lpid" "$lhb" "$lcr" || continue
      echo "  slot $ls ('$lf')  -> ARRENDAMIENTO MUERTO (pid ${lpid:-<ninguno>}, heartbeat ${lhb:-<created:$lcr>})"
      if [ "$force" = "1" ]; then
        if _wt_reclaim_slot "$ls" "$lf"; then echo "     reclamado"; lease_reclaimed=$((lease_reclaimed+1))
        else echo "     ERROR: no se pudo reclamar el slot $ls (Oracle no retirado); la fila se conserva"; clean_failures=$((clean_failures+1)); fi
      fi
    done <<EOF
$reg_snap
EOF
    # Refresca el snapshot para que los planos de recursos usen owners exactos tras liberar filas.
    if [ "$lease_reclaimed" -gt 0 ]; then reg_snap="$(wt_registry_lock cat "$PM_WT_REGISTRY" 2>/dev/null)" || true; fi
  fi
  if [ "$lease_reclaimed" -gt 0 ]; then echo "  ($lease_reclaimed reclamado(s))"
  elif [ "$force" = "1" ]; then echo "  (ninguno reclamable)"
  else echo "  (informativo; FORCE=1 para reclamar)"; fi

  apis="$(on_intel "docker $ctx ps -a --filter 'name=pm-wt' --format '{{.Names}}' 2>/dev/null" 2>/dev/null | tr -d '\r' | grep -E '^pm-wt[0-9]+-api$' || true)"
  oracles="$(on_intel "docker $ctx ps -a --filter 'name=pm-wt' --format '{{.Names}}' 2>/dev/null" 2>/dev/null | tr -d '\r' | grep -E '^pm-wt[0-9]+-oracle-1$' || true)"
  sites="$(ssh "$PM_REMOTE_SSH" "WINHOST=${PM_GUEST_WINHOST} bash ~/pm-host-windows/scripts/sites-status.sh" 2>/dev/null | cut -d'|' -f1 | grep -E '^pm-wt[0-9]+$' || true)"

  echo "[wt-gc] plano API:"
  for n in $apis; do
    slot="${n#pm-wt}"; slot="${slot%-api}"
    owner="$(_wt_gc_owner "$slot" "$reg_snap")"
    if [ -n "$owner" ]; then echo "  $n  -> $owner"
    else
      echo "  $n  -> HUERFANO (slot $slot libre)"; orphans=$((orphans+1))
      if [ "$force" = "1" ]; then
        # Sin '; true': el rc del docker rm (o del ssh) se propaga y una falla de retiro se contabiliza.
        if on_intel "docker $ctx rm -f '$n' >/dev/null 2>&1"; then echo "     retirado"
        else echo "     ERROR: no se pudo retirar '$n' (ssh/docker)"; clean_failures=$((clean_failures+1)); fi
      fi
    fi
  done
  [ -n "$apis" ] || echo "  (ninguno)"

  echo "[wt-gc] plano Oracle:"
  for n in $oracles; do
    slot="${n#pm-wt}"; slot="${slot%-oracle-1}"
    owner="$(_wt_gc_owner "$slot" "$reg_snap")"
    if [ -n "$owner" ]; then echo "  $n  -> $owner"
    else
      echo "  $n  -> HUERFANO (slot $slot libre)"; orphans=$((orphans+1))
      if [ "$force" = "1" ]; then
        wt_derive "$slot"
        # wt_oracle_down retorna != 0 si el contenedor/volumen sobrevive (VERIFICA la ausencia): se contabiliza.
        if wt_oracle_down; then echo "     retirado"
        else echo "     ERROR: no se pudo retirar '$n' por completo"; clean_failures=$((clean_failures+1)); fi
      fi
    fi
  done
  [ -n "$oracles" ] || echo "  (ninguno)"

  echo "[wt-gc] plano sites IIS del guest:"
  for n in $sites; do
    slot="${n#pm-wt}"
    owner="$(_wt_gc_owner "$slot" "$reg_snap")"
    if [ -n "$owner" ]; then echo "  $n  -> $owner"
    else
      echo "  $n  -> HUERFANO (slot $slot libre)"; orphans=$((orphans+1))
      if [ "$force" = "1" ]; then
        if ssh "$PM_REMOTE_SSH" "WINHOST=${PM_GUEST_WINHOST} SLOT=$slot bash ~/pm-host-windows/scripts/site-down.sh" >/dev/null 2>&1; then echo "     retirado"
        else echo "     ERROR: no se pudo retirar el site '$n' (guest inalcanzable o site-down fallo)"; clean_failures=$((clean_failures+1)); fi
      fi
    fi
  done
  [ -n "$sites" ] || echo "  (ninguno o guest inalcanzable)"

  # Plano de tuneles: un tunel per-slot escucha en 18100+N. Se cruza el puerto local contra el registro; los
  # tuneles del singleton (18080) y los de puertos fuera del bloque no se tocan (pueden ser de otra sesion).
  echo "[wt-gc] plano tuneles SSH de esta M1 (bloque ${PM_WT_TUNNEL_PORT_BASE}+slot):"
  local tun_line tun_port tun_pid found=0
  while IFS= read -r tun_line; do
    [ -n "$tun_line" ] || continue
    found=1
    tun_pid="${tun_line%% *}"
    # Extrae el puerto local de un '-L <puerto>:<winhost>:<siteport>'.
    tun_port="$(printf '%s' "$tun_line" | sed -n "s/.*-L \([0-9]\{1,\}\):${PM_GUEST_WINHOST}:.*/\1/p")"
    if [ -z "$tun_port" ]; then echo "  pid $tun_pid  (no se dedujo el puerto local)"; continue; fi
    # SOLO la reserva documentada [BASE, BASE+SLOTS_MAX) es del aprovisionamiento por slot. La cota superior usa
    # PM_WT_SLOTS_MAX (reserva 18100-18107), NO el PM_WT_SLOTS de la invocacion: con PM_WT_SLOTS bajo, un tunel
    # legitimo de un slot alto (p. ej. 18106) caeria "fuera del bloque" y no se GC-aria. Fuera de la reserva
    # (18080 del singleton, 60211 del puente, cualquier tunel ad-hoc) el proceso es de otra via y NO se toca.
    if [ "$tun_port" -lt "$PM_WT_TUNNEL_PORT_BASE" ] 2>/dev/null \
       || [ "$tun_port" -ge "$(( PM_WT_TUNNEL_PORT_BASE + PM_WT_SLOTS_MAX ))" ] 2>/dev/null; then
      echo "  pid $tun_pid  localhost:$tun_port  -> fuera del bloque de slots (singleton, puente u otra via): no se toca"; continue
    fi
    slot=$(( tun_port - PM_WT_TUNNEL_PORT_BASE ))
    owner="$(_wt_gc_owner "$slot" "$reg_snap")"
    if [ -n "$owner" ]; then echo "  pid $tun_pid  localhost:$tun_port  -> $owner (slot $slot)"
    else
      echo "  pid $tun_pid  localhost:$tun_port  -> HUERFANO (slot $slot libre)"; orphans=$((orphans+1))
      if [ "$force" = "1" ]; then
        if kill "$tun_pid" 2>/dev/null; then echo "     tunel cerrado (pid $tun_pid)"
        else echo "     ERROR: no se pudo cerrar el tunel (pid $tun_pid)"; clean_failures=$((clean_failures+1)); fi
      fi
    fi
  done <<EOF
$(pgrep -fl -- "-L .*:${PM_GUEST_WINHOST}:" 2>/dev/null)
EOF
  [ "$found" = "1" ] || echo "  (ninguno)"

  echo ""
  [ "$lease_reclaimed" -eq 0 ] || echo "[wt-gc] $lease_reclaimed arrendamiento(s) muerto(s) reclamado(s) (slot liberado + recursos retirados)."
  if [ "$orphans" -eq 0 ]; then echo "[wt-gc] sin huerfanos de recursos."
  elif [ "$force" != "1" ]; then echo "[wt-gc] $orphans huerfano(s) de recursos; re-corre con FORCE=1 para retirarlos."
  elif [ "$clean_failures" -gt 0 ]; then echo "[wt-gc] $orphans huerfano(s); $clean_failures retiro(s)/reclamo(s) fallaron (ver ERROR arriba)."
  else echo "[wt-gc] $orphans huerfano(s) de recursos retirado(s)."; fi

  # Aviso de retencion prolongada del turno del guest singleton (vacio si esta libre o por debajo del umbral).
  local gt="$BASE_DIR/tools/guest-turn/guest-turn.sh"
  if [ -x "$gt" ]; then "$gt" hold-warn 2>/dev/null | sed 's/^/[wt-gc] /'; fi

  # Exit != 0 si con FORCE=1 no se pudo retirar algun huerfano (ssh/docker/kill fallaron): un wt-gc en pipeline
  # distingue "limpio" de "no pudo limpiar" (ac8). Sin huerfanos, sin FORCE, o todo retirado -> 0.
  [ "$clean_failures" -eq 0 ] || { wt_log "wt-gc: $clean_failures retiro(s) fallaron; revisa manualmente en $PM_REMOTE_SSH"; return 1; }
  return 0
}

# Verbo independiente: siembra/asegura solo la referencia LN compartida (paso deliberado de una vez). Con
# PM_WT_SEED_FORCE=1 (make wt-seed-ln FORCE=1) RE-APLICA el grupo ln aunque la referencia ya este completa: es el
# escape para meter un seed ln NUEVO en el pm_erpln106 ya provisionado (el guard have==need de wt_ensure_ln_singleton
# mide presencia de tablas, no contenido, asi que un seed que agrega filas a una tabla existente se saltaria en
# silencio). Patron SINGLETON=1/NUKE=1 del proyecto.
cmd_wt_seed_ln() {
  wt_require_intel || return 1
  # Si WT apunta a un worktree de codigo, siembra los ln/*.sql de ESE worktree (no solo el checkout central), para
  # validar un seed nuevo del worktree. Mismo criterio que _cmd_wt_up_locked (marcador PL.PM.sln).
  local folder
  if folder="$(wt_resolve_folder 2>/dev/null)" && [ -f "$WRAPPER_DIR/worktrees/$folder/PL.PM.sln" ]; then
    PM_SOLUTION_DIR="$WRAPPER_DIR/worktrees/$folder"
    PM_CONTAINERS_DIR="$PM_SOLUTION_DIR/containers"
    wt_log "seed-ln: usando los containers del worktree '$folder' ($PM_CONTAINERS_DIR)"
  fi
  local pw; pw="$(wt_shared_sql_password)" || return 1
  sync_to_intel || return 1
  WT_REMOTE_CONTAINERS_ABS="$(on_intel "cd '$PM_REMOTE_DIR' && pwd" | tr -d '\r')" || WT_REMOTE_CONTAINERS_ABS=""
  [ -n "$WT_REMOTE_CONTAINERS_ABS" ] || { wt_die "no se resolvio la ruta remota de containers"; return 1; }
  wt_shared_sql_check || return 1
  # Mismo lock del seed que cmd_wt_up: el 'docker cp' de los CSV va a rutas COMPARTIDAS del motor (F2).
  wt_lock seed wt_push_seed_assets || return 1
  if [ "${PM_WT_SEED_FORCE:-0}" = "1" ]; then
    wt_log "FORCE=1: re-aplicando el grupo ln sobre '$PM_WT_LN_DB' (salta el guard have==need de wt_ensure_ln_singleton)."
    wt_log "AVISO: el grupo ln re-aplica los ln/*.sql sobre '$PM_WT_LN_DB' (compartido): si algun script aun hace DROP+CREATE disrupta a las sesiones que lo leen -> corre solo con el resto quieto."
    wt_lock ln wt_seed_group "$pw" ln "_pm_unused" "$PM_WT_LN_DB"
  else
    wt_lock ln wt_ensure_ln_singleton "$pw"
  fi
}

# --- Verbos de data-plane del slot (wt-sql / wt-oracle / wt-flag): encapsulan credenciales/puente/contexto para
# que ningun agente los re-descubra. Slot-mandatorios: exigen WT con slot asignado (exit 2 sin el). ---

# Resuelve el slot del worktree (WT) y deriva sus parametros. Retorna 2 si no hay slot asignado (guard compartido).
_wt_bind_slot() {  # setea WT_SLOT/PM_*/WT_ORACLE_* via wt_derive; imprime nada.
  local folder slot
  folder="$(wt_resolve_folder)" || return 2
  slot="$(wt_slot_lookup "$folder")"
  [ -n "$slot" ] || { wt_die "el worktree '$folder' no tiene slot asignado: corre 'make wt-up WT=$folder' primero"; return 2; }
  wt_derive "$slot"
  WT_BOUND_FOLDER="$folder"
}

# wt-sql: corre SQL arbitrario contra la BD del slot (pm_planning_wt<N>) por el motor compartido. SCALAR=1 -> valor
# escalar (sin encabezado). El SA, el host/puerto del motor y el nombre de la BD los resuelve el verbo.
cmd_wt_sql() {
  wt_require_intel || return 1
  [ -n "${PM_WT_SQL:-}" ] || { wt_die "falta SQL=\"<consulta>\" (make wt-sql WT=<folder> SQL=\"SELECT ...\" [SCALAR=1])"; return 2; }
  _wt_bind_slot || return $?
  local pw; pw="$(wt_shared_sql_password)" || return 1
  wt_shared_sql_check || return 1
  # Fija la BD por el flag -d de sqlcmd (no 'USE [db]'): asi no emite el mensaje "Changed database context" que
  # ensuciaria el escalar. El SQL llega intacto (con comillas simples) porque el Makefile exporta SQL (no lo
  # interpola entre comillas simples en la linea de comando).
  if [ "${PM_WT_SQL_SCALAR:-0}" = "1" ]; then
    wt_shared_query "$pw" "SET NOCOUNT ON; $PM_WT_SQL" "-h -1 -W -d $PM_PLANNING_DB" 2>/dev/null | tr -d '\r'
  else
    wt_shared_query "$pw" "SET NOCOUNT ON; $PM_WT_SQL" "-d $PM_PLANNING_DB"
  fi
}

# wt-oracle: corre SQL arbitrario (multi-fila) contra el Oracle ControlPiso del slot. Exige el contenedor Oracle
# del slot activo (aprovisionado con ORACLE=1). ORACLE_HOME, sqlplus y credenciales los resuelve el verbo.
cmd_wt_oracle() {
  wt_require_intel || return 1
  [ -n "${PM_WT_SQL:-}" ] || { wt_die "falta SQL=\"<consulta>\" (make wt-oracle WT=<folder> SQL=\"select ...\")"; return 2; }
  _wt_bind_slot || return $?
  wt_oracle_running || { wt_die "el Oracle del slot '$WT_ORACLE_CONTAINER' no esta corriendo: aprovisiona con 'make wt-up WT=$WT_BOUND_FOLDER ORACLE=1'"; return 1; }
  local ctx; ctx="$(remote_docker_ctx)"
  printf 'set head off feed off pages 0 lines 32767 trimspool on;\n%s\n' "$PM_WT_SQL" \
    | on_intel "docker $ctx exec -i -e ORACLE_HOME='$PM_WT_ORACLE_HOME' '$WT_ORACLE_CONTAINER' bash -c 'export PATH=\$ORACLE_HOME/bin:\$PATH; exec sqlplus -S $PM_WT_ORACLE_USER/$PM_WT_ORACLE_PASS@localhost:1521/XE'"
}

# wt-flag: fija un feature flag en la BD del slot por el motor compartido. Es el canal SANCIONADO para el slot: el
# endpoint POST /api/v1/tools/feature-flags rechaza el SQL del slot por la allowlist DEV (Server 'sqlserver,1433'
# fuera de la allowlist). KEY=<flag> STATE=on|off [PLANT=RES]. Falla si el flag no existe (0 filas afectadas).
cmd_wt_flag() {
  wt_require_intel || return 1
  [ -n "${PM_WT_FLAG_KEY:-}" ] || { wt_die "falta KEY=<flag> (make wt-flag WT=<folder> KEY=<flag> STATE=on|off [PLANT=RES])"; return 2; }
  local v
  case "${PM_WT_FLAG_STATE:-}" in
    on|ON|1|true|TRUE)    v=1 ;;
    off|OFF|0|false|FALSE) v=0 ;;
    *) wt_die "falta STATE=on|off (make wt-flag WT=<folder> KEY=$PM_WT_FLAG_KEY STATE=on)"; return 2 ;;
  esac
  _wt_bind_slot || return $?
  local plant="${PM_WT_FLAG_PLANT:-RES}" pw key_esc sql out
  pw="$(wt_shared_sql_password)" || return 1
  wt_shared_sql_check || return 1
  key_esc="$(printf '%s' "$PM_WT_FLAG_KEY" | sed "s/'/''/g")"
  sql="SET NOCOUNT ON; USE [$PM_PLANNING_DB]; UPDATE FeatureManagement.FeatureFlags SET IsEnabled=$v, UpdatedAt=SYSUTCDATETIME() WHERE [Key]=N'$key_esc' AND Plant=N'$plant'; SELECT @@ROWCOUNT;"
  out="$(wt_shared_scalar "$pw" "$sql")"
  if [ "${out:-0}" = "0" ]; then
    wt_die "flag '$PM_WT_FLAG_KEY'/$plant no existe en $PM_PLANNING_DB (0 filas): revisa KEY/PLANT o que la BD tenga el seed del flag"; return 1
  fi
  wt_log "flag '$PM_WT_FLAG_KEY'/$plant -> IsEnabled=$v en $PM_PLANNING_DB ($out fila(s) actualizada(s))"
}

# wt-heartbeat: refresca el arrendamiento (pid+heartbeat) del slot sin re-aprovisionar. Para holds largos que no
# tocan el slot por otros verbos (analogo a deploy-turn heartbeat), evita que el reclaim por TTL lo considere muerto.
cmd_wt_heartbeat() {
  local folder slot
  folder="$(wt_resolve_folder)" || return 1
  slot="$(wt_slot_lookup "$folder")"
  [ -n "$slot" ] || { wt_die "el worktree '$folder' no tiene slot asignado"; return 2; }
  wt_registry_lock wt_slot_touch "$folder"
  wt_log "arrendamiento del slot $slot ('$folder') refrescado (pid $$, heartbeat $(date -u +%Y-%m-%dT%H:%M:%SZ))"
}

# wt-reclaim: reclama UN arrendamiento reclamable especifico (el worktree WT, cuyo dueno murio + heartbeat vencido).
# Respeta "nunca robar a una duena viva": gatea con wt_lease_reclaimable ANTES de tumbar recursos; un pid vivo o un
# heartbeat fresco => rechaza (return 3). Reusa _wt_reclaim_slot (teardown por nombre + release de la fila) y
# propaga su rc. Sin slot asignado => return 2. Requiere intel (el teardown usa docker/ssh a macdata).
cmd_wt_reclaim() {
  wt_require_intel || return 1
  local folder slot row cr pid hb
  folder="$(wt_resolve_folder)" || return 1
  slot="$(wt_slot_lookup "$folder")"
  [ -n "$slot" ] || { wt_die "el worktree '$folder' no tiene slot asignado"; return 2; }
  # Lee las columnas del arrendamiento (created=5, owner_pid=6, heartbeat=7) bajo lock para una lectura consistente.
  # Orden created<TAB>pid<TAB>heartbeat: el heartbeat (posiblemente vacio en filas viejas) queda ULTIMO, para que
  # 'read' no colapse un TAB intermedio (TAB es whitespace de IFS y colapsaria un campo vacio del medio).
  row="$(wt_registry_lock awk -F'\t' -v f="$folder" '$1==f{print $5"\t"$6"\t"$7; exit}' "$PM_WT_REGISTRY")"
  IFS=$'\t' read -r cr pid hb <<EOF
$row
EOF
  wt_lease_reclaimable "$pid" "$hb" "$cr" || { wt_die "el arrendamiento del slot $slot ('$folder') NO es reclamable (pid vivo o heartbeat fresco): no se roba a una duena viva"; return 3; }
  # _wt_reclaim_slot se invoca en contexto de condicion (como en wt_reclaim_dead_leases y cmd_wt_gc): sus guardas
  # internas ('; true', '|| true') asumen set -e SUPRIMIDO; llamarlo BARE abortaria el teardown a media via.
  if _wt_reclaim_slot "$slot" "$folder"; then return 0; fi
  return 1
}
