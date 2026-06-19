#!/usr/bin/env bash
# Habilita el log de errores detallado del legado en el guest (Health Monitoring -> Event Log),
# recicla el app pool y limpia el Event Log. Corre EN la macdata; transfiere enable-error-log.ps1 y lo ejecuta.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # .../host-windows
ENV_FILE="$HERE/.env"
_C_WINHOST="${WINHOST:-}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

KEY="${GUEST_KEY:-$HOME/pm-host-windows/artifacts/ssh/id_pmwin}"
G="${_C_WINHOST:-${WINHOST:-172.16.128.129}}"
SSHG(){ ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25 Administrator@"$G" "$@"; }

PS_LOCAL="$HERE/scripts/enable-error-log.ps1"
[ -f "$PS_LOCAL" ] || { echo "[diag] no existe $PS_LOCAL" >&2; exit 1; }

echo "[diag] copiando enable-error-log.ps1 al guest"
scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$PS_LOCAL" Administrator@"$G":C:/enable-error-log.ps1

echo "[diag] habilitando Health Monitoring + reciclando pool en el guest"
SSHG 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\enable-error-log.ps1'
echo "[diag] EXIT"
