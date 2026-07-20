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
_C_WINHOST="${WINHOST:-}"; _C_SLOT="${SLOT:-}"; _C_STAGE="${STAGE:-}"; _C_CLEAN="${CLEAN:-}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

ART="${ART:-$HERE/artifacts}"
STAGE="${_C_STAGE:-${STAGE:-$ART/stage}}"
SLOT="${_C_SLOT:-${SLOT:-}}"
# I5: 0 (default) = sincroniza PRESERVANDO bin/obj/packages del guest (MSBuild incremental); 1 = wipe total previo.
CLEAN="${_C_CLEAN:-${CLEAN:-0}}"
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
if [ "$CLEAN" = "1" ]; then
  # CLEAN=1: comportamiento previo (wipe total del arbol del guest + extract). Arrasa bin/obj/packages.
  echo "[stage-app] CLEAN=1: wipe total + extract en guest -> $DEST"
  SSHG "Remove-Item '$DEST' -Recurse -Force -ErrorAction SilentlyContinue; Expand-Archive -Path '$ZIP' -DestinationPath '$DEST' -Force; (Get-ChildItem '$DEST\\CargaPlantaPT_LN').Name -join ', '"
else
  # Incremental: extrae a un stage DESECHABLE y sincroniza (robocopy /MIR) al arbol del guest PRESERVANDO
  # bin/obj/packages (habilita MSBuild incremental + evita re-restore). robocopy retorna 0-7 en exito y >=8 en
  # error (se traduce a rc). La DLL versionada Oracle.ManagedDataAccess.dll vive en bin\ (excluida del /MIR): se
  # copia aparte sin purge para no perderla en el primer stage. STG = <DEST>.stage (fuera del arbol vivo).
  STG="${DEST}.stage"
  echo "[stage-app] incremental (preserva bin/obj/packages) en guest -> $DEST (CLEAN=1 para wipe total)"
  SSHG "\$ErrorActionPreference='Stop'; \
Remove-Item '$STG' -Recurse -Force -ErrorAction SilentlyContinue; \
Expand-Archive -Path '$ZIP' -DestinationPath '$STG' -Force; \
\$rc=0; \
robocopy '$STG\\CargaPlantaPT_LN' '$DEST\\CargaPlantaPT_LN' /MIR /XD bin obj packages /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null; \
if (\$LASTEXITCODE -ge 8) { \$rc=\$LASTEXITCODE }; \
robocopy '$STG\\CargaPlantaPT_LN\\ProgramaMaestroPT\\bin' '$DEST\\CargaPlantaPT_LN\\ProgramaMaestroPT\\bin' Oracle.ManagedDataAccess.dll /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null; \
if (\$LASTEXITCODE -ge 8) { \$rc=\$LASTEXITCODE }; \
Remove-Item '$STG' -Recurse -Force -ErrorAction SilentlyContinue; \
if (\$rc -ne 0) { Write-Error \"robocopy fallo (rc=\$rc)\"; exit 1 }; \
(Get-ChildItem '$DEST\\CargaPlantaPT_LN').Name -join ', '"
fi
echo "[stage-app] EXIT"
