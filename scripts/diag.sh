#!/usr/bin/env bash
# Habilita el log de errores detallado del legado en el guest (Health Monitoring -> Event Log) y recicla el
# app pool. Corre EN la macdata; transfiere enable-error-log.ps1 y lo ejecuta.
#
# Con SLOT=<N> opera el arbol y el pool del slot (C:\wt<N>, pm-wt<N>) y el ps1 viaja a un path per-slot.
# CLEAR_EVENT_LOG=1 limpia el Application Event Log, que es COMPARTIDO por toda la VM (default: no se limpia).
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # .../host-windows
ENV_FILE="$HERE/.env"
# Valores del invocador: se capturan ANTES del source del .env (precedencia invocador > .env > default).
_C_WINHOST="${WINHOST:-}"; _C_SLOT="${SLOT:-}"; _C_CLEAR="${CLEAR_EVENT_LOG:-}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

KEY="${GUEST_KEY:-$HOME/pm-host-windows/artifacts/ssh/id_pmwin}"
G="${_C_WINHOST:-${WINHOST:-172.16.128.129}}"
SLOT="${_C_SLOT:-${SLOT:-}}"
CLEAR_EVENT_LOG="${_C_CLEAR:-${CLEAR_EVENT_LOG:-0}}"
SSHG(){ ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25 Administrator@"$G" "$@"; }

case "$SLOT" in
  '')       PS_GUEST='C:/enable-error-log.ps1';        PS_GUEST_WIN='C:\enable-error-log.ps1';        SLOT_ARG='' ;;
  *[!0-9]*) echo "[diag] SLOT no numerico: '$SLOT'" >&2; exit 2 ;;
  *)        PS_GUEST="C:/enable-error-log-wt$SLOT.ps1"; PS_GUEST_WIN="C:\\enable-error-log-wt$SLOT.ps1"; SLOT_ARG=" -Slot $SLOT" ;;
esac
CLEAR_ARG=""
[ "$CLEAR_EVENT_LOG" = "1" ] && CLEAR_ARG=" -ClearEventLog"

PS_LOCAL="$HERE/scripts/enable-error-log.ps1"
[ -f "$PS_LOCAL" ] || { echo "[diag] no existe $PS_LOCAL" >&2; exit 1; }

echo "[diag] copiando enable-error-log.ps1 al guest ($PS_GUEST; slot ${SLOT:-<singleton>})"
scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$PS_LOCAL" Administrator@"$G":"$PS_GUEST"

echo "[diag] habilitando Health Monitoring + reciclando el pool del slot en el guest"
SSHG "powershell -NoProfile -ExecutionPolicy Bypass -File $PS_GUEST_WIN$SLOT_ARG$CLEAR_ARG"
echo "[diag] EXIT"
