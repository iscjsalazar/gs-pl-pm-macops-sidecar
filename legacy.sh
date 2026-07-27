#!/usr/bin/env bash
# Driver del lanzamiento del legado CargaPlantaPT_LN. La logica vive aqui; el Makefile es el catalogo de verbos.
# Corre en la maquina de desarrollo (M1) y orquesta por SSH: data tier (intel) + VM Windows + build/deploy.
# Idempotente: verifica antes de levantar y NO relanza lo que ya esta arriba (salvo PM_LEGACY_FORCE=1).
#
# Dos vias:
#   - SINGLETON (SLOT vacio): site 'pm':8080, arbol C:\src, tunel 18080. Es la via legada. Un turno exclusivo
#     (tools/guest-turn/guest-turn.sh) impide que dos sesiones se pisen el arbol y el Web.config.
#   - PER-SLOT (PM_LEGACY_SLOT=N): site 'pm-wt<N>':8100+N, arbol C:\wt<N>, tunel 18100+N. Varias sesiones en
#     paralelo sin turno: cada una tiene site, arbol y config propios.
# En AMBAS vias la seccion stage->build->deploy la serializa un lock que vive en macdata (scripts/guest-lock.sh):
# MSBuild, el applicationHost.config de IIS y los vCPU de la VM son recursos compartidos por todos los sites.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"                      # raiz del checkout del sidecar (central o worktree); pwd -P casa con git toplevel
# Raiz del arbol (repos hermanos + sidecar central). Robusto ante un git worktree del sidecar: sube hasta el
# ancestro con gs-pl-pm-macops-sidecar/ en vez de asumir "HERE/..". Override: PM_WRAPPER_DIR.
_find_root(){ local d="$1"; while [ "$d" != "/" ]; do [ -d "$d/gs-pl-pm-macops-sidecar" ] && { printf '%s' "$d"; return 0; }; d="$(dirname "$d")"; done; return 1; }
WRAPPER_DIR="${PM_WRAPPER_DIR:-$(_find_root "$HERE" || true)}"
[ -n "$WRAPPER_DIR" ] || { printf 'ERROR: no se localizo la raiz del proyecto (ancestro con gs-pl-pm-macops-sidecar/); fija PM_WRAPPER_DIR\n' >&2; exit 1; }
SIDECAR_CENTRAL_DIR="$WRAPPER_DIR/gs-pl-pm-macops-sidecar"
WT_REGISTRY="${PM_WT_REGISTRY:-$SIDECAR_CENTRAL_DIR/.worktrees/slots.tsv}"   # registro compartido folder->slot
# Helpers puros del registro de slots (T-015): se reusan wt_pid_dead/wt_is_num/wt_slot_row_by_slot/
# wt_lease_reclaimable/wt_age_secs y, para slot-claim/slot-release, wt_slot_lookup/wt_slot_assign/
# wt_slot_release/wt_slot_touch/wt_registry_lock. Se sourcea unicamente lib/worktrees.sh (no lib/common.sh):
# esas funciones son puras (sin SSH/Docker) y este archivo no ejecuta nada al sourcearse mas alla de defaults
# de variables (verificado; PM_WT_REGISTRY abajo apunta al MISMO registro que WT_REGISTRY, derivado arriba).
# NO se reusa wt_reclaim_dead_leases/wt_probe_live_slots (requieren on_intel/remote_docker_ctx de lib/common.sh,
# fuera del alcance de este driver): un slot-claim con el pool lleno remite a 'make wt-gc FORCE=1' /
# 'make wt-reclaim WT=<folder>' en vez de reclamar inline.
PM_WT_REGISTRY="$WT_REGISTRY"
PM_WT_SLOTS="${PM_WT_SLOTS:-8}"        # tamaño del pool que wt_slot_assign recorre (mismo default que lib/common.sh)
PM_WT_LEASE_TTL="${PM_WT_LEASE_TTL:-3600}"  # TTL del arrendamiento (mismo default que lib/common.sh); lo consume wt_lease_reclaimable
# shellcheck source=lib/worktrees.sh
. "$HERE/lib/worktrees.sh"

# --- Config (defaults; el Makefile traduce vars cortas a estas PM_LEGACY_*) ---
MACDATA="${PM_LEGACY_MACDATA:-macdata}"                       # alias SSH de la mac Intel
WINHOST="${PM_LEGACY_WINHOST:-172.16.128.129}"               # IP del guest Windows (NAT interna de macdata)
SLOT="${PM_LEGACY_SLOT:-}"                                    # vacio = via singleton; <N> = via per-slot
case "$SLOT" in
  '') : ;;
  *[!0-9]*) printf 'ERROR: PM_LEGACY_SLOT no numerico: %s\n' "$SLOT" >&2; exit 2 ;;
esac
SINGLETON="${PM_LEGACY_SINGLETON:-0}"                         # 1 = escape deliberado a la via singleton en launch/build/deploy

# Bases de puertos dedicadas por slot. NO se derivan de 8080/1521: 8080+N choca con el singleton 'pm':8080 y
# 8080+N*10 con 'pmpub':8090; 1521+offset choca con pm-local-oracle-1 (slot 0) y pm-arts-rt-oracle-1 (slot 5).
SITE_PORT_BASE="${PM_LEGACY_SITE_PORT_BASE:-8100}"
TUNNEL_PORT_BASE="${PM_LEGACY_TUNNEL_PORT_BASE:-18100}"
ORACLE_PORT_BASE="${PM_WT_ORACLE_PORT_BASE:-15210}"

SITE_NAME="pm${SLOT:+-wt$SLOT}"                               # site IIS del guest
# Puerto vacio => derivado del slot (o el default singleton). El Makefile ya no impone 8080/18080.
if [ -n "${PM_LEGACY_SITE_PORT:-}" ]; then SITE_PORT="$PM_LEGACY_SITE_PORT"
elif [ -n "$SLOT" ]; then SITE_PORT=$(( SITE_PORT_BASE + SLOT ))
else SITE_PORT=8080; fi
if [ -n "${PM_LEGACY_TUNNEL_PORT:-}" ]; then TUNNEL_PORT="$PM_LEGACY_TUNNEL_PORT"
elif [ -n "$SLOT" ]; then TUNNEL_PORT=$(( TUNNEL_PORT_BASE + SLOT ))
else TUNNEL_PORT=18080; fi

