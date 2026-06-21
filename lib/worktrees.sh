#!/usr/bin/env bash
# Aprovisionamiento aislado por worktree para el data tier + API de PM.
# Compatible con bash 3.2 (el /bin/bash de macOS): sin arrays asociativos, lock por mkdir.
# La logica vive aqui; wt.sh es la capa fina y el Makefile expone los verbos.
#
# Modelo "slot": un slot (0..N-1) es la unica perilla por worktree; de el se derivan proyecto, offset de
# puertos, nombre de BD y prefijo de bus. Capas:
#   - Singletons compartidos (una vez): SQL de nvoslabs (reusado), referencia LN propia pm_erpln106
#     (seed-once guarded), bus PM-owned (emulador + SQL Edge).
#   - Per-worktree: BD pm_planning_wt<N> en el SQL compartido + contenedor de la API (build desde el worktree).
# Oracle ControlPiso y el legado multi-sitio NO entran en el nucleo (sirven a la via legada/E2E); quedan como
# follow-up tras una bandera.
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
wt_lock() {
  local name="$1"; shift
  local dir; dir="$(dirname "$PM_WT_REGISTRY")"
  local lock="$dir/.${name}.lock" i=0
  mkdir -p "$dir"
  until mkdir "$lock" 2>/dev/null; do
    i=$((i+1)); [ "$i" -gt 180 ] && { wt_die "timeout esperando el lock '$name'"; return 1; }
    sleep 1
  done
  # shellcheck disable=SC2064
  trap "rmdir '$lock' 2>/dev/null || true" RETURN
  "$@"
}

# Serializa lecturas/escrituras del registro de slots (folder -> slot), gitignored.
wt_registry_lock() { wt_lock registry "$@"; }

# Slot asignado a un folder (sin asignar uno nuevo); vacio si no existe.
wt_slot_lookup() {  # uso: wt_slot_lookup <folder>
  [ -f "$PM_WT_REGISTRY" ] || return 0
  awk -F'\t' -v f="$1" '$1==f{print $2; exit}' "$PM_WT_REGISTRY"
}

# Asigna (o reusa) el slot libre mas bajo para un folder y lo persiste. Imprime el slot.
wt_slot_assign() {  # uso: wt_slot_assign <folder>   (correr bajo wt_registry_lock)
  local folder="$1" existing n used
  existing="$(wt_slot_lookup "$folder")"
  if [ -n "$existing" ]; then printf '%s' "$existing"; return 0; fi
  [ -f "$PM_WT_REGISTRY" ] || : > "$PM_WT_REGISTRY"
  for n in $(seq 0 $(( PM_WT_SLOTS - 1 ))); do
    used="$(awk -F'\t' -v s="$n" '$2==s{print 1; exit}' "$PM_WT_REGISTRY")"
    if [ -z "$used" ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$folder" "$n" "pm-wt${n}" "$(( n * 10 ))" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$PM_WT_REGISTRY"
      printf '%s' "$n"; return 0
    fi
  done
  wt_die "sin slots libres (PM_WT_SLOTS=$PM_WT_SLOTS); baja un worktree o sube PM_WT_SLOTS"; return 1
}

# Libera el slot de un folder (borra su linea del registro).
wt_slot_release() {  # uso: wt_slot_release <folder>   (correr bajo wt_registry_lock)
  [ -f "$PM_WT_REGISTRY" ] || return 0
  local tmp="${PM_WT_REGISTRY}.tmp"
  awk -F'\t' -v f="$1" '$1!=f' "$PM_WT_REGISTRY" > "$tmp" && mv "$tmp" "$PM_WT_REGISTRY"
}

# Resuelve el folder del worktree: WT explicito, o autodeteccion por el toplevel git si se corre dentro de uno.
wt_resolve_folder() {
  if [ -n "${WT:-}" ]; then printf '%s' "$WT"; return 0; fi
  local top; top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] && { basename "$top"; return 0; }
  wt_die "falta WT=<folder> (o ejecutar dentro del worktree para autodeteccion)"; return 1
}

