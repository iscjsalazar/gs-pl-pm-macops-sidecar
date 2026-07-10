#!/usr/bin/env bash
# Lock de la seccion stage->build->deploy del guest legado. Corre EN la macdata.
#
# Tres recursos del guest son compartidos por TODOS los sites, incluidos los per-slot:
#   - los nodos residentes de MSBuild y los vCPU de la VM (un build satura la maquina),
#   - el applicationHost.config de IIS (los cmdlets de WebAdministration concurrentes fallan al commitear),
#   - el Event Log y las features machine-wide (WCF HTTP Activation).
# El lock vive en macdata (no en el orquestador), asi que cubre tambien a sesiones de otras maquinas.
#
# Transiciones por mkdir/mv (rename atomico); nunca rm. Antes de reclamar un lock rancio consulta al guest:
# si hay un MSBuild vivo, no roba (la sesion duena esta trabajando aunque su heartbeat se haya quedado atras).
#
#   guest-lock.sh acquire --owner <id> [--timeout <seg>]   # 0 = adquirido; 1 = timeout/error
#   guest-lock.sh touch   --owner <id>                      # refresca el heartbeat entre fases
#   guest-lock.sh release --owner <id> [--force]            # libera (mv al graveyard)
#   guest-lock.sh status
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # .../pm-host-windows
ENV_FILE="$HERE/.env"
_C_WINHOST="${WINHOST:-}"                          # valor del invocador (precede a .env)
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

KEY="${GUEST_KEY:-$HOME/pm-host-windows/artifacts/ssh/id_pmwin}"
G="${_C_WINHOST:-${WINHOST:-172.16.128.129}}"

BASE_DIR="${GUEST_LOCK_BASE:-$HERE/.locks}"
LOCK_DIR="$BASE_DIR/guest.lock"
GRAVEYARD="$BASE_DIR/graveyard"
LOG_FILE="$BASE_DIR/guest-lock-log.txt"

# Espera por defecto: un stage+build+deploy en frio ronda los 10-15 min; 1800 s deja a la segunda sesion
# esperar un ciclo completo de la primera en vez de fallar.
DEFAULT_TIMEOUT="${GUEST_LOCK_TIMEOUT:-1800}"
# Sin heartbeat por mas de este tiempo el lock se considera rancio (el guard de MSBuild decide el robo).
STALE_TTL="${GUEST_LOCK_STALE_TTL:-2700}"
POLL_SECONDS="${GUEST_LOCK_POLL:-5}"

log(){ printf '[guest-lock] %s\n' "$*" >&2; }
die(){ printf '[guest-lock] ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }
log_event(){ printf '%s | %-10s | owner=%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${2:-?}" "${3:-}" >> "$LOG_FILE"; }

SSHG(){ ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 Administrator@"$G" "$@"; }

owner_file(){ printf '%s' "$LOCK_DIR/owner"; }
read_owner(){ [ -f "$(owner_file)" ] && cat "$(owner_file)" 2>/dev/null | tr -d '\r\n'; }

heartbeat_age(){
  local hb; hb=$(stat -f %m "$LOCK_DIR/heartbeat" 2>/dev/null) || hb=$(stat -f %m "$LOCK_DIR" 2>/dev/null) || hb=0
  echo $(( $(date +%s) - hb ))
}

# El guest esta compilando? Cualquier respuesta que no sea un 0 inequivoco se trata como "si" (fail-closed):
# un guest inalcanzable no autoriza el robo del lock.
guest_msbuild_running(){
  local n
  n="$(SSHG 'powershell -NoProfile -Command "(Get-Process msbuild -ErrorAction SilentlyContinue | Measure-Object).Count"' 2>/dev/null | tr -d ' \r\n')"
  case "$n" in
    0) return 1 ;;
    *) return 0 ;;
  esac
}

# Reclamo seguro: rename atomico al graveyard; solo un reclamante gana el mv. Nunca rm.
# El owner se recibe como argumento: tras el mv el archivo ya no esta donde read_owner lo busca.
steal_lock(){  # uso: steal_lock <motivo> <owner-previo>
  local why="$1" prev="${2:-?}" dest
  dest="$GRAVEYARD/guest.lock.$why.$(date +%s).$$"
  if mv "$LOCK_DIR" "$dest" 2>/dev/null; then
    log_event "steal-$why" "$prev" "-> $dest"
    log "lock reclamado ($why; duena previa '${prev}'); archivado en $dest"
    return 0
  fi
  return 1
}