SQL_PORT="${PM_LEGACY_SQL_PORT:-1433}"                       # SQL del data tier en macdata
ORACLE_PORT="${PM_LEGACY_ORACLE_PORT:-1521}"                 # Oracle: 1521 = singleton; 15210+N = Oracle del slot
DBHOST="${PM_LEGACY_DBHOST:-172.16.128.1}"                   # host del data tier visto DESDE el guest (pasarela NAT)
PROFILE="${PM_LEGACY_PROFILE:-full}"                         # sql | full (el legado necesita Oracle ControlPiso)
DATATIER="${PM_LEGACY_DATATIER:-1}"                          # 0 = no gestionar el data tier
FORCE="${PM_LEGACY_FORCE:-0}"                                # 1 = rebuild/redeploy aunque ya este arriba
# I5: staging incremental del legado. CLEAN=1 = comportamiento previo (wipe total del arbol del guest + nuget
# restore incondicional); por default (0) el stage PRESERVA bin/obj/packages (MSBuild incremental) y el restore
# se salta si packages.config no cambio. Viaja por env a stage-app.sh/build-app.sh (no via PM_LEGACY_*: el Makefile
# no lo traduce, y make exporta CLEAN=1 a la receta cuando se pasa en linea de comando o entorno).
CLEAN="${CLEAN:-0}"
# E2E (solicitud e2e-launch-orchestration): wiring opcional al backend .NET 10 que el deploy inyecta en el
# Web.config/connections.config DESPLEGADO (la frontera: el repo legado no los conoce). Vacio = no inyecta.
BACKEND_URL="${PM_LEGACY_BACKEND_URL:-}"                     # appSetting backendBaseUrl (URL del backend vista por el guest)
SQL_PM_HOST="${PM_LEGACY_SQL_PM_HOST:-}"                     # ConStrPm: host,puerto del SQL del backend (alcanzable por el guest)
SQL_PM_DB="${PM_LEGACY_SQL_PM_DB:-}"                         # ConStrPm: catalogo (pm_planning o pm_planning_wt<N>)
SQL_PM_USER="${PM_LEGACY_SQL_PM_USER:-}"                     # ConStrPm: usuario
SQL_PM_PASS="${PM_LEGACY_SQL_PM_PASS:-}"                     # ConStrPm: password
SQL_READER_USER="${PM_LEGACY_SQL_READER_USER:-}"            # ConStrJobsReader: usuario (pm_reader; vacio = login de app)
SQL_READER_PASS="${PM_LEGACY_SQL_READER_PASS:-}"            # ConStrJobsReader: password
HW_REMOTE="${PM_LEGACY_HW_REMOTE:-~/pm-host-windows}"        # checkout de host-windows EN macdata
# Stage de fuente EN macdata: per-slot, para que dos sesiones no comprimen ni transfieran el mismo arbol.
STAGE_REMOTE="${PM_LEGACY_STAGE_REMOTE:-~/pm-host-windows/artifacts/stage${SLOT:+/wt$SLOT}}"
# Turno del guest singleton (M1) y lock de la seccion de build (macdata). 0 los desactiva: solo para
# diagnostico, nunca en operacion normal.
GUEST_TURN_ENABLED="${PM_LEGACY_GUEST_TURN:-1}"
GUEST_LOCK_ENABLED="${PM_LEGACY_GUEST_LOCK:-1}"
GUEST_LOCK_TIMEOUT="${PM_LEGACY_GUEST_LOCK_TIMEOUT:-1800}"
GUEST_TURN_SH="$HERE/tools/guest-turn/guest-turn.sh"
# Fuente del legado en el M1. Prioridad: PM_LEGACY_SRC_LOCAL explicito > WT=<folder> (worktree de codigo
# legacy, validado por ProgramaMaestroPT.sln) > CWD dentro de un worktree legacy > central pl-pm-legacy.
_resolve_legacy_src(){
  [ -n "${PM_LEGACY_SRC_LOCAL:-}" ] && { printf '%s' "$PM_LEGACY_SRC_LOCAL"; return 0; }
  if [ -n "${WT:-}" ] && [ -f "$WRAPPER_DIR/worktrees/$WT/ProgramaMaestroPT.sln" ]; then
    printf '%s' "$WRAPPER_DIR/worktrees/$WT"; return 0
  fi
  local top; top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  case "$top" in "$WRAPPER_DIR/worktrees/"*) [ -f "$top/ProgramaMaestroPT.sln" ] && { printf '%s' "$top"; return 0; } ;; esac
  printf '%s' "$WRAPPER_DIR/pl-pm-legacy"
}
SRC_LOCAL="$(_resolve_legacy_src)"                           # fuente del legado EN M1 (central o worktree de codigo)

APP_PATH="health.aspx"                                        # ruta de humo que publica deploy-iis.ps1 (raiz del site)

log(){ printf '== %s\n' "$*"; }
warn(){ printf 'AVISO: %s\n' "$*" >&2; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ssh_md(){ ssh "$MACDATA" "$@"; }
# Escapa comillas simples para incrustar un valor en un comando remoto entre comillas simples.
_esc(){ printf "%s" "${1//\'/\'\\\'\'}"; }

# Health del legado consultado DESDE macdata hacia el guest (evita depender del tunel).
guest_health(){ ssh_md "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://$WINHOST:$SITE_PORT/$APP_PATH" 2>/dev/null; }

# Empuja los scripts de host-windows (M1) al checkout en macdata, para que los verbos
# remotos corran la version actual. No toca artifacts/ ni .env (propios de macdata).
#
# ATENCION: $HW_REMOTE/scripts es un arbol UNICO compartido por todas las sesiones (a diferencia de
# STAGE_REMOTE, que si es per-slot). Sincronizarlo mientras otra sesion ejecuta esos mismos scripts bajo el
# lock del guest los reemplaza a mitad de su corrida. Por eso stage_build/deploy toman el lock ANTES de
# sincronizar (ver guest_lock_acquire) y el resto de verbos solo lo hacen si el lock esta libre o es suyo.
_SYNCED=0
sync_remote(){
  [ "$_SYNCED" = "1" ] && return 0
  log "sincronizando host-windows (scripts/packer) -> $MACDATA:$HW_REMOTE"
  ssh_md "mkdir -p $HW_REMOTE/scripts" || true
  # $HW_REMOTE/scripts es un arbol UNICO compartido: un 'rsync -a' desde un checkout viejo revierte en silencio
  # los scripts de las demas sesiones (falta el --delete que si tienen los arboles per-slot de sync_to_intel).
  # Guard por marcador de version: $HW_REMOTE/scripts/.sync-version guarda '<HEAD-short-sha> <committer-epoch>'
  # del checkout que sincronizo. Si el marcador remoto trae un epoch ESTRICTAMENTE mayor (arbol mas nuevo), NO
  # se sincroniza (no se revierte un arbol mas nuevo; warn en vez de die, para no abortar el verbo). Si no, se
  # sincroniza con --delete y se reescribe el marcador.
  local local_epoch local_sha remote_epoch
  local_epoch="$(git -C "$HERE" show -s --format=%ct HEAD 2>/dev/null || true)"
  local_sha="$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || true)"
  case "$local_epoch" in ''|*[!0-9]*) local_epoch="" ;; esac
  if [ -n "$local_epoch" ]; then
    remote_epoch="$(ssh_md "cat $HW_REMOTE/scripts/.sync-version 2>/dev/null" 2>/dev/null | awk '{print $2}')"
    case "$remote_epoch" in ''|*[!0-9]*) remote_epoch="" ;; esac
    if [ -n "$remote_epoch" ] && [ "$remote_epoch" -gt "$local_epoch" ]; then
      warn "el arbol remoto de host-windows/scripts es mas nuevo (epoch $remote_epoch > $local_epoch de $HERE); NO se sincroniza para no revertirlo"
      _SYNCED=1
      return 0
    fi
    rsync -a --delete -e ssh "$HERE/scripts" "$HERE/packer" "$MACDATA:$HW_REMOTE/" \
      || die "fallo el sync de host-windows hacia $MACDATA"
    # El --delete borra el marcador (no vive en el arbol fuente): se reescribe tras el rsync.
    ssh_md "printf '%s %s\n' '$local_sha' '$local_epoch' > $HW_REMOTE/scripts/.sync-version" || true
  else
    # Sin git (o HEAD sin epoch): se degrada al comportamiento previo (rsync -a SIN --delete, no reversible).
    warn "sin metadatos git de $HERE; sync no reversible (rsync -a sin --delete): un checkout viejo podria revertir scripts remotos"
    rsync -a -e ssh "$HERE/scripts" "$HERE/packer" "$MACDATA:$HW_REMOTE/" \
      || die "fallo el sync de host-windows hacia $MACDATA"
  fi
  _SYNCED=1
}

