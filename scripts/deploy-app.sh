#!/usr/bin/env bash
# Publica el web project legacy en IIS del guest (app pool .NET v4.0, site en SITE_PORT) y deja health.aspx.
# Corre EN la macdata; transfiere deploy-iis.ps1 al guest y lo ejecuta. Idempotente (recrea el site).
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # .../host-windows
ENV_FILE="$HERE/.env"
_C_WINHOST="${WINHOST:-}"; _C_SITE_PORT="${SITE_PORT:-}"   # valores del invocador (preceden a .env)
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

KEY="${GUEST_KEY:-$HOME/pm-host-windows/artifacts/ssh/id_pmwin}"
G="${_C_WINHOST:-${WINHOST:-172.16.128.129}}"
SITE_PORT="${_C_SITE_PORT:-${SITE_PORT:-${SITE_PORT_48:-8080}}}"
SSHG(){ ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25 Administrator@"$G" "$@"; }

PS_LOCAL="$HERE/scripts/deploy-iis.ps1"
[ -f "$PS_LOCAL" ] || { echo "[deploy-app] no existe $PS_LOCAL" >&2; exit 1; }
DBHOST="${PM_LEGACY_DBHOST:-172.16.128.1}"   # IP del data tier (Oracle) vista DESDE el guest (host del bridge)

echo "[deploy-app] copiando deploy-iis.ps1 al guest (site :$SITE_PORT, oracle $DBHOST)"
scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$PS_LOCAL" Administrator@"$G":C:/deploy-iis.ps1

echo "[deploy-app] ejecutando deploy en el guest (vdir ProgramaMaestroLN + conn string data tier)"
SSHG "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\deploy-iis.ps1 -Port $SITE_PORT -OracleHost $DBHOST"

echo "[deploy-app] verificando health en el guest"
SSHG "powershell -NoProfile -Command \"(Invoke-WebRequest -UseBasicParsing http://localhost:$SITE_PORT/health.aspx).StatusCode\""
echo "[deploy-app] EXIT"
