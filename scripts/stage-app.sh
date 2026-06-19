#!/usr/bin/env bash
# Transfiere la fuente del legado (ya staged en macdata) al guest: zip -> scp -> extract en C:\src.
# Corre EN la macdata. La fuente incluye Bin\Oracle.ManagedDataAccess.dll versionada (resuelve el HintPath).
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # .../host-windows
ENV_FILE="$HERE/.env"
_C_WINHOST="${WINHOST:-}"                          # valor del invocador (precede a .env)
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

ART="${ART:-$HERE/artifacts}"
STAGE="${STAGE:-$ART/stage}"
KEY="${GUEST_KEY:-$HOME/pm-host-windows/artifacts/ssh/id_pmwin}"
G="${_C_WINHOST:-${WINHOST:-172.16.128.129}}"
SSHG(){ ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25 Administrator@"$G" "$@"; }

[ -d "$STAGE/CargaPlantaPT_LN" ] || { echo "[stage-app] no existe $STAGE/CargaPlantaPT_LN (sincronizar la fuente primero)" >&2; exit 1; }

cd "$STAGE"
echo "[stage-app] zip + scp fuente -> guest"
rm -f CargaPlantaPT_LN.zip
zip -qr CargaPlantaPT_LN.zip CargaPlantaPT_LN
echo "[stage-app] zip: $(du -h CargaPlantaPT_LN.zip | cut -f1)"
scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null CargaPlantaPT_LN.zip Administrator@"$G":C:/src.zip

echo "[stage-app] extract en guest -> C:\\src"
SSHG 'Remove-Item C:\src -Recurse -Force -ErrorAction SilentlyContinue; Expand-Archive -Path C:\src.zip -DestinationPath C:\src -Force; (Get-ChildItem C:\src\CargaPlantaPT_LN).Name -join ", "'
echo "[stage-app] EXIT"