# Instala SOLO guest-lock.sh en macdata. Es el huevo-y-la-gallina del lock: para tomarlo hace falta el script,
# pero sincronizar todo el arbol antes de tenerlo pisaria los scripts que otra sesion esta ejecutando. Este
# archivo es idempotente entre versiones (misma interfaz), asi que copiarlo fuera del lock es inocuo.
sync_lock_script(){
  ssh_md "mkdir -p $HW_REMOTE/scripts" || true
  rsync -a -e ssh "$HERE/scripts/guest-lock.sh" "$MACDATA:$HW_REMOTE/scripts/guest-lock.sh" \
    || die "fallo el sync de guest-lock.sh hacia $MACDATA"
}

# --- Guard de SLOT en launch/build/deploy ------------------------------------
# Sin SLOT estos verbos fallan en seco ANTES de tomar guest-turn y de cualquier accion remota: la via
# singleton esta deprecada (process-e2e-local-slots.md §5). El escape SINGLETON=1 la habilita deliberadamente
# con warning y sin alterar su comportamiento (toma y RETIENE guest-turn).
require_slot(){
  local verb="$1"
  [ -n "$SLOT" ] && return 0
  if [ "$SINGLETON" = "1" ]; then
    warn "[VIA LEGADA] corriendo sobre el singleton (site pm:8080, arbol C:\\src): toma y retiene guest-turn hasta make legacy-down / make legacy-turn-release (deprecada por process-e2e-local-slots.md §5)"
    return 0
  fi
  printf 'ERROR: falta SLOT: usa make legacy-%s SLOT=<N> (deriva el slot de tu worktree con make wt-info WT=<wt>).\n' "$verb" >&2
  printf '       La via singleton (site pm:8080, arbol C:\\src) esta deprecada (process-e2e-local-slots.md §5) y\n' >&2
  printf '       ademas toma y RETIENE guest-turn; para usarla deliberadamente: make legacy-%s SINGLETON=1\n' "$verb" >&2
  exit 2
}

# --- Guard de arrendamiento (lease) de SLOT en build/launch/deploy (T-015; S1 de T-013/D80) ------------------
# Un SLOT numerico por si solo NO prueba que el arbol guest C:\wt<N> sea tuyo: sin este guard, un
# 'legacy-build SLOT=<N> CLEAN=1' de una sesion podia hacer wipe del arbol de OTRA sesion que ya tenia ese
# mismo SLOT arrendado en slots.tsv (caso observado: T-013 sobre SLOT=0 vivo de otra sesion). Corre DESPUES de
# require_slot (SLOT ya resuelto) y ANTES de cualquier stage/wipe/deploy (guest_turn_acquire/stage_build/deploy).
#
# Clasificacion (semantica de "duena viva" IDENTICA a wt_lease_reclaimable de lib/worktrees.sh — Hecho #4
# del analisis T-015 / M1 r1): dueña viva = pid vivo O heartbeat fresco dentro de PM_WT_LEASE_TTL (default 3600 s).
# Todo verbo del proyecto que escribe slots.tsv (wt-up, wt-heartbeat, e2e-url) es un CLI de un disparo: owner_pid
# esta casi siempre muerto aunque el arrendamiento siga activo; el latido operativo es el heartbeat, no el pid.
#   - sin fila para el SLOT                          -> permite (log informativo; ver slot-claim para evitar la carrera)
#   - fila reclamable (pid muerto Y hb > TTL)        -> permite con AVISO (arrendamiento huerfano; el registro lo retira
#                                                       wt-reclaim/wt-gc, fuera de este verbo)
#   - fila con dueña viva y folder == WT             -> permite (folder propio; identidad = columna 1 de slots.tsv, NO el
#                                                       worktree de FUENTE del legado, que es ortogonal via SRC_LOCAL)
#   - fila con dueña viva y folder != WT             -> EXIT 3 (fail-closed) salvo override explicito
#
# Escape UNICO: LEASE_OVERRIDE=1 + LEASE_OVERRIDE_REASON=<texto no vacio> (make: LEASE_OVERRIDE /
# LEASE_OVERRIDE_REASON; driver: PM_LEGACY_LEASE_OVERRIDE / PM_LEGACY_LEASE_OVERRIDE_REASON), con log
# '[LEASE-OVERRIDE]' inequivoco. FORCE=1 (PM_LEGACY_FORCE) NO es este escape y esta funcion no lo lee: FORCE ya
# significa "rebuild/redeploy aunque health 200" sobre TU slot; sobrecargarlo para "pisa el slot de otra sesion"
# mezclaria ambos significados y volveria el guard un bypass silencioso en el uso rutinario de FORCE=1 propio.
LEASE_OVERRIDE="${PM_LEGACY_LEASE_OVERRIDE:-0}"
LEASE_OVERRIDE_REASON="${PM_LEGACY_LEASE_OVERRIDE_REASON:-}"

