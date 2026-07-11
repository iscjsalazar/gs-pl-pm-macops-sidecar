#!/usr/bin/env bash
# guest-turn.sh -- turno exclusivo del guest legado singleton (site 'pm':8080, arbol C:\src).
#
# Varias sesiones del orquestador comparten una unica VM Windows y, en la via
# SINGLETON del legado, un unico site IIS y un unico arbol fuente: el stage de
# una sesion borra el arbol de la otra y el deploy reescribe su Web.config.
# Este script implementa un mutex local por mkdir (atomico en el filesystem) con
# deteccion de sesiones muertas (vitalidad del proceso + heartbeat) y reclamo
# seguro por mv (rename atomico). Todas las transiciones del lock son mkdir/mv:
# el script no ejecuta rm.
#
# La via PER-SLOT (SLOT no vacio) no requiere este turno: cada slot tiene site,
# arbol y config propios. La seccion stage->build->deploy de AMBAS vias la
# serializa scripts/guest-lock.sh, que vive en macdata y cubre tambien a las
# sesiones de otras maquinas orquestadoras.
#
# Uso: guest-turn.sh <acquire|release|status|heartbeat|check-held-by-me> [opciones]
set -uo pipefail

SCRIPT_NAME=${0##*/}
HERE="$(cd "$(dirname "$0")" && pwd -P)"

# Raiz del arbol (ancestro con gs-pl-pm-macops-sidecar/): aloja el estado compartido de locks, que un
# git worktree del sidecar reusa en vez de fragmentar. Override duro: PM_WRAPPER_DIR.
_find_root(){ local d="$1"; while [ "$d" != "/" ]; do [ -d "$d/gs-pl-pm-macops-sidecar" ] && { printf '%s' "$d"; return 0; }; d="$(dirname "$d")"; done; return 1; }
WRAPPER_DIR="${PM_WRAPPER_DIR:-$(_find_root "$HERE" || true)}"
[ -n "$WRAPPER_DIR" ] || { printf 'ERROR: no se localizo la raiz del proyecto (ancestro con gs-pl-pm-macops-sidecar/); fija PM_WRAPPER_DIR\n' >&2; exit 1; }

BASE_DIR="${PM_GUEST_TURN_LOCK_BASE:-$WRAPPER_DIR/.locks}"
LOCK_DIR="$BASE_DIR/guest-legacy.lock"
GRAVEYARD="$BASE_DIR/graveyard"
LOG_FILE="$BASE_DIR/guest-turn-log.txt"

# Sin heartbeat por mas de este tiempo, el turno se REPORTA como abandonado.
HEARTBEAT_TTL="${GUEST_TURN_HEARTBEAT_TTL:-3600}"
POLL_SECONDS=10
# A diferencia de deploy-turn, el turno del guest se sostiene durante el USO del site (una persona navegando la
# UI puede no ejecutar ningun verbo en horas). Robarselo a una duena VIVA por heartbeat rancio desplegaria sobre
# el C:\src y el Web.config que esa sesion esta usando: exactamente lo que este lock existe para impedir. Por eso
# el reclamo automatico exige que el proceso duena este MUERTO. Un turno vivo pero abandonado se libera con
# 'release --force --reason "<texto>"', que exige orden explicita del usuario y queda en la bitacora.
STEAL_STALE="${GUEST_TURN_STEAL_STALE:-0}"

# Edad de RETENCION del turno (ahora - acquired_epoch), independiente del heartbeat: una duena viva pero
# abandonada sostiene el turno sin limite (por diseno launch/build/deploy lo retienen hasta down/release).
# Superado este umbral, 'status', 'legacy.sh sites-status' y 'wt-gc' lo marcan como retencion prolongada e
# imprimen el comando de rescate. Solo AVISA: no reintroduce el robo automatico a una duena viva.
GUEST_TURN_HOLD_WARN="${GUEST_TURN_HOLD_WARN:-14400}"   # 4 h: el doble de la validacion mas larga observada

info() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }

