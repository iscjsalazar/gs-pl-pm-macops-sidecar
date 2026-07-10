#!/usr/bin/env bash
# Desmonta el frontend per-slot del guest (site, pool, arbol, raiz, zip, scripts, regla de firewall) y el
# stage per-slot de macdata. Corre EN la macdata; transfiere site-down.ps1 al guest y lo ejecuta.
#
# Exige SLOT numerico: solo toca artefactos cuyo nombre deriva de el. El site singleton 'pm' (:8080) y los
# demas slots quedan intactos. Idempotente.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # .../pm-host-windows
ENV_FILE="$HERE/.env"
_C_WINHOST="${WINHOST:-}"; _C_SLOT="${SLOT:-}"; _C_STAGE_BASE="${STAGE_BASE:-}"   # valores del invocador (preceden a .env)
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

KEY="${GUEST_KEY:-$HOME/pm-host-windows/artifacts/ssh/id_pmwin}"
G="${_C_WINHOST:-${WINHOST:-172.16.128.129}}"
SLOT="${_C_SLOT:-${SLOT:-}}"
ART="${ART:-$HERE/artifacts}"
STAGE_BASE="${_C_STAGE_BASE:-${STAGE_BASE:-$ART/stage}}"

case "$SLOT" in
  ''|*[!0-9]*) echo "[site-down] ERROR: SLOT ausente o no numerico ('$SLOT'); este verbo NUNCA opera el site singleton 'pm'" >&2; exit 2 ;;
esac

SSHG(){ ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25 Administrator@"$G" "$@"; }

PS_LOCAL="$HERE/scripts/site-down.ps1"
[ -f "$PS_LOCAL" ] || { echo "[site-down] no existe $PS_LOCAL" >&2; exit 1; }

echo "[site-down] copiando site-down.ps1 al guest (slot $SLOT)"
scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$PS_LOCAL" Administrator@"$G":C:/site-down-wt$SLOT.ps1 \
  || { echo "[site-down] aviso: no se pudo copiar el script al guest (guest apagado?)" >&2; }

echo "[site-down] desmontando el site pm-wt$SLOT en el guest"
SSHG "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\site-down-wt$SLOT.ps1 -Slot $SLOT" \
  || echo "[site-down] aviso: el desmontaje en el guest reporto errores (se continua con el stage local)" >&2

# Stage per-slot en macdata. La ruta deriva del slot; el stage singleton ($STAGE_BASE/CargaPlantaPT_LN) no se toca.
STAGE_SLOT="$STAGE_BASE/wt$SLOT"
if [ -d "$STAGE_SLOT" ]; then
  rm -rf "$STAGE_SLOT" && echo "[site-down] stage local retirado: $STAGE_SLOT"
else
  echo "[site-down] stage local ausente: $STAGE_SLOT"
fi
echo "[site-down] EXIT"