require_slot_lease(){
  local verb="$1"
  [ -n "$SLOT" ] || return 0   # singleton: fuera de alcance de este guard (arbol C:\src, protegido por guest-turn)
  if [ "$LEASE_OVERRIDE" = "1" ] && [ -z "$LEASE_OVERRIDE_REASON" ]; then
    printf 'ERROR: LEASE_OVERRIDE=1 exige LEASE_OVERRIDE_REASON=<texto> (motivo del override).\n' >&2
    printf '       uso: make legacy-%s SLOT=%s LEASE_OVERRIDE=1 LEASE_OVERRIDE_REASON="<motivo>"\n' "$verb" "$SLOT" >&2
    exit 2
  fi
  local row folder created pid hb
  row="$(wt_slot_row_by_slot "$SLOT")"
  if [ -z "$row" ]; then
    log "lease: slot $SLOT sin fila en $WT_REGISTRY -> permite (para evitar carrera con un wt-up/legacy-slot-claim concurrente, reserva antes con 'make legacy-slot-claim WT=<folder-legacy>')"
    return 0
  fi
  # Fila: folder\tslot\tproject\toffset\tcreated\towner_pid\theartbeat
  IFS=$'\t' read -r folder _ _ _ created pid hb <<EOF
$row
EOF
  # Reusa wt_lease_reclaimable (misma semántica que wt-reclaim/wt-gc): reclamable <=> pid muerto AND hb > TTL.
  # Negacion = dueña viva = pid vivo O heartbeat fresco (el caso comun: CLI de un disparo ya terminado).
  if wt_lease_reclaimable "$pid" "$hb" "$created"; then
    warn "lease: slot $SLOT arrendado por '$folder' pero es reclamable (pid ${pid:-<ninguno>} muerto y heartbeat ${hb:-<sin hb>} rancio > ${PM_WT_LEASE_TTL}s) -> permite (arrendamiento huerfano; el registro se retira con 'make wt-reclaim WT=$folder' o 'make wt-gc FORCE=1', fuera de este verbo)"
    return 0
  fi
  if [ -n "${WT:-}" ] && [ "$WT" = "$folder" ]; then
    log "lease: slot $SLOT arrendado por '$folder' (folder propio, WT=$WT) -> permite"
    return 0
  fi
  if [ "$LEASE_OVERRIDE" = "1" ]; then
    warn "[LEASE-OVERRIDE] slot $SLOT folder=$folder pid=$pid reason='$LEASE_OVERRIDE_REASON' by $(hostname -s 2>/dev/null || echo m1):$$"
    return 0
  fi
  printf 'ERROR: slot %s esta arrendado por la sesion "%s" (pid %s, heartbeat %s; dueña viva = pid vivo o heartbeat fresco dentro de TTL %ss): legacy-%s se ABORTA para no pisar su arbol C:\\wt%s.\n' \
    "$SLOT" "$folder" "${pid:-<ninguno>}" "${hb:-<sin heartbeat>}" "${PM_WT_LEASE_TTL}" "$verb" "$SLOT" >&2
  printf '       Si ese folder eres TU: pasa WT=%s para afirmar la identidad del arrendamiento.\n' "$folder" >&2
  printf '       Para un slot propio en una tarea solo-legado (worktree sin PL.PM.sln): make legacy-slot-claim WT=<tu-folder-legacy>.\n' >&2
  printf '       Override deliberado (coordinado con la duena viva): LEASE_OVERRIDE=1 LEASE_OVERRIDE_REASON="<motivo>" make legacy-%s SLOT=%s ...\n' "$verb" "$SLOT" >&2
  exit 3
}

# --- Claim/release ligero de arrendamiento (solo-legacy, sin PL.PM.sln) --------------------------------------
# Reusa el POOL de slots.tsv (wt_slot_assign/wt_slot_release/wt_slot_touch de lib/worktrees.sh) SOLO para
# reservar folder+numero de slot: NO aprovisiona API/Oracle/BD (eso sigue siendo 'wt-up'/'e2e-up'). Exige el
# marcador de legado (ProgramaMaestroPT.sln) para no consumir una fila del registro COMPARTIDO con una clave que
# no es un worktree de codigo (mismo criterio que wt_resolve_folder en lib/worktrees.sh). Identidad = WT=<folder>,
# el mismo nombre que ya resuelve la fuente del legado en _resolve_legacy_src y que exige require_slot_lease.
slot_claim(){
  local folder="${WT:-}"
  [ -n "$folder" ] || { printf 'ERROR: legacy-slot-claim exige WT=<folder-legacy> (worktree con ProgramaMaestroPT.sln bajo worktrees/).\n' >&2; exit 2; }
  [ -f "$WRAPPER_DIR/worktrees/$folder/ProgramaMaestroPT.sln" ] \
    || { printf 'ERROR: worktrees/%s no contiene ProgramaMaestroPT.sln; legacy-slot-claim es SOLO para worktrees solo-legado (para pl-programa-maestro usa make wt-up WT=%s).\n' "$folder" "$folder" >&2; exit 2; }
  local slot
  slot="$(wt_registry_lock wt_slot_assign "$folder" "")" || slot=""
  if [ -z "$slot" ]; then
    printf 'ERROR: sin slots libres (PM_WT_SLOTS=%s). Libera uno con "make wt-gc FORCE=1" (huerfanos/arrendamientos muertos) o "make wt-reclaim WT=<folder>" (uno especifico), y reintenta.\n' "${PM_WT_SLOTS:-8}" >&2
    exit 1
  fi
  wt_registry_lock wt_slot_touch "$folder"
  log "slot $slot arrendado a '$folder' (SOLO registro: NO aprovisiona API/Oracle/BD; para eso usa wt-up/e2e-up)"
  printf '   siguiente paso:      make legacy-build SLOT=%s WT=%s\n' "$slot" "$folder"
  printf '   liberar al terminar: make legacy-slot-release WT=%s\n' "$folder"
}

