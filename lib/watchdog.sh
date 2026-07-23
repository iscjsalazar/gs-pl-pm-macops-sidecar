#!/usr/bin/env bash
# Watchdog portable del sidecar: techo total sobre un comando, kill de arbol TERM->KILL.
# Semantica: rc original en exito/fallo ordinario; 124 al vencer; 130 ante INT/TERM del handler del caller.
# Variables de contexto (opcionales, no secretos):
#   RESULT_ROOT | WATCHDOG_MARKER_DIR — directorio para el marcador de timeout
#   PHASE — nombre corto de la fase (diagnostico)
#   WATCHDOG_RUNNER — identificador del runner (diagnostico)
# El caller puede observar ACTIVE_CMD_PID / ACTIVE_WATCHDOG_PID para limpiar ante senales.

watchdog_valid_uint(){ case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

process_tree(){
  local pid="$1" child children
  children="$(pgrep -P "$pid" 2>/dev/null || true)"
  for child in $children; do process_tree "$child"; done
  printf '%s\n' "$pid"
}

run_with_watchdog(){
  local timeout_s="$1"; shift
  if ! watchdog_valid_uint "$timeout_s" || [ "$timeout_s" -le 0 ]; then
    if type die >/dev/null 2>&1; then
      die "timeout invalido '$timeout_s'"
    fi
    printf 'ERROR [watchdog]: timeout invalido %s\n' "$timeout_s" >&2
    return 1
  fi
  local cmd_pid watchdog_pid rc=0 marker tree pid
  local root="${RESULT_ROOT:-${WATCHDOG_MARKER_DIR:-${TMPDIR:-/tmp}}}"
  local phase="${PHASE:-cmd}"
  mkdir -p "$root" 2>/dev/null || true
  marker="$root/.timeout-$phase-$$"
  "$@" & cmd_pid=$!; ACTIVE_CMD_PID="$cmd_pid"
  (
    sleep "$timeout_s"
    if kill -0 "$cmd_pid" 2>/dev/null; then
      mkdir "$marker" 2>/dev/null || true
      tree="$(process_tree "$cmd_pid")"
      for pid in $tree; do kill -TERM "$pid" 2>/dev/null || true; done
      sleep 5
      for pid in $tree; do kill -KILL "$pid" 2>/dev/null || true; done
    fi
  ) & watchdog_pid=$!; ACTIVE_WATCHDOG_PID="$watchdog_pid"
  wait "$cmd_pid" || rc=$?
  if [ -d "$marker" ]; then
    wait "$watchdog_pid" 2>/dev/null || true
    rmdir "$marker" 2>/dev/null || true
    ACTIVE_CMD_PID=''; ACTIVE_WATCHDOG_PID=''
    printf 'ERROR [watchdog]: phase=%s runner=%s timeout_s=%s exit=124\n' \
      "$phase" "${WATCHDOG_RUNNER:-?}" "$timeout_s" >&2
    return 124
  fi
  tree="$(process_tree "$watchdog_pid")"
  for pid in $tree; do kill -TERM "$pid" 2>/dev/null || true; done
  wait "$watchdog_pid" 2>/dev/null || true
  ACTIVE_CMD_PID=''; ACTIVE_WATCHDOG_PID=''
  return "$rc"
}
