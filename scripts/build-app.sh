#!/usr/bin/env bash
# Compila la solucion legacy completa en el guest con la MSBuild de VS Build Tools (Roslyn + web targets).
# Corre EN la macdata.
set -uo pipefail
KEY="$HOME/pm-host-windows/artifacts/ssh/id_pmwin"; G="${WINHOST:-172.16.128.129}"
SSHG(){ ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25 Administrator@"$G" "$@"; }

echo "== msbuild path =="
SSHG 'Get-Content C:\buildtools.msbuildpath'

echo "== nuget restore (re-asegura) =="
SSHG 'C:\tools\nuget.exe restore C:\src\CargaPlantaPT_LN\ProgramaMaestroPT.sln -NonInteractive 2>&1 | Select-Object -Last 3'

echo "== BUILD solution (ET + DAL + BL + ProgramaMaestroPT web) =="
SSHG '$mb = (Get-Content C:\buildtools.msbuildpath).Trim(); & $mb C:\src\CargaPlantaPT_LN\ProgramaMaestroPT.sln /p:Configuration=Debug /m /nologo /clp:Summary /v:m 2>&1 | Select-Object -Last 50'
echo "== EXIT build-app =="