slot_release(){
  local folder="${WT:-}"
  [ -n "$folder" ] || { printf 'ERROR: legacy-slot-release exige WT=<folder-legacy>.\n' >&2; exit 2; }
  local slot pid
  slot="$(wt_slot_lookup "$folder")"
  if [ -z "$slot" ]; then log "'$folder' no tiene slot arrendado; nada que liberar"; return 0; fi
  pid="$(wt_slot_row_by_slot "$slot" | awk -F'\t' '{print $6}')"
  # Espejo de "no robar a una duena viva": otro proceso (mismo folder, otra corrida) sigue vivo -> exige el
  # mismo override que require_slot_lease, no un segundo mecanismo.
  if [ "$pid" != "$$" ] && ! wt_pid_dead "$pid" && [ "$LEASE_OVERRIDE" != "1" ]; then
    printf 'ERROR: el slot %s de "%s" lo sostiene otro proceso vivo (pid %s); si es una liberacion coordinada usa LEASE_OVERRIDE=1 LEASE_OVERRIDE_REASON="<motivo>".\n' "$slot" "$folder" "$pid" >&2
    exit 3
  fi
  wt_registry_lock wt_slot_release "$folder"
  log "slot $slot liberado ('$folder')"
  # Desmontaje del site del guest: OPCIONAL, y deliberadamente MANUAL (no automatico aqui): site_down deriva
  # SITE_NAME/TUNNEL_PORT del SLOT con el que arranco ESTE proceso (top de legacy.sh), no del slot resuelto por
  # folder; re-invocar el mismo binario con SLOT=<n> explicito evita re-derivar ese estado a mano.
  log "si 'legacy-build/launch' llego a desplegar el site del slot $slot, retiralo con: PM_LEGACY_SLOT=$slot ./legacy.sh site-down"
}

# --- Warning de TUNNEL= ad-hoc en legacy-tunnel (no bloquea) -----------------
# Sin SLOT y con TUNNEL fijado a mano el puerto no proviene de la derivacion del slot: modo deprecado
# (process-e2e-local-slots.md §5). El rescate del tunel singleton 18080 sigue siendo legitimo en la via legada.
warn_tunnel_adhoc(){
  { [ -z "$SLOT" ] && [ -n "${PM_LEGACY_TUNNEL_PORT:-}" ]; } || return 0
  warn "[DEPRECADO] TUNNEL ad-hoc: los puertos se derivan del slot (make legacy-tunnel SLOT=<N>); el 18080 pertenece a la via legada"
}

# --- Turno del guest singleton (lock en la M1) -------------------------------
# Solo la via singleton lo necesita: comparte site, arbol y Web.config entre sesiones. La via per-slot no.
# El turno se MANTIENE tras el verbo (la sesion sigue usando el site) y se libera con 'legacy.sh down' o
# 'legacy.sh turn-release'. Los turnos de sesiones muertas o abandonadas se reclaman solos (pid + heartbeat).
guest_turn_acquire(){
  [ -z "$SLOT" ] || return 0
  [ "$GUEST_TURN_ENABLED" = "1" ] || return 0
  [ -x "$GUEST_TURN_SH" ] || { warn "no se encontro $GUEST_TURN_SH; se procede sin turno del guest"; return 0; }
  local rc=0
  "$GUEST_TURN_SH" acquire --tag "${PM_LEGACY_TURN_TAG:-legacy-singleton}" || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) printf 'ERROR: el guest singleton (site pm:8080, arbol C:\\src) lo usa otra sesion.\n' >&2
       printf '       Usa la via per-slot (make e2e-up WT=<worktree>) o espera y reintenta.\n' >&2
       exit 3 ;;
    *) die "no se pudo evaluar el turno del guest singleton (codigo $rc)" ;;
  esac
}
guest_turn_release(){
  [ -z "$SLOT" ] || return 0
  [ -x "$GUEST_TURN_SH" ] || return 0
  "$GUEST_TURN_SH" release || true
}
# Refresca el heartbeat si el turno es de esta sesion. Lo llaman los verbos de consulta y de uso, para que una
# sesion que sigue trabajando sobre el singleton no aparezca como abandonada en 'turn-status'.
guest_turn_heartbeat(){
  [ -z "$SLOT" ] || return 0
  [ -x "$GUEST_TURN_SH" ] || return 0
  "$GUEST_TURN_SH" check-held-by-me 2>/dev/null && "$GUEST_TURN_SH" heartbeat >/dev/null 2>&1
  return 0
}

# --- Lock de macdata: seccion stage->build->deploy ---------------------------
# Cubre AMBAS vias y a sesiones de cualquier maquina orquestadora (el lock vive en macdata, no en la M1).
_GUEST_LOCK_OWNER="$(hostname -s 2>/dev/null || echo m1):$$:$(date +%s)"
_GUEST_LOCK_HELD=0
# Toma el lock ANTES de sincronizar el arbol de scripts compartido: el sync sobreescribe los mismos
# stage-app.sh/build-app.sh/deploy-app.sh que otra sesion podria estar ejecutando bajo su lock.
guest_lock_acquire(){
  [ "$GUEST_LOCK_ENABLED" = "1" ] || { sync_remote; return 0; }
  [ "$_GUEST_LOCK_HELD" = "1" ] && return 0
  sync_lock_script
  log "lock de $MACDATA: turno de stage->build->deploy del guest (owner $_GUEST_LOCK_OWNER)"
  ssh_md "bash $HW_REMOTE/scripts/guest-lock.sh acquire --owner '$(_esc "$_GUEST_LOCK_OWNER")' --timeout $GUEST_LOCK_TIMEOUT" \
    || die "no se obtuvo el lock del guest en $MACDATA (otra sesion compila/despliega); reintenta mas tarde"
  _GUEST_LOCK_HELD=1
  trap 'guest_lock_release' EXIT INT TERM
  # Ya con el lock: ahora si se instala la version de ESTA sesion de todos los scripts que se van a ejecutar.
  sync_remote
}
guest_lock_touch(){
  [ "$_GUEST_LOCK_HELD" = "1" ] || return 0
  ssh_md "bash $HW_REMOTE/scripts/guest-lock.sh touch --owner '$(_esc "$_GUEST_LOCK_OWNER")'" >/dev/null 2>&1 || true
}
guest_lock_release(){
  [ "$_GUEST_LOCK_HELD" = "1" ] || return 0
  _GUEST_LOCK_HELD=0
  ssh_md "bash $HW_REMOTE/scripts/guest-lock.sh release --owner '$(_esc "$_GUEST_LOCK_OWNER")'" >/dev/null 2>&1 \
    || warn "no se pudo liberar el lock del guest en $MACDATA (caduca por TTL)"
}

# --- Verbos ---