usage() {
  cat <<EOF
$SCRIPT_NAME -- turno exclusivo del guest legado singleton (site 'pm':8080, arbol C:\\src).

Subcomandos:
  acquire --tag <id> [--wait <seg>]
      Toma el turno. Sin --wait intenta una vez: si esta ocupado sale con
      codigo 3 (la sesion hace otra cosa y reintenta). Reclama solo los locks
      de sesiones muertas (pid) o abandonadas (heartbeat > ${HEARTBEAT_TTL}s).
      El reclamo automatico exige que el proceso duena este MUERTO: a una duena
      viva NO se le roba el turno aunque su heartbeat este rancio (estaria usando
      el site). GUEST_TURN_STEAL_STALE=1 revierte esa politica.
  release [--force --reason "<texto>"]
      Libera el turno propio. --force libera el ajeno (queda logueado);
      reservado a orden explicita del usuario. Es la via para un turno vivo
      pero abandonado.
  status
      Muestra si el turno esta libre u ocupado (duena, tag, edades, vitalidad).
      Marca RETENCION PROLONGADA si la edad de retencion supera ${GUEST_TURN_HOLD_WARN}s.
  hold-warn
      Imprime el aviso de retencion prolongada (si aplica) para embeberlo en
      sites-status / wt-gc; vacio si esta libre o por debajo del umbral.
  heartbeat
      Refresca el heartbeat del turno propio (sesiones largas de uso del site).
  check-held-by-me
      Sale 0 si esta sesion tiene el turno vivo; 1 si no.

La via per-slot (make e2e-up / make legacy-launch SLOT=N) NO usa este turno.
El lock vive en $LOCK_DIR
Bitacora append-only en $LOG_FILE
EOF
}

# --- Identidad de la sesion --------------------------------------------------
# La sesion se identifica por el proceso del CLI (o el shell interactivo si se
# corre a mano): primer ancestro cuyo ejecutable es claude/node/bun.
# pid + lstart distingue reciclaje de pids.
SESSION_PID=""
SESSION_LSTART=""
SESSION_COMM=""

find_session_pid() {
  if [ -n "${GUEST_TURN_SESSION_PID:-}" ]; then
    printf '%s' "$GUEST_TURN_SESSION_PID"
    return 0
  fi
  local pid=$$ comm base
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | sed 's/^ *//;s/ *$//')
    [ -n "$comm" ] || break
    base=${comm##*/}
    case "$base" in
      claude|node|bun) printf '%s' "$pid"; return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  printf '%s' "$PPID"
}

init_session() {
  SESSION_PID=$(find_session_pid)
  SESSION_LSTART=$(ps -p "$SESSION_PID" -o lstart= 2>/dev/null || true)
  SESSION_COMM=$(ps -p "$SESSION_PID" -o comm= 2>/dev/null | sed 's/^ *//;s/ *$//' || true)
}

# --- Estado del lock ---------------------------------------------------------
OWNER_PID=""
OWNER_LSTART=""
OWNER_TAG=""
OWNER_USER=""
OWNER_AT=""
OWNER_EPOCH=""

read_owner() {
  local f="$LOCK_DIR/owner"
  [ -f "$f" ] || return 1
  OWNER_PID=$(sed -n 's/^session_pid=//p' "$f")
  OWNER_LSTART=$(sed -n 's/^session_lstart=//p' "$f")
  OWNER_TAG=$(sed -n 's/^tag=//p' "$f")
  OWNER_USER=$(sed -n 's/^user=//p' "$f")
  OWNER_AT=$(sed -n 's/^acquired_at=//p' "$f")
  OWNER_EPOCH=$(sed -n 's/^acquired_epoch=//p' "$f")
  [ -n "$OWNER_PID" ]
}

owner_alive() {
  [ -n "$OWNER_PID" ] || return 1
  local cur
  cur=$(ps -p "$OWNER_PID" -o lstart= 2>/dev/null || true)
  [ -n "$cur" ] || return 1
  [ "$cur" = "$OWNER_LSTART" ]
}

owner_is_me() {
  [ -n "$OWNER_PID" ] && [ "$OWNER_PID" = "$SESSION_PID" ] && [ "$OWNER_LSTART" = "$SESSION_LSTART" ]
}

heartbeat_age() {
  local hb
  hb=$(stat -f %m "$LOCK_DIR/heartbeat" 2>/dev/null) || hb=0
  echo $(( $(date +%s) - hb ))
}

lock_dir_age() {
  local m
  m=$(stat -f %m "$LOCK_DIR" 2>/dev/null) || m=0
  echo $(( $(date +%s) - m ))
}

# Edad de retencion del turno actual (ahora - acquired_epoch). 0 si no hay epoch (lock viejo o sin owner).
hold_age() {
  [ -n "${OWNER_EPOCH:-}" ] || { echo 0; return; }
  echo $(( $(date +%s) - OWNER_EPOCH ))
}

