#!/usr/bin/env bash
# Publica el web project legacy en IIS del guest (app pool .NET v4.0, site en SITE_PORT) y deja health.aspx.
# Corre EN la macdata; transfiere deploy-iis.ps1 al guest y lo ejecuta. Idempotente (recrea el site).
#
# Con SLOT=<N> el deploy opera el site per-slot ('pm-wt<N>'): el ps1 viaja a un path per-slot (C:/deploy-iis-wt<N>.ps1)
# para que dos sesiones concurrentes no se pisen la version del script, y el propio ps1 deriva SiteName/App/Root/Port
# del slot (evita el quoting de backslashes SSH -> PowerShell).
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # .../host-windows
ENV_FILE="$HERE/.env"
# Valores del invocador: se capturan ANTES del source del .env, que puede redefinirlos
# (precedencia invocador > .env > default).
_C_WINHOST="${WINHOST:-}"; _C_SITE_PORT="${SITE_PORT:-}"; _C_SLOT="${SLOT:-}"
_C_DBHOST="${PM_LEGACY_DBHOST:-}"; _C_ORACLE_PORT="${PM_LEGACY_ORACLE_PORT:-}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

KEY="${GUEST_KEY:-$HOME/pm-host-windows/artifacts/ssh/id_pmwin}"
G="${_C_WINHOST:-${WINHOST:-172.16.128.129}}"
SLOT="${_C_SLOT:-${SLOT:-}}"
DBHOST="${_C_DBHOST:-${PM_LEGACY_DBHOST:-172.16.128.1}}"      # IP del data tier (Oracle) vista DESDE el guest
ORACLE_PORT="${_C_ORACLE_PORT:-${PM_LEGACY_ORACLE_PORT:-1521}}"  # 1521 = singleton; 15210+N = Oracle del slot
SITE_PORT_BASE="${SITE_PORT_BASE:-8100}"
SSHG(){ ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25 Administrator@"$G" "$@"; }

case "$SLOT" in
  '')       PS_GUEST='C:/deploy-iis.ps1';        PS_GUEST_WIN='C:\deploy-iis.ps1';        SLOT_ARG='' ;;
  *[!0-9]*) echo "[deploy-app] SLOT no numerico: '$SLOT'" >&2; exit 2 ;;
  *)        PS_GUEST="C:/deploy-iis-wt$SLOT.ps1"; PS_GUEST_WIN="C:\\deploy-iis-wt$SLOT.ps1"; SLOT_ARG=" -Slot $SLOT" ;;
esac

# El puerto del site se DERIVA del slot cuando el invocador no lo fija. Sin esta derivacion, un
# 'SLOT=3 deploy-app.sh' sin SITE_PORT caeria al default 8080 y crearia el site pm-wt3 sobre el binding del
# singleton 'pm', tumbandolo. legacy.sh siempre pasa SITE_PORT; esta rama protege la invocacion directa.
SITE_PORT="${_C_SITE_PORT:-${SITE_PORT:-${SITE_PORT_48:-}}}"
if [ -z "$SITE_PORT" ]; then
  if [ -n "$SLOT" ]; then SITE_PORT=$(( SITE_PORT_BASE + SLOT )); else SITE_PORT=8080; fi
fi

PS_LOCAL="$HERE/scripts/deploy-iis.ps1"
[ -f "$PS_LOCAL" ] || { echo "[deploy-app] no existe $PS_LOCAL" >&2; exit 1; }

# --- E2E (solicitud e2e-launch-orchestration): inyeccion opcional del wiring al backend .NET 10. Los valores
# viajan en base64 para no romper el quoting a traves de SSH -> PowerShell del guest. Vacio = no se pasan
# (legacy-launch standalone: deploy-iis.ps1 solo repunta conStringOracle). ---
_b64(){ printf '%s' "${1:-}" | base64 | tr -d '\n'; }
EXTRA=""
[ -n "${PM_LEGACY_BACKEND_URL:-}" ] && EXTRA="$EXTRA -BackendBaseUrlB64 $(_b64 "$PM_LEGACY_BACKEND_URL")"
[ -n "${PM_LEGACY_SQL_PM_HOST:-}" ] && EXTRA="$EXTRA -SqlPmHostB64 $(_b64 "$PM_LEGACY_SQL_PM_HOST")"
[ -n "${PM_LEGACY_SQL_PM_DB:-}"   ] && EXTRA="$EXTRA -SqlPmDbB64 $(_b64 "$PM_LEGACY_SQL_PM_DB")"
[ -n "${PM_LEGACY_SQL_PM_USER:-}" ] && EXTRA="$EXTRA -SqlPmUserB64 $(_b64 "$PM_LEGACY_SQL_PM_USER")"
[ -n "${PM_LEGACY_SQL_PM_PASS:-}" ] && EXTRA="$EXTRA -SqlPmPassB64 $(_b64 "$PM_LEGACY_SQL_PM_PASS")"
# ConStrJobsReader (login de solo-lectura pm_reader). Vacio = deploy-iis.ps1 cae al login de la app.
[ -n "${PM_LEGACY_SQL_READER_USER:-}" ] && EXTRA="$EXTRA -SqlReaderUserB64 $(_b64 "$PM_LEGACY_SQL_READER_USER")"
[ -n "${PM_LEGACY_SQL_READER_PASS:-}" ] && EXTRA="$EXTRA -SqlReaderPassB64 $(_b64 "$PM_LEGACY_SQL_READER_PASS")"
[ -n "$EXTRA" ] && echo "[deploy-app] inyeccion E2E: backendBaseUrl=${PM_LEGACY_BACKEND_URL:-} ConStrPm=${PM_LEGACY_SQL_PM_HOST:-}/${PM_LEGACY_SQL_PM_DB:-} ConStrJobsReader user=${PM_LEGACY_SQL_READER_USER:-<app>} (passwords ocultos)"

echo "[deploy-app] copiando deploy-iis.ps1 al guest ($PS_GUEST; slot ${SLOT:-<singleton>}, site :$SITE_PORT, oracle $DBHOST:$ORACLE_PORT)"
scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$PS_LOCAL" Administrator@"$G":"$PS_GUEST"

echo "[deploy-app] ejecutando deploy en el guest (vdir ProgramaMaestroLN + conn string data tier)"
SSHG "powershell -NoProfile -ExecutionPolicy Bypass -File $PS_GUEST_WIN$SLOT_ARG -Port $SITE_PORT -OracleHost $DBHOST -OraclePort $ORACLE_PORT$EXTRA"

echo "[deploy-app] verificando health en el guest"
SSHG "powershell -NoProfile -Command \"(Invoke-WebRequest -UseBasicParsing http://localhost:$SITE_PORT/health.aspx).StatusCode\""
echo "[deploy-app] EXIT"
