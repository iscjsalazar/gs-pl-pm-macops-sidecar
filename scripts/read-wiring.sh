#!/usr/bin/env bash
# Imprime el wiring REALMENTE desplegado del site del legado (clave=valor por linea; passwords enmascaradas).
# Corre EN la macdata; transfiere read-wiring.ps1 al guest y lo ejecuta.
#
# El valor efectivo de backendBaseUrl / conStringOracle / ConStrPm solo existe en el guest (el repo versiona
# placeholders). Esta es la unica fuente de verdad para verificar que un slot quedo cableado a SU backend, SU
# BD y SU Oracle -- y no a los de otra sesion.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # .../host-windows
ENV_FILE="$HERE/.env"
_C_WINHOST="${WINHOST:-}"; _C_SLOT="${SLOT:-}"     # valores del invocador (preceden a .env)
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

KEY="${GUEST_KEY:-$HOME/pm-host-windows/artifacts/ssh/id_pmwin}"
G="${_C_WINHOST:-${WINHOST:-172.16.128.129}}"
SLOT="${_C_SLOT:-${SLOT:-}}"
SSHG(){ ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 Administrator@"$G" "$@"; }

case "$SLOT" in
  '')       PS_GUEST='C:/read-wiring.ps1';        PS_GUEST_WIN='C:\read-wiring.ps1';        SLOT_ARG='' ;;
  *[!0-9]*) echo "[read-wiring] SLOT no numerico: '$SLOT'" >&2; exit 2 ;;
  *)        PS_GUEST="C:/read-wiring-wt$SLOT.ps1"; PS_GUEST_WIN="C:\\read-wiring-wt$SLOT.ps1"; SLOT_ARG=" -Slot $SLOT" ;;
esac

PS_LOCAL="$HERE/scripts/read-wiring.ps1"
[ -f "$PS_LOCAL" ] || { echo "[read-wiring] no existe $PS_LOCAL" >&2; exit 1; }

scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$PS_LOCAL" Administrator@"$G":"$PS_GUEST" \
  || { echo "[read-wiring] no se pudo copiar el script al guest" >&2; exit 1; }
SSHG "powershell -NoProfile -ExecutionPolicy Bypass -File $PS_GUEST_WIN$SLOT_ARG" 2>/dev/null | tr -d '\r'