data_up(){
  if [ "$DATATIER" = "0" ]; then log "data tier: omitido (DATATIER=0)"; return 0; fi
  log "data tier (intel): verificando puertos en $MACDATA (SQL:$SQL_PORT Oracle:$ORACLE_PORT)"
  # Los dos puertos se comprueban POR SEPARADO: un check combinado no distingue cual esta abajo, y atribuir
  # siempre el fallo al Oracle del slot produce un mensaje falso y bloquea el pm-run que provisiona el SQL.
  local sql_up=0 oracle_up=0
  ssh_md "nc -z -G 3 127.0.0.1 $SQL_PORT"    2>/dev/null && sql_up=1
  ssh_md "nc -z -G 3 127.0.0.1 $ORACLE_PORT" 2>/dev/null && oracle_up=1
  if [ "$sql_up" = "1" ] && [ "$oracle_up" = "1" ]; then
    log "data tier ya arriba -> no se relanza"
    return 0
  fi
  # Un Oracle per-slot (>= ORACLE_PORT_BASE) NO lo levanta 'pm-run': ese verbo solo enciende el stack singleton
  # en 1521. Si el que falta es ese Oracle, "remediar" con pm-run dejaria el frontend del slot apuntando a un
  # puerto muerto; se aborta con el diagnostico correcto. Si el Oracle del slot esta arriba y solo falta el SQL,
  # se remedia como siempre.
  if [ "$oracle_up" = "0" ] && [ "$ORACLE_PORT" -ge "$ORACLE_PORT_BASE" ] 2>/dev/null; then
    die "el Oracle del slot (:$ORACLE_PORT) no responde en $MACDATA; lo aprovisiona 'make wt-up WT=<worktree> ORACLE=1' (pm-run solo levanta el singleton :1521)"
  fi
  log "data tier abajo (SQL:$sql_up Oracle:$oracle_up) -> levantando via pm.sh (TARGET=intel PROFILE=$PROFILE)"
  # El data tier del legado (Oracle ControlPiso + Infor LN con su seed) lo provisiona la solicitud
  # db-setup-containers; aqui solo se asegura que los contenedores/puertos esten arriba en intel.
  # WRAPPER="$WRAPPER_DIR": propaga la raiz ya resuelta (honra el override PM_WRAPPER_DIR); sin esto el
  # sub-make pisaria PM_WRAPPER_DIR='' y el data tier perderia el override en layout no estandar.
  make -C "$HERE" pm-run WRAPPER="$WRAPPER_DIR" TARGET=intel REMOTE="$MACDATA" SQLHOST="$MACDATA" PROFILE="$PROFILE" \
    || die "fallo al levantar el data tier en intel"
  # Tras remediar se re-verifica: un pm-run exitoso que no publique el SQL esperado sigue siendo un fallo. El
  # Oracle del slot no lo toca pm-run, asi que solo se re-verifica cuando es el singleton.
  ssh_md "nc -z -G 3 127.0.0.1 $SQL_PORT" 2>/dev/null || die "el data tier sigue sin publicar SQL:$SQL_PORT en $MACDATA"
  if [ "$ORACLE_PORT" -lt "$ORACLE_PORT_BASE" ] 2>/dev/null; then
    ssh_md "nc -z -G 3 127.0.0.1 $ORACLE_PORT" 2>/dev/null || die "el data tier sigue sin publicar Oracle:$ORACLE_PORT en $MACDATA"
  fi
}

vm_up(){
  sync_remote
  log "VM Windows: asegurando (idempotente) en $MACDATA"
  ssh_md "WINHOST=$WINHOST bash $HW_REMOTE/scripts/vm-up.sh" || die "no se pudo asegurar la VM"
}

stage_build(){
  if [ "$FORCE" != "1" ] && [ "$(guest_health)" = "200" ]; then
    log "app ya desplegada en $SITE_NAME (health 200) -> se omite build (PM_LEGACY_FORCE=1 para forzar)"
    return 0
  fi
  [ -d "$SRC_LOCAL" ] || die "fuente del legado no encontrada: $SRC_LOCAL (ver g2: pl-pm-legacy)"
  guest_lock_acquire   # toma el lock y solo entonces sincroniza los scripts compartidos de macdata
  log "sincronizando fuente M1 -> macdata stage ($STAGE_REMOTE)"
  ssh_md "mkdir -p $STAGE_REMOTE" || true
  rsync -a --delete \
    -e ssh \
    --exclude='.git/' \
    "$SRC_LOCAL/" "$MACDATA:$STAGE_REMOTE/CargaPlantaPT_LN/" || die "fallo el rsync de la fuente"
  guest_lock_touch
  log "staging fuente macdata -> guest + build (VS Build Tools)${CLEAN:+ (CLEAN=$CLEAN)}"
  ssh_md "WINHOST=$WINHOST SLOT='$SLOT' STAGE=$STAGE_REMOTE CLEAN='$CLEAN' bash $HW_REMOTE/scripts/stage-app.sh" || die "fallo el staging al guest"
  guest_lock_touch
  ssh_md "WINHOST=$WINHOST SLOT='$SLOT' CLEAN='$CLEAN' bash $HW_REMOTE/scripts/build-app.sh" || die "fallo el build en el guest"
  guest_lock_touch
}

deploy(){
  if [ "$FORCE" != "1" ] && [ "$(guest_health)" = "200" ]; then
    log "app ya sirviendo en $SITE_NAME (health 200) -> se omite deploy (PM_LEGACY_FORCE=1 para forzar)"
    return 0
  fi
  guest_lock_acquire   # toma el lock y solo entonces sincroniza los scripts compartidos de macdata
  log "deploy a IIS del guest (site $SITE_NAME :$SITE_PORT; oracle $DBHOST:$ORACLE_PORT)${BACKEND_URL:+ + inyeccion backend ($BACKEND_URL)}"
  # Propaga el wiring E2E opcional al deploy-app.sh remoto (vacio = no inyecta; deploy standalone intacto).
  ssh_md "WINHOST=$WINHOST SITE_PORT=$SITE_PORT SLOT='$SLOT' \
    PM_LEGACY_DBHOST='$(_esc "$DBHOST")' \
    PM_LEGACY_ORACLE_PORT='$(_esc "$ORACLE_PORT")' \
    PM_LEGACY_BACKEND_URL='$(_esc "$BACKEND_URL")' \
    PM_LEGACY_SQL_PM_HOST='$(_esc "$SQL_PM_HOST")' \
    PM_LEGACY_SQL_PM_DB='$(_esc "$SQL_PM_DB")' \
    PM_LEGACY_SQL_PM_USER='$(_esc "$SQL_PM_USER")' \
    PM_LEGACY_SQL_PM_PASS='$(_esc "$SQL_PM_PASS")' \
    PM_LEGACY_SQL_READER_USER='$(_esc "$SQL_READER_USER")' \
    PM_LEGACY_SQL_READER_PASS='$(_esc "$SQL_READER_PASS")' \
    bash $HW_REMOTE/scripts/deploy-app.sh" || die "fallo el deploy"
}

diag(){
  sync_remote
  log "habilitando log de errores detallado (Health Monitoring -> Event Log) + reciclando el pool $SITE_NAME"
  # CLEAR_EVENT_LOG=1 limpia el Application Event Log, COMPARTIDO por toda la VM (default: se conserva).
  ssh_md "WINHOST=$WINHOST SLOT='$SLOT' CLEAR_EVENT_LOG='${CLEAR_EVENT_LOG:-0}' bash $HW_REMOTE/scripts/diag.sh" \
    || die "fallo al habilitar el log de errores"
}

