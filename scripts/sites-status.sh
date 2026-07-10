#!/usr/bin/env bash
# Lista los sites IIS 'pm*' del guest, una linea por site: <nombre>|<estado>|<bindings>.
# Corre EN la macdata. Salida cruda: el consumidor (legacy.sh sites-status, wt-gc) la cruza con el registro
# de slots para marcar huerfanos.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # .../host-windows
ENV_FILE="$HERE/.env"
_C_WINHOST="${WINHOST:-}"                          # valor del invocador (precede a .env)
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

KEY="${GUEST_KEY:-$HOME/pm-host-windows/artifacts/ssh/id_pmwin}"
G="${_C_WINHOST:-${WINHOST:-172.16.128.129}}"
SSHG(){ ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 Administrator@"$G" "$@"; }

# El shell SSH por defecto del guest es PowerShell: el comando viaja tal cual. \$_ escapa el $_ del bash.
SSHG "Import-Module WebAdministration; Get-Website | Where-Object { \$_.Name -like 'pm*' } | ForEach-Object { \$_.Name + '|' + \$_.State + '|' + ((\$_.bindings.Collection | ForEach-Object { \$_.bindingInformation }) -join ',') }" 2>/dev/null | tr -d '\r'
