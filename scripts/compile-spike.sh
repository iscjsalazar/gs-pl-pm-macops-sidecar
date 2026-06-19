#!/usr/bin/env bash
# Spike de compilacion: transfiere el legacy al guest, restaura NuGet y compila las class libs
# con la MSBuild INBOX de .NET Framework (sin VS Build Tools). Corre EN la macdata.
set -uo pipefail
KEY="$HOME/pm-host-windows/artifacts/ssh/id_pmwin"
G="${WINHOST:-172.16.128.129}"
SSHG(){ ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 Administrator@"$G" "$@"; }

cd "$HOME/pm-host-windows/artifacts/stage"
echo "== zip + scp source -> guest =="
rm -f CargaPlantaPT_LN.zip
zip -qr CargaPlantaPT_LN.zip CargaPlantaPT_LN
echo "zip: $(du -h CargaPlantaPT_LN.zip | cut -f1)"
scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null CargaPlantaPT_LN.zip Administrator@"$G":C:/src.zip

echo "== extract en guest =="
SSHG 'Remove-Item C:\src -Recurse -Force -ErrorAction SilentlyContinue; Expand-Archive -Path C:\src.zip -DestinationPath C:\src -Force; (Get-ChildItem C:\src\CargaPlantaPT_LN).Name -join ", "'

echo "== nuget.exe =="
SSHG 'if(-not(Test-Path C:\tools)){mkdir C:\tools|Out-Null}; Invoke-WebRequest https://dist.nuget.org/win-x86-commandline/latest/nuget.exe -OutFile C:\tools\nuget.exe -UseBasicParsing; "nuget bytes: " + (Get-Item C:\tools\nuget.exe).Length'

echo "== nuget restore (sln) =="
SSHG 'C:\tools\nuget.exe restore C:\src\CargaPlantaPT_LN\ProgramaMaestroPT.sln -NonInteractive 2>&1 | Select-Object -Last 10'

echo "== build BL (cascada ET+DAL+BL) con MSBuild inbox v4.0.30319 =="
SSHG '& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe C:\src\CargaPlantaPT_LN\BL\BL.csproj /p:Configuration=Debug /nologo /v:m 2>&1 | Select-Object -Last 30'
echo "== EXIT compile-spike =="
