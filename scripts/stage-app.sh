#!/usr/bin/env bash
# Transfiere la fuente del legado (ya staged en macdata) al guest: zip -> scp -> extract.
# Corre EN la macdata. La fuente incluye Bin\Oracle.ManagedDataAccess.dll versionada (resuelve el HintPath).
#
# Destino segun SLOT:
#   SLOT vacio -> C:\src     (via singleton; comportamiento historico)
#   SLOT=<N>   -> C:\wt<N>   (via per-slot)
# Los arboles per-slot viven FUERA de C:\src a proposito: un checkout desactualizado del sidecar ejecuta el
# 'Remove-Item C:\src -Recurse' de la version vieja de este script y arrasaria cualquier arbol anidado ahi,
# con sites vivos apuntandole.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # .../host-windows
ENV_FILE="$HERE/.env"
# Valores del invocador: se capturan ANTES del source del .env, que puede redefinirlos
# (precedencia invocador > .env > default).
_C_WINHOST="${WINHOST:-}"; _C_SLOT="${SLOT:-}"; _C_STAGE="${STAGE:-}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

ART="${ART:-$HERE/artifacts}"
STAGE="${_C_STAGE:-${STAGE:-$ART/stage}}"
SLOT="${_C_SLOT:-${SLOT:-}}"
KEY="${GUEST_KEY:-$HOME/pm-host-windows/artifacts/ssh/id_pmwin}"
G="${_C_WINHOST:-${WINHOST:-172.16.128.129}}"
SSHG(){ ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25 Administrator@"$G" "$@"; }

case "$SLOT" in
  '')       DEST='C:\src';      ZIP='C:/src.zip' ;;
  *[!0-9]*) echo "[stage-app] SLOT no numerico: '$SLOT'" >&2; exit 2 ;;
  *)        DEST="C:\\wt$SLOT"; ZIP="C:/src-wt$SLOT.zip" ;;
esac

[ -d "$STAGE/CargaPlantaPT_LN" ] || { echo "[stage-app] no existe $STAGE/CargaPlantaPT_LN (sincronizar la fuente primero)" >&2; exit 1; }

cd "$STAGE"
echo "[stage-app] zip + scp fuente -> guest ($ZIP)"
rm -f CargaPlantaPT_LN.zip
zip -qr CargaPlantaPT_LN.zip CargaPlantaPT_LN
echo "[stage-app] zip: $(du -h CargaPlantaPT_LN.zip | cut -f1)"
scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null CargaPlantaPT_LN.zip Administrator@"$G":"$ZIP"

# El shell SSH por defecto del guest es PowerShell: el comando viaja tal cual.
echo "[stage-app] extract en guest -> $DEST"
SSHG "Remove-Item '$DEST' -Recurse -Force -ErrorAction SilentlyContinue; Expand-Archive -Path '$ZIP' -DestinationPath '$DEST' -Force; (Get-ChildItem '$DEST\\CargaPlantaPT_LN').Name -join ', '"
echo "[stage-app] EXIT"
