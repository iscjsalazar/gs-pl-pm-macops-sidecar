#!/usr/bin/env bash
# Arranca (idempotente) la VM Windows del legado y espera el SSH del guest. Corre EN la macdata.
# No construye la VM (eso es build-vm.sh); solo la enciende si esta apagada.
set -uo pipefail
export PATH=/usr/local/bin:$PATH
# vmrun no siempre esta en PATH en macdata; resolver al de VMware Fusion como fallback.
VMRUN="$(command -v vmrun || true)"
[ -n "$VMRUN" ] || VMRUN="/Applications/VMware Fusion.app/Contents/Library/vmrun"

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # .../host-windows
ENV_FILE="$HERE/.env"
_C_WINHOST="${WINHOST:-}"                          # valor del invocador (precede a .env)
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

ART="${ART:-$HERE/artifacts}"
VMNAME="${VMNAME:-pm-win2022core}"
VMX="${VMX:-$ART/vms/$VMNAME/$VMNAME.vmx}"
WINHOST="${_C_WINHOST:-${WINHOST:-172.16.128.129}}"

[ -f "$VMX" ] || { echo "[vm-up] VMX no encontrado: $VMX (correr build-vm.sh primero)" >&2; exit 1; }

if "$VMRUN" -T fusion list 2>/dev/null | grep -qF "$VMX"; then
  echo "[vm-up] VM ya corriendo -> no se relanza"
else
  echo "[vm-up] iniciando VM headless: $VMX"
  # Dos sesiones pueden pasar el 'list' antes de que ninguna arranque: el 'start' del perdedor falla sobre una
  # VM que YA esta corriendo. Se re-verifica el estado real antes de darlo por error.
  if ! "$VMRUN" -T fusion start "$VMX" nogui; then
    if "$VMRUN" -T fusion list 2>/dev/null | grep -qF "$VMX"; then
      echo "[vm-up] el arranque fallo pero la VM aparece corriendo (otra sesion la levanto) -> se continua"
    else
      echo "[vm-up] fallo al iniciar la VM" >&2; exit 1
    fi
  fi
fi

echo "[vm-up] esperando SSH del guest $WINHOST:22 ..."
for i in $(seq 1 40); do
  if nc -z -G 3 "$WINHOST" 22 2>/dev/null; then echo "[vm-up] guest SSH OK"; exit 0; fi
  sleep 3
done
echo "[vm-up] el guest no respondio SSH a tiempo" >&2
exit 1