diag_logs(){
  sync_remote
  log "errores ASP.NET del Event Log del guest (detalle completo; var MAX=${MAX:-40})"
  ssh_md "WINHOST=$WINHOST MAX=${MAX:-40} bash $HW_REMOTE/scripts/diag-logs.sh" || die "fallo al leer los logs"
}

# Desmonta el frontend del slot (site, pool, arbol, raiz, zip, scripts, firewall) y su stage en macdata.
# Exige slot: NUNCA opera el singleton.
site_down(){
  [ -n "$SLOT" ] || die "site-down exige SLOT=<N> (PM_LEGACY_SLOT): nunca opera el site singleton 'pm'"
  sync_remote
  tunnel_down
  log "desmontando el site $SITE_NAME del guest"
  ssh_md "WINHOST=$WINHOST SLOT='$SLOT' bash $HW_REMOTE/scripts/site-down.sh" || die "fallo el desmontaje del site $SITE_NAME"
}

# Vista del plano IIS: sites 'pm*' del guest cruzados contra el registro de slots; marca huerfanos.
sites_status(){
  sync_remote
  log "sites 'pm*' en el guest ($WINHOST)"
  local sites name state bindings slot owner
  sites="$(ssh_md "WINHOST=$WINHOST bash $HW_REMOTE/scripts/sites-status.sh" 2>/dev/null)"
  [ -n "$sites" ] || { warn "no se listaron sites (guest apagado?)"; return 0; }
  printf '   %-14s %-9s %-14s %s\n' SITE ESTADO BINDING REGISTRO
  while IFS='|' read -r name state bindings; do
    [ -n "$name" ] || continue
    case "$name" in
      pm-wt*)
        slot="${name#pm-wt}"
        owner="$(awk -F'\t' -v s="$slot" '$2==s{print $1; exit}' "$WT_REGISTRY" 2>/dev/null)"
        [ -n "$owner" ] || owner="HUERFANO (slot $slot libre) -> make legacy-site-down SLOT=$slot"
        printf '   %-14s %-9s %-14s %s\n' "$name" "$state" "$bindings" "$owner" ;;
      pm)    printf '   %-14s %-9s %-14s %s\n' "$name" "$state" "$bindings" "singleton (via legada)" ;;
      pmpub) printf '   %-14s %-9s %-14s %s\n' "$name" "$state" "$bindings" "artefacto de publish (260630-0116)" ;;
      *)     printf '   %-14s %-9s %-14s %s\n' "$name" "$state" "$bindings" "" ;;
    esac
  done <<EOF
$sites
EOF
  printf '\n'
  log "tuneles SSH de esta M1 hacia el guest"
  pgrep -fl ":$WINHOST:" 2>/dev/null | sed 's/^/   /' || echo "   (ninguno)"
}

tunnel_up(){
  if pgrep -f "$TUNNEL_PORT:$WINHOST:$SITE_PORT" >/dev/null 2>&1; then
    log "tunel ya activo (localhost:$TUNNEL_PORT) -> no se relanza"
    return 0
  fi
  log "abriendo tunel SSH: localhost:$TUNNEL_PORT -> $WINHOST:$SITE_PORT (via $MACDATA)"
  # I9: acota el ssh del tunel. Un macdata inalcanzable colgaba 'ssh -f' de forma indefinida (es justo el cuelgue
  # que dispara el timeout de e2e-url en up.sh/relaunch.sh). ConnectTimeout bota la conexion muerta en ~10 s;
  # BatchMode evita que un prompt interactivo (host key/password) cuelgue; un reintento corto absorbe un fallo
  # transitorio antes de abortar. Todos los ssh del flujo ya corren no-interactivos (auth por llave), asi que
  # BatchMode no cambia el camino sano.
  local i
  for i in 1 2; do
    ssh -o ConnectTimeout=10 -o BatchMode=yes -f -N -L "$TUNNEL_PORT:$WINHOST:$SITE_PORT" "$MACDATA" && return 0
    log "tunel: intento $i fallo (ssh); reintentando ..."
    sleep 2
  done
  die "no se pudo abrir el tunel (localhost:$TUNNEL_PORT -> $WINHOST:$SITE_PORT via $MACDATA) tras 2 intentos"
}

tunnel_down(){
  if pgrep -f "$TUNNEL_PORT:$WINHOST:$SITE_PORT" >/dev/null 2>&1; then
    pkill -f "$TUNNEL_PORT:$WINHOST:$SITE_PORT" && log "tunel cerrado (localhost:$TUNNEL_PORT)"
  else
    log "no hay tunel activo"
  fi
}

print_url(){
  guest_turn_heartbeat   # consultar la URL es señal de que la sesion sigue usando el site
  local code; code="$(guest_health)"
  printf '\n'
  printf '  +----------------------------------------------------------------+\n'
  printf '  |  Legado CargaPlantaPT_LN -- acceso                             |\n'
  printf '  +----------------------------------------------------------------+\n'
  printf '   Site:         %s   (slot %s)\n' "$SITE_NAME" "${SLOT:-<singleton>}"
  printf '   App (humo):   http://localhost:%s/health.aspx\n' "$TUNNEL_PORT"
  printf '   App (login):  http://localhost:%s/ProgramaMaestroLN/Login.aspx\n' "$TUNNEL_PORT"
  printf '   Tunel:        localhost:%s  ->  %s:%s  (via %s)\n' "$TUNNEL_PORT" "$WINHOST" "$SITE_PORT" "$MACDATA"
  printf '   Data tier:    %s  SQL:%s  Oracle:%s\n' "$MACDATA" "$SQL_PORT" "$ORACLE_PORT"
  printf '   Health guest: HTTP %s\n' "${code:-sin respuesta}"
  if [ -n "$SLOT" ]; then
    printf '   Parar:        make -C gs-pl-pm-macops-sidecar legacy-site-down SLOT=%s\n' "$SLOT"
  else
    printf '   Parar tunel:  make -C gs-pl-pm-macops-sidecar legacy-down   (libera tambien el turno del guest)\n'
  fi
  printf '\n'
  [ "$code" = "200" ] || warn "health != 200: revisar deploy/conn strings (rutas /ProgramaMaestroLN/ requieren vdir; ver runbook H-10)."
}