# Imprime (a stdout) el aviso de retencion prolongada si el turno lleva tomado mas de GUEST_TURN_HOLD_WARN;
# nada si esta libre o por debajo del umbral. Self-contained (lee el owner). Lo consumen el verbo 'hold-warn'
# (para sites-status y wt-gc) y 'print_status'. Solo avisa; el rescate exige orden explicita del usuario.
print_hold_warn() {
  read_owner 2>/dev/null || return 0
  local age; age=$(hold_age)
  [ "$age" -gt "$GUEST_TURN_HOLD_WARN" ] 2>/dev/null || return 0
  printf 'RETENCION PROLONGADA del turno del guest: %ss tomado por %s (umbral %ss).\n' \
    "$age" "${OWNER_TAG:-?}" "$GUEST_TURN_HOLD_WARN"
  if owner_is_me; then
    printf '  es ESTA sesion; si ya no usas el site: %s release\n' "$SCRIPT_NAME"
  else
    printf '  rescate (solo con orden explicita del usuario): %s release --force --reason "<texto>"\n' "$SCRIPT_NAME"
  fi
}

log_event() {
  printf '%s | %-13s | tag=%s pid=%s user=%s | %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${2:-?}" "${SESSION_PID:-$$}" "$(id -un)" "${3:-}" >> "$LOG_FILE"
}

write_owner() {
  {
    printf 'session_pid=%s\n' "$SESSION_PID"
    printf 'session_lstart=%s\n' "$SESSION_LSTART"
    printf 'session_comm=%s\n' "$SESSION_COMM"
    printf 'tag=%s\n' "$1"
    printf 'user=%s\n' "$(id -un)"
    printf 'acquired_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'acquired_epoch=%s\n' "$(date +%s)"
  } > "$LOCK_DIR/owner"
  touch "$LOCK_DIR/heartbeat"
}

# Reclamo seguro: rename atomico al graveyard; solo un reclamante gana el mv.
steal_lock() {
  local why="$1" dest
  dest="$GRAVEYARD/guest-legacy.lock.$why.$(date +%s).$$"
  if mv "$LOCK_DIR" "$dest" 2>/dev/null; then
    log_event "steal-$why" "${OWNER_TAG:-?}" "duena pid=${OWNER_PID:-?} desde=${OWNER_AT:-?} -> $dest"
    info "lock de '${OWNER_TAG:-?}' (pid ${OWNER_PID:-?}) reclamado ($why); archivado en $dest"
    return 0
  fi
  return 1
}

print_status() {
  if ! read_owner 2>/dev/null; then
    if [ -d "$LOCK_DIR" ]; then
      echo "turno del guest: EN TRANSICION (lock sin owner; edad $(lock_dir_age)s)"
    else
      echo "turno del guest: LIBRE"
    fi
    return 0
  fi
  local vivo="MUERTA" hb
  owner_alive && vivo="viva"
  hb=$(heartbeat_age)
  echo "turno del guest: OCUPADO"
  echo "  tag       : $OWNER_TAG"
  echo "  duena     : pid $OWNER_PID ($vivo), user $OWNER_USER"
  echo "  desde     : $OWNER_AT ($(( $(date +%s) - ${OWNER_EPOCH:-$(date +%s)} ))s)"
  echo "  heartbeat : hace ${hb}s (TTL ${HEARTBEAT_TTL}s)"
  if owner_is_me; then
    echo "  nota      : el turno pertenece a ESTA sesion"
  fi
  if [ "$(hold_age)" -gt "$GUEST_TURN_HOLD_WARN" ] 2>/dev/null; then
    echo "  AVISO     : RETENCION PROLONGADA (> ${GUEST_TURN_HOLD_WARN}s). Rescate (orden explicita): $SCRIPT_NAME release --force --reason \"<texto>\""
  fi
}

