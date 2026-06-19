#!/usr/bin/env bash
# Construye la VM Windows Server 2022 Core (headless, desatendida) con Packer (vmware-iso).
# Ejecutar EN la macdata:  bash ~/pm-host-windows/scripts/build-vm.sh
set -euo pipefail
export PATH=/usr/local/bin:$PATH

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # .../host-windows
ENV_FILE="$HERE/.env"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

ART="${ART:-$HERE/artifacts}"
ISO="${ISO:-$ART/iso/SERVER_EVAL_x64FRE_en-us.iso}"
: "${WINPASS:?falta WINPASS en $ENV_FILE}"
[ -f "$ISO" ] || { echo "ISO no encontrado: $ISO" >&2; exit 1; }

cd "$HERE/packer"
echo "[build-vm] generando Autounattend.xml desde plantilla ..."
sed "s|@@WINPASS@@|$WINPASS|g" Autounattend.xml.tmpl > Autounattend.xml   # gitignored

export PACKER_CACHE_DIR="$ART/cache"
echo "[build-vm] packer init ..."
packer init .

echo "[build-vm] packer build (headless, ~20-40 min) ... log: $ART/packer-build.log"
PACKER_LOG=1 PACKER_LOG_PATH="$ART/packer-build.log" \
  packer build -force \
    -var "iso_path=$ISO" \
    -var "winpass=$WINPASS" \
    -var "output_dir=$ART/vms/pm-win2022core" \
    windows-server-core.pkr.hcl

echo "[build-vm] LISTO. VMX:"
ls -la "$ART/vms/pm-win2022core/"*.vmx 2>/dev/null || true