# Deriva todos los parametros por slot y recalcula puertos.
wt_derive() {  # uso: wt_derive <slot>
  WT_SLOT="$1"
  PM_PROJECT="pm-wt${WT_SLOT}"
  PM_PORT_OFFSET=$(( WT_SLOT * 10 ))
  PM_PLANNING_DB="pm_planning_wt${WT_SLOT}"
  WT_SB_PREFIX="wt${WT_SLOT}"
  PM_PROFILE="full"; PROFILE_FLAG="--profile full"
  compute_ports
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

# Ejecuta una consulta T-SQL DENTRO del contenedor del SQL compartido (server-local, tools18). El SQL viaja
# por STDIN (-i /dev/stdin) -> sin quoting de metacaracteres; la password por env ($SAPW) la expande el bash
# del contenedor (correrla directa la expandiria la shell remota, donde $SAPW no existe -> login falla).
# uso: wt_shared_query <password> <sql> [flags-extra-de-sqlcmd]
wt_shared_query() {
  local pw="$1" sql="$2" flags="${3:-}"
  local ctx; ctx="$(remote_docker_ctx)"
  printf '%s' "$sql" | on_intel "docker $ctx exec -i -e SAPW='$(wt_esc "$pw")' '$PM_SHARED_SQL_CONTAINER' /bin/bash -c '/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \"\$SAPW\" -C $flags -i /dev/stdin'"
}
# Escalar (sin encabezado): retorna el valor trimmeado.
wt_shared_scalar() { wt_shared_query "$1" "$2" "-h -1 -W" 2>/dev/null | tr -d ' \r\n'; }
# DDL/idempotente: corta en error (-b).
wt_shared_exec()   { wt_shared_query "$1" "$2" "-b"; }

# Copia los assets de seed AL contenedor del SQL compartido: scripts (sql/init -> /pmseed) y CSV del grupo ln
# (sql/data -> /pmdata, oracle/data -> /seed-ctrlpiso). El seed corre por 'docker exec' contra ese mismo
# contenedor (localhost) con tools18, y el BULK INSERT (server-side) lee los CSV de su filesystem. Idempotente.
# Los CSV del grupo ln van a /pmdata (overlay del contenedor), NO a /data: ese path es bind-mount al arbol
# fuente del SQL de nvoslabs, y escribir ahi sobreescribiria sus CSV homonimos (p. ej. ttxpcf925116.csv).
wt_push_seed_assets() {  # uso: wt_push_seed_assets   (requiere WT_REMOTE_CONTAINERS_ABS)
  local ctx; ctx="$(remote_docker_ctx)"
  wt_log "copiando scripts + CSV de seed al contenedor del SQL compartido (/pmseed, /pmdata, /seed-ctrlpiso) ..."
  # mkdir como root (-u 0): el contenedor corre como 'mssql', que no puede crear dirs en /. docker cp ya
  # escribe como root; los archivos quedan world-readable -> el proceso de SQL (BULK INSERT server-side) los lee.
  on_intel "docker $ctx exec -u 0 '$PM_SHARED_SQL_CONTAINER' mkdir -p /pmseed /pmdata /seed-ctrlpiso \
    && docker $ctx cp '$WT_REMOTE_CONTAINERS_ABS/sql/init/.' '$PM_SHARED_SQL_CONTAINER:/pmseed' \
    && docker $ctx cp '$WT_REMOTE_CONTAINERS_ABS/sql/data/.' '$PM_SHARED_SQL_CONTAINER:/pmdata' \
    && docker $ctx cp '$WT_REMOTE_CONTAINERS_ABS/oracle/data/.' '$PM_SHARED_SQL_CONTAINER:/seed-ctrlpiso'" \
    || { wt_die "fallo al copiar los assets de seed al SQL compartido"; return 1; }
}

# Aplica en orden los *.sql de un grupo (/pmseed/<group>) DENTRO del contenedor del SQL compartido con tools18
# (el sqlcmd viejo de mssql-tools no acepta -v; tools18 si). El loop viaja por STDIN (bash -s) para evitar el
# quoting anidado; los nombres de BD se pasan como sqlcmd vars (identificadores seguros, embebidos). El grupo
# ln lee sus CSV de /pmdata (LN_CSV_DIR); el grupo planning ignora esa var (lee /seed-ctrlpiso embebido).
wt_seed_group() {  # uso: wt_seed_group <password> <ln|planning> <planning_db> <ln_db>
  local pw="$1" group="$2" pdb="$3" ldb="$4" ctx; ctx="$(remote_docker_ctx)"
  printf '%s\n' \
    'set -e' \
    "for f in \$(ls /pmseed/$group/*.sql | sort); do" \
    '  echo "[seed] aplica $(basename "$f")"' \
    "  /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \"\$SAPW\" -C -b -v PLANNING_DB=$pdb LN_DB=$ldb LN_CSV_DIR=/pmdata -i \"\$f\"" \
    'done' \
  | on_intel "docker $ctx exec -i -e SAPW='$(wt_esc "$pw")' '$PM_SHARED_SQL_CONTAINER' /bin/bash -s"
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

# Siembra la BD de producto del worktree (pm_planning_wt<N>) en el SQL compartido reusando el seeder de la
# solucion (init.sh) con PM_SEED_LN=0 (omite el grupo ln; reusa pm_erpln106).
wt_seed_planning() {  # uso: wt_seed_planning <password>
  local pw="$1"
  wt_log "sembrando BD de producto '$PM_PLANNING_DB' en el SQL compartido (solo grupo planning; reusa $PM_WT_LN_DB) ..."
  wt_seed_group "$pw" planning "$PM_PLANNING_DB" "$PM_WT_LN_DB" \
    || { wt_die "fallo el seed de '$PM_PLANNING_DB'"; return 1; }
}

# --- Bus PM-owned (singleton compartido entre worktrees) ---

# Levanta el bus (sbsqledge + servicebus emulador) como proyecto compose dedicado, una sola vez.
wt_ensure_bus() {
  local ctx; ctx="$(remote_docker_ctx)"
  if on_intel "[ \"\$(docker $ctx inspect -f '{{.State.Running}}' '${PM_WT_BUS_PROJECT}-servicebus-1' 2>/dev/null)\" = true ]" 2>/dev/null; then
    wt_log "bus PM-owned ya arriba (proyecto $PM_WT_BUS_PROJECT)"; return 0
  fi
  wt_log "levantando bus PM-owned (proyecto $PM_WT_BUS_PROJECT: sbsqledge + servicebus; host :$PM_WT_BUS_HOST_PORT) ..."
  on_intel "export PATH=/usr/local/bin:\$PATH PM_SB_SA_PASSWORD='$(wt_esc "$PM_SB_SA_PASSWORD")' PM_SB_HOST_PORT='$PM_WT_BUS_HOST_PORT'; cd '$PM_REMOTE_DIR/compose' && docker $ctx compose -p '$PM_WT_BUS_PROJECT' -f '$COMPOSE_FILE' --profile bus up -d sbsqledge servicebus" \
    || { wt_die "fallo al levantar el bus PM-owned"; return 1; }
}

# --- API por worktree ---

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
  # connstrings vistas desde el contenedor: SQL por alias de la red compartida; bus por alias del singleton.
  local cs ln sbcs
  cs="Server=$PM_SHARED_SQL_HOST,$PM_SHARED_SQL_PORT;Database=$PM_PLANNING_DB;User Id=sa;Password=$pw;TrustServerCertificate=True"
  ln="Server=$PM_SHARED_SQL_HOST,$PM_SHARED_SQL_PORT;Database=$PM_WT_LN_DB;User Id=sa;Password=$pw;TrustServerCertificate=True"
  sbcs="Endpoint=sb://servicebus:5672;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;"
  cs="$(wt_esc "$cs")"; ln="$(wt_esc "$ln")"; sbcs="$(wt_esc "$sbcs")"
  wt_log "run contenedor $cname (redes: $PM_SHARED_SQL_NETWORK + ${PM_WT_BUS_PROJECT}_default; sql $PM_SHARED_SQL_HOST/$PM_PLANNING_DB; bus prefix $WT_SB_PREFIX; publica $PM_API_PORT->8080) ..."
  # create + connect (segunda red) + start: evita la ventana en que la API arranca antes de unir el bus.
  on_intel "docker $ctx rm -f '$cname' >/dev/null 2>&1; \
    docker $ctx create --name '$cname' --network '$PM_SHARED_SQL_NETWORK' -p '$PM_API_PORT:8080' \
      -e ASPNETCORE_ENVIRONMENT=IntegrationTest \
      -e ConnectionStrings__Planning='$cs' -e ConnectionStrings__Ln='$ln' \
      -e ServiceBus__ConnectionString='$sbcs' -e ServiceBus__SubscriptionPrefix='$WT_SB_PREFIX' '$img' >/dev/null \
    && docker $ctx network connect '${PM_WT_BUS_PROJECT}_default' '$cname' \
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

# --- Verbos ---

cmd_wt_up() {
  wt_require_intel || return 1
  local folder slot
  folder="$(wt_resolve_folder)" || return 1
  slot="$(wt_registry_lock wt_slot_assign "$folder")" || return 1
  wt_derive "$slot"
  wt_log "worktree '$folder' -> slot $slot (proyecto $PM_PROJECT, offset $PM_PORT_OFFSET, API :$PM_API_PORT, BD $PM_PLANNING_DB, bus $WT_SB_PREFIX)"

  # Codigo de la API (build): el worktree si existe; override explicito por PM_WT_SOLUTION_DIR; si no, el
  # default de load_env (la solucion principal) -> util para smoke sin un worktree git aparte.
  if [ -n "${PM_WT_SOLUTION_DIR:-}" ]; then
    PM_SOLUTION_DIR="$PM_WT_SOLUTION_DIR"
  elif [ -e "$WRAPPER_DIR/worktrees/$folder/.git" ]; then
    PM_SOLUTION_DIR="$WRAPPER_DIR/worktrees/$folder"
  fi
  [ -d "$PM_SOLUTION_DIR" ] || { wt_die "no existe la solucion '$PM_SOLUTION_DIR' (worktree '$folder'); fija PM_WT_SOLUTION_DIR"; return 1; }
  # Dir remoto por slot en macdata (aisla el contexto de build entre worktrees).
  PM_REMOTE_SOLUTION_DIR="pm-solution-wt${slot}"
  wt_log "codigo de la API: $PM_SOLUTION_DIR -> $PM_REMOTE_SSH:$PM_REMOTE_SOLUTION_DIR"

  local pw; pw="$(wt_shared_sql_password)" || return 1

  # 1) rsync de containers/ (scripts + CSV de seed) a macdata; resuelve su ruta absoluta para docker -v/cp.
  sync_to_intel || return 1
  WT_REMOTE_CONTAINERS_ABS="$(on_intel "cd '$PM_REMOTE_DIR' && pwd" | tr -d '\r')" || WT_REMOTE_CONTAINERS_ABS=""
  [ -n "$WT_REMOTE_CONTAINERS_ABS" ] || { wt_die "no se resolvio la ruta remota de containers"; return 1; }

  # 2) singletons compartidos
  wt_shared_sql_check || return 1
  wt_push_seed_assets || return 1
  # Lock dedicado del seed LN: serializa el check-then-act (DROP+CREATE de pm_erpln106) entre wt-up
  # concurrentes en frio; sin el, dos verian la referencia ausente y la sembrarian en paralelo (corrupcion).
  wt_lock ln wt_ensure_ln_singleton "$pw" || return 1
  # Lock dedicado del bus: serializa el check-then-act entre wt-up concurrentes (solo uno hace el cold-start
  # del singleton; los demas esperan y lo ven arriba). No usa el lock del registro para no serializar el seed/build.
  wt_lock bus wt_ensure_bus || return 1

  # 3) per-worktree: seed de la BD de producto + API
  wt_seed_planning "$pw" || return 1
  wt_up_api "$pw" || return 1

  echo ""
  echo "[wt] worktree '$folder' (slot $slot) ARRIBA:"
  echo "[wt]   API      -> http://$PM_REMOTE_SSH:$PM_API_PORT/health/live"
  echo "[wt]   SQL      -> $PM_SHARED_SQL_HOST/$PM_PLANNING_DB (compartido; publicado en $PM_REMOTE_SSH:$PM_SHARED_SQL_PUBLISHED)"
  echo "[wt]   LN ref   -> $PM_WT_LN_DB (compartido, read-only)"
  echo "[wt]   bus      -> $PM_WT_BUS_PROJECT (prefix $WT_SB_PREFIX)"
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
  local pw; pw="$(wt_shared_sql_password)" && wt_drop_planning "$pw" || wt_log "aviso: no se dropeo la BD (sin password del SQL compartido)"
  wt_registry_lock wt_slot_release "$folder"
  wt_log "worktree '$folder' bajado y slot $slot liberado (singletons compartidos intactos)"
}

cmd_wt_ls() {
  if [ ! -s "$PM_WT_REGISTRY" ]; then echo "[wt] registro vacio ($PM_WT_REGISTRY)"; return 0; fi
  echo "folder	slot	project	offset	created"
  cat "$PM_WT_REGISTRY"
}

cmd_wt_status() {
  wt_require_intel || return 1
  local ctx; ctx="$(remote_docker_ctx)"
  wt_shared_sql_check || true
  echo "[wt] contenedores PM por worktree en $PM_REMOTE_SSH:"
  on_intel "docker $ctx ps --filter 'name=pm-wt' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" || true
  echo "[wt] bus PM-owned ($PM_WT_BUS_PROJECT):"
  on_intel "docker $ctx ps --filter 'name=${PM_WT_BUS_PROJECT}-' --format 'table {{.Names}}\t{{.Status}}'" || true
}

# Verbo independiente: siembra/asegura solo la referencia LN compartida (paso deliberado de una vez).
cmd_wt_seed_ln() {
  wt_require_intel || return 1
  local pw; pw="$(wt_shared_sql_password)" || return 1
  sync_to_intel || return 1
  WT_REMOTE_CONTAINERS_ABS="$(on_intel "cd '$PM_REMOTE_DIR' && pwd" | tr -d '\r')" || WT_REMOTE_CONTAINERS_ABS=""
  [ -n "$WT_REMOTE_CONTAINERS_ABS" ] || { wt_die "no se resolvio la ruta remota de containers"; return 1; }
  wt_shared_sql_check || return 1
  wt_push_seed_assets || return 1
  wt_lock ln wt_ensure_ln_singleton "$pw"
}
