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
_C_WINHOST="${WINHOST:-}"; _C_SLOT="${SLOT:-}"; _C_CLEAN="${CLEAN:-}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

KEY="${GUEST_KEY:-$HOME/pm-host-windows/artifacts/ssh/id_pmwin}"
G="${_C_WINHOST:-${WINHOST:-172.16.128.129}}"
SLOT="${_C_SLOT:-${SLOT:-}}"
# I5: 0 (default) = nuget restore SOLO si packages.config cambio (o falta packages/); 1 = restore incondicional.
CLEAN="${_C_CLEAN:-${CLEAN:-0}}"
SSHG(){ ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25 Administrator@"$G" "$@"; }

case "$SLOT" in
  '')       SRC_GUEST='C:\src\CargaPlantaPT_LN' ;;
  *[!0-9]*) echo "[build-app] SLOT no numerico: '$SLOT'" >&2; exit 2 ;;
  *)        SRC_GUEST="C:\\wt$SLOT\\CargaPlantaPT_LN" ;;
esac
SLN="$SRC_GUEST\\ProgramaMaestroPT.sln"

echo "== msbuild path (slot ${SLOT:-<singleton>}; fuente $SRC_GUEST) =="
SSHG 'Get-Content C:\buildtools.msbuildpath'

# I5: nuget restore condicional. Se hashea el conjunto de packages.config (SHA256, orden estable) y se compara con
# el marcador de la ultima restauracion exitosa (<solucion>\packages\.pm-restore.sha). Si coincide, packages/ existe
# y CLEAN!=1 => SKIP. El marcador vive DENTRO de packages/ a proposito: el stage incremental lo preserva (/XD
# packages) y un CLEAN (wipe de packages/) lo borra, forzando el restore. 26 paquetes -> restore completo ~sobre.
# NOTA: NO se fija $ErrorActionPreference='Stop': el 'nuget.exe ... 2>&1' emite a stderr y, bajo Stop, Windows
# PowerShell 5.1 lanzaria NativeCommandError aun con restore exitoso. El control de error es explicito por $LASTEXITCODE.
echo "== nuget restore (condicional: solo si packages.config cambio o falta packages/; CLEAN=$CLEAN) =="
SSHG "\$src='$SRC_GUEST'; \$sln='$SLN'; \$clean='$CLEAN'; \
\$pkgdir=\"\$src\\packages\"; \$marker=\"\$pkgdir\\.pm-restore.sha\"; \
\$cfgs = Get-ChildItem -Path \$src -Recurse -Filter packages.config -ErrorAction SilentlyContinue | Sort-Object FullName; \
\$hash = if (\$cfgs) { ((\$cfgs | Get-FileHash -Algorithm SHA256 | ForEach-Object { \$_.Hash }) -join '') } else { '' }; \
\$prev = if (Test-Path \$marker) { (Get-Content \$marker -Raw).Trim() } else { '' }; \
if (\$clean -ne '1' -and (Test-Path \$pkgdir) -and \$hash -ne '' -and \$hash -eq \$prev) { \
  Write-Output '[build-app] nuget restore SKIP (packages.config sin cambio)' \
} else { \
  C:\\tools\\nuget.exe restore \$sln -NonInteractive 2>&1 | Select-Object -Last 3; \
  if (\$LASTEXITCODE -eq 0) { New-Item -ItemType Directory -Force -Path \$pkgdir | Out-Null; Set-Content -Path \$marker -Value \$hash } else { Write-Error \"nuget restore fallo (rc=\$LASTEXITCODE)\"; exit 1 } \
}"

# /nr:false: sin nodos residentes de MSBuild. Los nodos sobreviven al build y se reusan entre invocaciones;
# compartidos entre arboles distintos arrastran estado del arbol anterior a los builds per-slot.
echo "== BUILD solution (ET + DAL + BL + ProgramaMaestroPT web) =="
SSHG "\$mb = (Get-Content C:\\buildtools.msbuildpath).Trim(); & \$mb '$SLN' /p:Configuration=Debug /m /nr:false /nologo /clp:Summary /v:m 2>&1 | Select-Object -Last 50"
echo "== EXIT build-app =="
