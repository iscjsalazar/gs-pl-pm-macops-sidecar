#!/usr/bin/env bash
# Contadores de memoria del guest Windows: presupuesto de RAM y evidencia de paginacion.
# Corre EN la macdata. Imprime clave=valor, una linea por metrica (MB salvo donde se indica).
#
# El presupuesto del guest lo consumen los w3wp activos (uno por app pool con trafico; el idle-timeout de
# 20 min los recicla) y el MSBuild en vuelo. 'pagesPerSec' > 0 sostenido indica que la VM esta paginando y el
# tope de frontends concurrentes se excedio.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # .../host-windows
ENV_FILE="$HERE/.env"
_C_WINHOST="${WINHOST:-}"                          # valor del invocador (precede a .env)
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

KEY="${GUEST_KEY:-$HOME/pm-host-windows/artifacts/ssh/id_pmwin}"
G="${_C_WINHOST:-${WINHOST:-172.16.128.129}}"
SSHG(){ ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 Administrator@"$G" "$@"; }

# El shell SSH por defecto del guest es PowerShell. \$ escapa el $ del bash.
SSHG "
\$os = Get-CimInstance Win32_OperatingSystem;
'memTotalMB=' + [int](\$os.TotalVisibleMemorySize/1KB);
'memFreeMB=' + [int](\$os.FreePhysicalMemory/1KB);
'memUsedMB=' + [int]((\$os.TotalVisibleMemorySize - \$os.FreePhysicalMemory)/1KB);
'commitLimitMB=' + [int](\$os.SizeStoredInPagingFiles/1KB + \$os.TotalVisibleMemorySize/1KB);
\$pg = (Get-Counter '\Memory\Pages/sec' -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue;
'pagesPerSec=' + [int]\$pg;
\$av = (Get-Counter '\Memory\Available MBytes' -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue;
'availableMB=' + [int]\$av;
\$w = Get-Process w3wp -ErrorAction SilentlyContinue;
'w3wpCount=' + (\$w | Measure-Object).Count;
if (\$w) { foreach (\$p in \$w) { 'w3wpWorkingSetMB=' + [int](\$p.WorkingSet64/1MB) } }
\$mb = Get-Process msbuild -ErrorAction SilentlyContinue;
'msbuildCount=' + (\$mb | Measure-Object).Count;
if (\$mb) { 'msbuildWorkingSetMB=' + [int]((\$mb | Measure-Object WorkingSet64 -Sum).Sum/1MB) }
" 2>/dev/null | tr -d '\r'