cmd_acquire(){
  local owner="" timeout="$DEFAULT_TIMEOUT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner) owner="${2:-}"; shift 2 ;;
      --timeout) timeout="${2:-$DEFAULT_TIMEOUT}"; shift 2 ;;
      *) die "acquire: opcion desconocida: $1" ;;
    esac
  done
  [ -n "$owner" ] || die "acquire: falta --owner <id>"

  local deadline=$(( $(date +%s) + timeout )) cur announced=0
  while :; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s' "$owner" > "$(owner_file)"
      touch "$LOCK_DIR/heartbeat"
      log_event "acquire" "$owner" ""
      log "lock del guest adquirido (owner=$owner)"
      return 0
    fi
    cur="$(read_owner || true)"
    if [ -n "$cur" ] && [ "$cur" = "$owner" ]; then
      touch "$LOCK_DIR/heartbeat"
      log "esta invocacion ya tiene el lock (owner=$owner); heartbeat refrescado"
      return 0
    fi
    # Lock sin owner: el ganador aun lo escribe, o quedo roto.
    if [ -z "$cur" ] && [ "$(heartbeat_age)" -gt 60 ]; then
      steal_lock "broken" "(sin-owner)" || true
      continue
    fi
    if [ "$(heartbeat_age)" -gt "$STALE_TTL" ]; then
      if guest_msbuild_running; then
        log "lock rancio (heartbeat $(heartbeat_age)s) pero el guest tiene MSBuild vivo: NO se reclama"
      else
        steal_lock "stale" "$cur" || true
        continue
      fi
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "timeout (${timeout}s) esperando el lock del guest; lo tiene '${cur:-?}' (heartbeat hace $(heartbeat_age)s)"
      return 1
    fi
    [ "$announced" = "1" ] || { log "guest ocupado por '${cur:-?}': esperando (hasta ${timeout}s) ..."; announced=1; }
    sleep "$POLL_SECONDS"
  done
}

cmd_touch(){
  local owner=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner) owner="${2:-}"; shift 2 ;;
      *) die "touch: opcion desconocida: $1" ;;
    esac
  done
  [ -d "$LOCK_DIR" ] || { log "no hay lock que refrescar"; return 0; }
  local cur; cur="$(read_owner || true)"
  [ "$cur" = "$owner" ] || { log "el lock lo tiene '${cur:-?}', no '$owner'; heartbeat no refrescado"; return 1; }
  touch "$LOCK_DIR/heartbeat"
}

cmd_release(){
  local owner="" force="false"
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner) owner="${2:-}"; shift 2 ;;
      --force) force="true"; shift ;;
      *) die "release: opcion desconocida: $1" ;;
    esac
  done
  [ -d "$LOCK_DIR" ] || { log "el lock del guest ya esta libre"; return 0; }
  local cur dest; cur="$(read_owner || true)"
  if [ "$cur" != "$owner" ] && [ "$force" != "true" ]; then
    log "el lock lo tiene '${cur:-?}', no '$owner': no se libera (usa --force solo con orden explicita)"
    return 1
  fi
  dest="$GRAVEYARD/guest.lock.released.$(date +%s).$$"
  mv "$LOCK_DIR" "$dest" || { log "no se pudo liberar el lock"; return 1; }
  log_event "release" "${cur:-?}" "-> $dest"
  log "lock del guest liberado (owner=${cur:-?})"
}

cmd_status(){
  if [ ! -d "$LOCK_DIR" ]; then echo "lock del guest: LIBRE"; return 0; fi
  echo "lock del guest: OCUPADO"
  echo "  owner     : $(read_owner || echo '(sin owner)')"
  echo "  heartbeat : hace $(heartbeat_age)s (rancio > ${STALE_TTL}s)"
  printf '  msbuild   : '; guest_msbuild_running && echo "vivo en el guest" || echo "sin MSBuild"
}

mkdir -p "$BASE_DIR" "$GRAVEYARD"

case "${1:-}" in
  acquire) shift; cmd_acquire "$@" ;;
  touch)   shift; cmd_touch "$@" ;;
  release) shift; cmd_release "$@" ;;
  status)  cmd_status ;;
  *) echo "uso: $0 {acquire|touch|release|status} --owner <id> [--timeout <seg>] [--force]" >&2; exit 2 ;;
esac
