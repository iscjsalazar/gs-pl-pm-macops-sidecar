#!/usr/bin/env bash
# Compila la solucion legacy completa en el guest con la MSBuild de VS Build Tools (Roslyn + web targets).
# Corre EN la macdata.
#
# Arbol fuente segun SLOT: vacio -> C:\src\CargaPlantaPT_LN; <N> -> C:\wt<N>\CargaPlantaPT_LN.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # .../host-windows
ENV_FILE="$HERE/.env"
# Valores del invocador: se capturan ANTES del source del .env, que puede redefinirlos
# (precedencia invocador > .env > default).
_C_WINHOST="${WINHOST:-}"; _C_SLOT="${SLOT:-}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

KEY="${GUEST_KEY:-$HOME/pm-host-windows/artifacts/ssh/id_pmwin}"
G="${_C_WINHOST:-${WINHOST:-172.16.128.129}}"
SLOT="${_C_SLOT:-${SLOT:-}}"
SSHG(){ ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25 Administrator@"$G" "$@"; }

case "$SLOT" in
  '')       SRC_GUEST='C:\src\CargaPlantaPT_LN' ;;
  *[!0-9]*) echo "[build-app] SLOT no numerico: '$SLOT'" >&2; exit 2 ;;
  *)        SRC_GUEST="C:\\wt$SLOT\\CargaPlantaPT_LN" ;;
esac
SLN="$SRC_GUEST\\ProgramaMaestroPT.sln"

echo "== msbuild path (slot ${SLOT:-<singleton>}; fuente $SRC_GUEST) =="
SSHG 'Get-Content C:\buildtools.msbuildpath'

echo "== nuget restore (re-asegura) =="
SSHG "C:\\tools\\nuget.exe restore '$SLN' -NonInteractive 2>&1 | Select-Object -Last 3"

# /nr:false: sin nodos residentes de MSBuild. Los nodos sobreviven al build y se reusan entre invocaciones;
# compartidos entre arboles distintos arrastran estado del arbol anterior a los builds per-slot.
echo "== BUILD solution (ET + DAL + BL + ProgramaMaestroPT web) =="
SSHG "\$mb = (Get-Content C:\\buildtools.msbuildpath).Trim(); & \$mb '$SLN' /p:Configuration=Debug /m /nr:false /nologo /clp:Summary /v:m 2>&1 | Select-Object -Last 50"
echo "== EXIT build-app =="