status(){
  guest_turn_heartbeat   # la sesion sigue viva sobre el singleton: su turno no debe envejecer
  log "estado del lanzamiento (site $SITE_NAME, slot ${SLOT:-<singleton>})"
  printf '   data tier (%s): ' "$MACDATA"
  ssh_md "nc -z -G 3 127.0.0.1 $SQL_PORT && nc -z -G 3 127.0.0.1 $ORACLE_PORT" 2>/dev/null \
    && echo "arriba (SQL:$SQL_PORT Oracle:$ORACLE_PORT)" || echo "abajo"
  printf '   VM/guest (%s): ' "$WINHOST"
  ssh_md "nc -z -G 3 $WINHOST 22" 2>/dev/null && echo "SSH arriba" || echo "sin SSH"
  printf '   app health: HTTP %s\n' "$(guest_health)"
  printf '   tunel local:%s: ' "$TUNNEL_PORT"
  pgrep -f "$TUNNEL_PORT:$WINHOST:$SITE_PORT" >/dev/null 2>&1 && echo "activo" || echo "inactivo"
  if [ -z "$SLOT" ] && [ -x "$GUEST_TURN_SH" ]; then
    printf '   '; "$GUEST_TURN_SH" status | head -1
    # Aviso de retencion prolongada del turno (vacio si esta libre o por debajo del umbral); indentado.
    "$GUEST_TURN_SH" hold-warn 2>/dev/null | sed 's/^/   /'
  fi
}

launch(){
  guest_turn_acquire
  data_up
  vm_up
  stage_build
  deploy
  guest_lock_release
  tunnel_up
  print_url
}

usage(){
  cat <<EOF
legacy.sh <verbo>  (orquesta el lanzamiento del legado; idempotente)
  launch        data tier (intel) + VM + build + deploy + tunel + URL (todo, inteligente)
  data-up       asegura el data tier en intel (omite si ya esta arriba)
  vm-up         asegura la VM Windows (omite si ya corre)
  build         sincroniza fuente + build en el guest (omite si health 200, salvo FORCE)
  deploy        publica en IIS del guest (omite si health 200, salvo FORCE)
  diag          habilita log de errores DETALLADO (Health Monitoring -> Event Log) + recicla el pool del slot
  diag-logs     vuelca los errores ASP.NET del Event Log del guest (var MAX=40)
  tunnel        abre el tunel SSH M1 -> guest (omite si ya activo)
  status        reporta estado de cada pieza
  url           imprime la URL/puertos de acceso
  down          cierra el tunel SSH y libera el turno del guest singleton
  site-down     desmonta el site per-slot del guest (exige SLOT; nunca toca el singleton)
  sites-status  lista los sites 'pm*' del guest cruzados con el registro de slots (marca huerfanos)
  slot-claim    arrienda un SLOT SOLO en el registro (sin PL.PM.sln; NO aprovisiona API/Oracle/BD); exige WT=<folder-legacy>
  slot-release  libera el arrendamiento de slot-claim (exige WT=<folder-legacy>)
  turn-status   estado del turno del guest singleton
  turn-heartbeat refresca el heartbeat del turno propio (sesiones largas de uso del site)
  turn-release  libera el turno del guest singleton de ESTA sesion

Vias:
  singleton (sin SLOT): site 'pm':8080, arbol C:\\src, tunel 18080; serializada por guest-turn.
  per-slot  (SLOT=N):   site 'pm-wt<N>':$SITE_PORT_BASE+N, arbol C:\\wt<N>, tunel $TUNNEL_PORT_BASE+N.

Lease del SLOT (launch/build/deploy): consultan slots.tsv antes de tocar el arbol del guest. Un SLOT arrendado
por OTRA sesion viva ABORTA (exit 3) salvo folder propio (WT=<folder> = columna 1 de la fila) o override
explicito LEASE_OVERRIDE=1 LEASE_OVERRIDE_REASON=<motivo> (FORCE=1 NO es este escape). Patron solo-legado (sin
PL.PM.sln): 'legacy-slot-claim WT=<folder-legacy>' -> anota el SLOT -> 'legacy-build SLOT=<N> WT=<folder-legacy>'
-> 'legacy-slot-release WT=<folder-legacy>'.

Variables (PM_LEGACY_*): MACDATA WINHOST SLOT SITE_PORT TUNNEL_PORT SQL_PORT ORACLE_PORT DBHOST PROFILE
                         DATATIER FORCE GUEST_TURN GUEST_LOCK GUEST_LOCK_TIMEOUT LEASE_OVERRIDE LEASE_OVERRIDE_REASON
EOF
}

case "${1:-}" in
  launch)   require_slot launch; require_slot_lease launch; launch ;;
  data-up)  data_up ;;
  vm-up)    vm_up ;;
  build)    require_slot build; require_slot_lease build; guest_turn_acquire; stage_build; guest_lock_release
            warn "'build' es solo la COMPUERTA DE COMPILACION del arbol del slot en el guest: si compilo, NO despliega ni re-inyecta el wiring runtime (backendBaseUrl + connection strings), y el site queda con los defaults del repo (backendBaseUrl=\"\"); si se OMITIO por health 200 (sin FORCE=1), el site corre el BINARIO VIEJO. En ambos casos el gateway a pm-api no opera bajo SQL-first: la validacion viva se hace SIEMPRE sobre 'make e2e-up WT=<wt-pm> LEGACYSRC=<path> FORCE=1' (ver process-e2e-local-slots.md D7)." ;;
  deploy)   require_slot deploy; require_slot_lease deploy; guest_turn_acquire; deploy; guest_lock_release
            warn "'deploy' publica el binario del slot en IIS pero NO re-inyecta el wiring runtime (backendBaseUrl + connection strings) ni corre la validacion; ademas se OMITE si el site responde health 200 (sin FORCE=1). Valida SIEMPRE sobre 'make e2e-up WT=<wt-pm> LEGACYSRC=<path> FORCE=1' (ver process-e2e-local-slots.md D7)." ;;
  diag)     diag ;;
  diag-logs) diag_logs ;;
  tunnel)   warn_tunnel_adhoc; tunnel_up ;;
  status)   status ;;
  url)      print_url ;;
  down)     tunnel_down; guest_turn_release ;;
  site-down) site_down ;;
  sites-status) sites_status ;;
  slot-claim)   slot_claim ;;
  slot-release) slot_release ;;
  turn-status)  [ -x "$GUEST_TURN_SH" ] || die "no se encontro $GUEST_TURN_SH"; "$GUEST_TURN_SH" status ;;
  turn-heartbeat) [ -x "$GUEST_TURN_SH" ] || die "no se encontro $GUEST_TURN_SH"; "$GUEST_TURN_SH" heartbeat ;;
  turn-release) [ -x "$GUEST_TURN_SH" ] || die "no se encontro $GUEST_TURN_SH"; shift; "$GUEST_TURN_SH" release "$@" ;;
  ""|help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