# --- Subcomandos -------------------------------------------------------------
cmd_acquire() {
  local tag="" wait_s=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --tag) tag="${2:-}"; shift 2 ;;
      --wait) wait_s="${2:-0}"; shift 2 ;;
      *) die "acquire: opcion desconocida: $1" ;;
    esac
  done
  [ -n "$tag" ] || die "acquire: falta --tag <id-solicitud-o-proposito>"

  local deadline=$(( $(date +%s) + wait_s ))
  while :; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      write_owner "$tag"
      log_event "acquire" "$tag" "guest singleton"
      info "turno del guest adquirido (tag=$tag)."
      return 0
    fi
    if ! read_owner; then
      # Lock sin owner: o el ganador aun lo esta escribiendo, o quedo roto.
      if [ "$(lock_dir_age)" -gt 30 ]; then
        OWNER_TAG="(sin-owner)"; OWNER_PID=""; OWNER_AT=""
        steal_lock "broken" || true
      else
        sleep 1
      fi
      continue
    fi
    if owner_is_me; then
      touch "$LOCK_DIR/heartbeat"
      info "esta sesion ya tiene el turno del guest (tag=$OWNER_TAG); heartbeat refrescado."
      return 0
    fi
    if ! owner_alive; then
      steal_lock "dead" || true
      continue
    fi
    # La duena esta VIVA. Un heartbeat rancio se REPORTA, no se reclama (ver STEAL_STALE arriba).
    if [ "$(heartbeat_age)" -gt "$HEARTBEAT_TTL" ] && [ "$STEAL_STALE" = "1" ]; then
      steal_lock "stale" || true
      continue
    fi
    if [ "$(date +%s)" -lt "$deadline" ]; then
      sleep "$POLL_SECONDS"
      continue
    fi
    print_status
    if [ "$(heartbeat_age)" -gt "$HEARTBEAT_TTL" ]; then
      warn "la duena sigue VIVA pero su heartbeat tiene $(heartbeat_age)s (TTL ${HEARTBEAT_TTL}s): quiza olvido liberarlo."
      warn "Si confirmas que ya no usa el guest: $SCRIPT_NAME release --force --reason \"<texto>\""
    fi
    warn "guest singleton ocupado; reintentar mas tarde, o usar la via per-slot (make e2e-up WT=<worktree>)."
    return 3
  done
}

cmd_release() {
  local force="false" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force="true"; shift ;;
      --reason) reason="${2:-}"; shift 2 ;;
      *) die "release: opcion desconocida: $1" ;;
    esac
  done
  if [ ! -d "$LOCK_DIR" ]; then
    info "el turno del guest ya esta libre."
    return 0
  fi
  read_owner || true
  local dest
  if owner_is_me; then
    dest="$GRAVEYARD/guest-legacy.lock.released.$(date +%s).$$"
    mv "$LOCK_DIR" "$dest" || die "no se pudo liberar el lock."
    log_event "release" "${OWNER_TAG:-?}" "-> $dest"
    info "turno del guest liberado (tag=${OWNER_TAG:-?})."
    return 0
  fi
  if [ "$force" = "true" ]; then
    [ -n "$reason" ] || die "release --force exige --reason \"<texto>\" (queda en la bitacora)."
    dest="$GRAVEYARD/guest-legacy.lock.forced.$(date +%s).$$"
    mv "$LOCK_DIR" "$dest" || die "no se pudo forzar la liberacion."
    log_event "release-force" "${OWNER_TAG:-?}" "razon: $reason -> $dest"
    warn "turno del guest de '${OWNER_TAG:-?}' liberado a la fuerza. Razon: $reason"
    return 0
  fi
  print_status
  die "el turno pertenece a otra sesion; 'release --force --reason' SOLO con orden explicita del usuario." 4
}

cmd_heartbeat() {
  [ -d "$LOCK_DIR" ] || die "no hay turno tomado." 4
  read_owner || die "lock sin owner; nada que refrescar." 4
  owner_is_me || die "el turno pertenece a otra sesion (tag=$OWNER_TAG); heartbeat rechazado." 4
  touch "$LOCK_DIR/heartbeat"
  info "heartbeat del guest refrescado (tag=$OWNER_TAG)."
}

cmd_check_held_by_me() {
  [ -d "$LOCK_DIR" ] || return 1
  read_owner || return 1
  owner_is_me || return 1
  owner_alive || return 1
  return 0
}

# --- Main --------------------------------------------------------------------
mkdir -p "$BASE_DIR" "$GRAVEYARD"
init_session

CMD="${1:-}"
[ $# -gt 0 ] && shift
case "$CMD" in
  acquire)          cmd_acquire "$@" ;;
  release)          cmd_release "$@" ;;
  status)           print_status ;;
  hold-warn)        print_hold_warn ;;
  heartbeat)        cmd_heartbeat ;;
  check-held-by-me) cmd_check_held_by_me ;;
  -h|--help|help|"") usage; [ -n "$CMD" ] || exit 1 ;;
  *) die "subcomando desconocido: $CMD (ver --help)" ;;
esac
