#!/usr/bin/env bash
# Bootstrap de UNA sola vez en la mac Intel (x86_64) que hospedara el data tier.
# Idempotente: instala/verifica colima + docker + compose y arranca la VM con specs (D6).
# Ejecutar EN la Intel:  bash bootstrap-intel.sh
#   o desde la dev:      make bootstrap-intel REMOTE=<host-ssh-intel>
set -euo pipefail

# SSH no interactivo trae PATH minimo (sin /usr/local/bin, donde viven brew/colima/docker en Intel).
export PATH="/usr/local/bin:$PATH"

PROFILE="${PM_COLIMA_PROFILE:-pm-data}"
CPU="${PM_VM_CPU:-6}"; MEM="${PM_VM_MEM:-16}"; DISK="${PM_VM_DISK:-60}"

echo "[bootstrap-intel] arquitectura: $(uname -m)"   # se espera x86_64

have() { command -v "$1" >/dev/null 2>&1; }

if ! have brew; then
  echo "[bootstrap-intel] ERROR: Homebrew no esta instalado. Instala desde https://brew.sh y reintenta." >&2
  exit 1
fi

for pkg in colima docker docker-compose; do
  if ! have "$pkg" && ! brew list "$pkg" >/dev/null 2>&1; then
    echo "[bootstrap-intel] instalando $pkg ..."; brew install "$pkg"
  else
    echo "[bootstrap-intel] $pkg OK"
  fi
done

# cablear el plugin de compose para 'docker compose' (v2)
mkdir -p "$HOME/.docker/cli-plugins"
if [ ! -e "$HOME/.docker/cli-plugins/docker-compose" ]; then
  CP="$(brew --prefix)/bin/docker-compose"
  [ -e "$CP" ] && ln -sf "$CP" "$HOME/.docker/cli-plugins/docker-compose" || true
fi

# arrancar la VM dedicada (en una Intel, colima usa x86_64 nativo: imagenes amd64 sin emular)
if colima status --profile "$PROFILE" >/dev/null 2>&1; then
  echo "[bootstrap-intel] colima '$PROFILE' ya corre"
else
  echo "[bootstrap-intel] arrancando colima '$PROFILE' ($CPU vCPU / $MEM GB / $DISK GB) ..."
  colima start --profile "$PROFILE" --cpu "$CPU" --memory "$MEM" --disk "$DISK"
fi

echo "[bootstrap-intel] docker: $(docker --context "colima-$PROFILE" version --format '{{.Server.Version}}' 2>/dev/null || echo 'verificar contexto')"
echo "[bootstrap-intel] LISTO. Contexto docker sugerido: colima-$PROFILE"
echo "[bootstrap-intel] Ahora desde la dev:  make run TARGET=intel REMOTE=<este-host>"
