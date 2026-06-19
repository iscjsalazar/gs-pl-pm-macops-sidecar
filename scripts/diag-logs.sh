#!/usr/bin/env bash
# Vuelca los errores ASP.NET (Health Monitoring) del Event Log del guest, con detalle completo.
# Corre EN la macdata; transfiere read-error-log.ps1 y lo ejecuta. Var: MAX (default 40).
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # .../host-windows
ENV_FILE="$HERE/.env"
_C_WINHOST="${WINHOST:-}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

KEY="${GUEST_KEY:-$HOME/pm-host-windows/artifacts/ssh/id_pmwin}"
G="${_C_WINHOST:-${WINHOST:-172.16.128.129}}"
MAX="${MAX:-40}"
SSHG(){ ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25 Administrator@"$G" "$@"; }

PS_LOCAL="$HERE/scripts/read-error-log.ps1"
[ -f "$PS_LOCAL" ] || { echo "[diag-logs] no existe $PS_LOCAL" >&2; exit 1; }

scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$PS_LOCAL" Administrator@"$G":C:/read-error-log.ps1
SSHG "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\read-error-log.ps1 -Max $MAX"
