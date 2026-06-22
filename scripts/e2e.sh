#!/usr/bin/env bash
# Orquestador E2E local del camino Programa Maestro (solicitud e2e-launch-orchestration).
# Compone los targets de tier ya existentes (wt-up, legacy-launch, e2e-net-check) y agrega el last-mile:
# inyeccion del wiring de aplicacion al backend .NET 10 en el deploy del legado, activacion del feature flag
# y un smoke funcional legacy-driven (sin navegador: el WCF generar_programa es REST sin auth).
#
# Ruta: wt (backend por slot sobre el SQL compartido de nvoslabs). Ese SQL solo escucha en el loopback de
# macdata, asi que e2e-up levanta un PUENTE (socat) para que el guest Windows lo alcance por la pasarela NAT.
# La M1 es SOLO el orquestador: todo el runtime (backend wt, VM del legado, puente, data tier) vive en macdata,
# manejado por SSH. El disparo del smoke va macdata -> guest DIRECTO; el tunel del legado (localhost:18080) es
# solo para acceso humano a la UI, no lo usa el smoke. Idempotente.
#
#   make e2e-up    WT=<folder> LEGACYSRC=<path>   # data tier + backend(wt) + puente SQL + legacy(+inyeccion) + flag ON + smoke
#   make e2e-smoke WT=<folder>                    # solo el smoke funcional (asume e2e-up ya dejo todo arriba)
#   make e2e-down  WT=<folder>                    # baja tunel + API del slot + puente SQL (singletons intactos)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/worktrees.sh"
set +e   # common.sh fija 'set -e'; el driver reporta y decide, no aborta a mitad.
load_env
# El backend wt, el SQL compartido y el bus viven en macdata; fija el contexto docker remoto (colima-nlc3runner).
wt_require_intel || { printf 'ERROR [e2e]: requiere PM_TARGET=intel y REMOTE=macdata\n' >&2; exit 2; }

VERB="${1:-up}"

# --- inputs (el Makefile traduce las vars cortas a estas) ---
WT="${WT:-}"                                    # worktree de pl-programa-maestro (PL.PM.sln) -> slot del backend
LEGACY_SRC="${PM_E2E_LEGACY_SRC:-}"             # fuente del legado en develop (ProgramaMaestroPT.sln + el gateway)
PLANTA="${PM_E2E_PLANTA:-RES}"                  # etiqueta de planta del legado (RES -> RT en el backend)
LINEA="${PM_E2E_LINEA:-}"                       # lineaFab del disparo (solo lo usa el camino Oracle/OFF)
ANOF="${PM_E2E_ANOF:-0}"                        # anio fiscal del disparo (idem)
SEMF="${PM_E2E_SEMF:-0}"                        # semana fiscal del disparo (idem)
FLAG_FINAL="${PM_E2E_FLAG_FINAL:-on}"          # estado del flag al terminar e2e-up (on|off)
TUNNEL="${PM_E2E_TUNNEL:-18080}"               # tunel del legado para acceso humano a la UI (no lo usa el smoke)
SITEPORT="${PM_E2E_SITE_PORT:-8080}"           # puerto IIS del legado en el guest (el smoke dispara aqui via macdata)
FORCE="${PM_E2E_FORCE:-0}"                      # 1 = re-deploy del legado aunque health 200 (re-inyecta wiring)
SQL_PM_HOST_OVERRIDE="${PM_E2E_SQL_PM_HOST:-}"  # override del host,puerto del SQL del flag (vacio = puente)
BRIDGE_PORT="${PM_E2E_BRIDGE_PORT:-60211}"      # puerto host (bridge) del puente -> shared SQL
BRIDGE_NAME="pm-e2e-sqlbridge"
BRIDGE_IMAGE="${PM_E2E_BRIDGE_IMAGE:-alpine/socat}"

VDIR="ProgramaMaestroLN"
SVC_PATH="$VDIR/Services/WCFobtenerDatos.svc/generar_programa"

elog(){ printf '== [e2e] %s\n' "$*"; }
ewarn(){ printf 'AVISO [e2e]: %s\n' "$*" >&2; }
edie(){ printf 'ERROR [e2e]: %s\n' "$*" >&2; exit 1; }

# --- resolucion de slot / backend ---

# Resuelve el slot del backend (asignado por wt-up) y deriva BD/offset del slot.
e2e_slot(){
  [ -n "$WT" ] || edie "falta WT=<folder> (worktree de pl-programa-maestro con PL.PM.sln; la ruta wt levanta el backend por slot)"
  E2E_SLOT="$(wt_slot_lookup "$WT")"
  [ -n "$E2E_SLOT" ] || edie "el worktree '$WT' no tiene slot asignado; corre 'make e2e-up' (invoca wt-up) antes de e2e-smoke/e2e-down"
  wt_derive "$E2E_SLOT"     # PM_PLANNING_DB=pm_planning_wt<N>, PM_PORT_OFFSET, PM_PROFILE=full, etc.
}

# Puerto host REALMENTE publicado por el contenedor de la API del slot (fuente de verdad; evita asumir el
# offset de PM_API_PORT, que load_env fija una sola vez). Fallback: PM_API_PORT.
e2e_api_port(){
  local ctx p; ctx="$(remote_docker_ctx)"
  p="$(on_intel "docker $ctx port 'pm-wt${E2E_SLOT}-api' 8080/tcp 2>/dev/null" 2>/dev/null | head -1 | sed 's/.*://' | tr -d '\r')"
  printf '%s' "${p:-$PM_API_PORT}"
}

# --- puente SQL (socat) para que el guest alcance el SQL compartido (loopback de macdata) ---

# Un contenedor socat unido a la red del SQL compartido publica 0.0.0.0:BRIDGE_PORT -> sqlserver:1433, asi el
# guest lo ve por la pasarela NAT (172.16.128.1:BRIDGE_PORT). Idempotente.
e2e_bridge_up(){
  local ctx; ctx="$(remote_docker_ctx)"
  if on_intel "[ \"\$(docker $ctx inspect -f '{{.State.Running}}' '$BRIDGE_NAME' 2>/dev/null)\" = true ]" 2>/dev/null; then
    elog "puente SQL ya arriba ($BRIDGE_NAME en :$BRIDGE_PORT)"; return 0
  fi
  on_intel "docker $ctx rm -f '$BRIDGE_NAME' >/dev/null 2>&1; true"
  elog "puente SQL: asegurando imagen $BRIDGE_IMAGE ..."
  on_intel "docker $ctx image inspect '$BRIDGE_IMAGE' >/dev/null 2>&1 || docker $ctx pull '$BRIDGE_IMAGE'" \
    || edie "no se pudo obtener la imagen del puente ($BRIDGE_IMAGE); macdata sin internet? fija PM_E2E_BRIDGE_IMAGE a una imagen socat presente"
  elog "puente SQL: $BRIDGE_NAME (red $PM_SHARED_SQL_NETWORK; publica $BRIDGE_PORT -> $PM_SHARED_SQL_HOST:$PM_SHARED_SQL_PORT) ..."
  on_intel "docker $ctx run -d --name '$BRIDGE_NAME' --network '$PM_SHARED_SQL_NETWORK' -p '$BRIDGE_PORT:1433' --restart unless-stopped '$BRIDGE_IMAGE' TCP-LISTEN:1433,fork,reuseaddr TCP:$PM_SHARED_SQL_HOST:$PM_SHARED_SQL_PORT >/dev/null" \
    || edie "fallo al levantar el puente SQL ($BRIDGE_NAME)"
}
e2e_bridge_down(){
  local ctx; ctx="$(remote_docker_ctx)"
  on_intel "docker $ctx rm -f '$BRIDGE_NAME' >/dev/null 2>&1; true" && elog "puente SQL bajado ($BRIDGE_NAME)"
}

# Verifica que el guest alcance el SQL del flag. Falla rapido: sin esto el legado cae a OFF silencioso (atrapa
# la excepcion del flag-read y usa Oracle), y el caso ON del smoke nunca pasaria.
e2e_check_guest_sql(){
  local host="${SQL_PM_HOST%%,*}" port="${SQL_PM_HOST##*,}" ok
  ok="$(ssh -o ConnectTimeout=10 "$PM_REMOTE_SSH" \
    "ssh -i $PM_GUEST_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12 Administrator@$PM_GUEST_WINHOST \"powershell -NoProfile -Command '(Test-NetConnection -ComputerName $host -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded'\"" 2>/dev/null | tr -d ' \r\n')"
  case "$ok" in
    *[Tt]rue*) elog "guest -> SQL del flag ($host:$port) OK" ;;
    *) edie "el guest NO alcanza el SQL del flag ($host:$port): el legado caeria a OFF silencioso. Revisa el puente ($BRIDGE_NAME) y el firewall de macdata sobre :$port" ;;
  esac
}

# --- feature flag y ordenes (contra el SQL compartido, BD del slot) ---

# Asegura el esquema del feature flag (FeatureManagement) en la BD del backend. PUENTE TEMPORAL: el seed de
# wt-up y el arranque de la API no aplican la migracion InitialFeatureManagement (PR 1762 feat(pm): feature
# flags store), asi que la tabla/vista del flag faltan en pm_planning_wt<N> y el legado leeria OFF. Esto refleja
# esa migracion (idempotente; solo crea lo ausente). Follow-up (scope pm): incluir FeatureManagement en el seed
# del backend o aplicar migraciones EF en wt-up; cuando eso ocurra, esta funcion queda como no-op.
e2e_ensure_flag_schema(){
  local pw; pw="$(wt_shared_sql_password)" || { ewarn "sin SA del SQL compartido: no se asegura el esquema del flag"; return 1; }
  local sql="SET NOCOUNT ON; USE [$PM_PLANNING_DB];
IF SCHEMA_ID(N'FeatureManagement') IS NULL EXEC('CREATE SCHEMA [FeatureManagement]');
IF OBJECT_ID(N'FeatureManagement.FeatureFlags') IS NULL CREATE TABLE [FeatureManagement].[FeatureFlags]([Key] nvarchar(128) NOT NULL,[Plant] nvarchar(16) NOT NULL,[IsEnabled] bit NOT NULL,[Description] nvarchar(512) NULL,[UpdatedAt] datetime2 NOT NULL,CONSTRAINT [PK_FeatureFlags] PRIMARY KEY ([Key],[Plant]));
IF OBJECT_ID(N'FeatureManagement.vwFeatureFlags') IS NULL EXEC('CREATE VIEW [FeatureManagement].[vwFeatureFlags] AS SELECT [Key],[Plant],[IsEnabled],[Description],[UpdatedAt] FROM [FeatureManagement].[FeatureFlags]');
IF NOT EXISTS (SELECT 1 FROM [FeatureManagement].[FeatureFlags] WHERE [Key]='carga-backend' AND [Plant]='$PLANTA') INSERT INTO [FeatureManagement].[FeatureFlags]([Key],[Plant],[IsEnabled],[Description],[UpdatedAt]) VALUES (N'carga-backend',N'$PLANTA',0,N'Deriva la carga del Programa Maestro al backend .NET 10 (planta RES/RT) en vez del SP Oracle PGE950RT.',SYSUTCDATETIME());"
  if wt_shared_exec "$pw" "$sql" >/dev/null 2>&1; then
    elog "esquema del feature flag asegurado en $PM_PLANNING_DB (puente temporal; ver follow-up del seed)"
  else
    ewarn "no se pudo asegurar el esquema del flag en $PM_PLANNING_DB"
  fi
}

e2e_set_flag(){  # uso: e2e_set_flag <0|1>
  local v="$1" pw; pw="$(wt_shared_sql_password)" || { ewarn "sin SA del SQL compartido: no se fijo el flag"; return 1; }
  local sql="SET NOCOUNT ON; USE [$PM_PLANNING_DB]; UPDATE FeatureManagement.FeatureFlags SET IsEnabled=$v, UpdatedAt=SYSUTCDATETIME() WHERE [Key]='carga-backend' AND Plant='$PLANTA';"
  if wt_shared_exec "$pw" "$sql" >/dev/null 2>&1; then
    elog "feature flag carga-backend/$PLANTA -> IsEnabled=$v (BD $PM_PLANNING_DB)"
  else
    ewarn "no se pudo fijar el flag (IsEnabled=$v) en $PM_PLANNING_DB (¿migraciones del backend aplicadas?)"
  fi
}

# Conteo de ordenes en la BD del backend. El backend almacena la planta BASE (BasePlantCode mapea RT->RES),
# no la etiqueta RT, asi que el conteo filtra Plant='RES'. -1 ante error de consulta.
e2e_orders_count(){
  local pw n; pw="$(wt_shared_sql_password)" || { printf '%s' "-1"; return; }
  n="$(wt_shared_scalar "$pw" "SET NOCOUNT ON; SELECT COUNT(*) FROM [$PM_PLANNING_DB].Demand.Orders WHERE Plant='RES';")"
  case "$n" in ''|*[!0-9]*) printf '%s' "-1" ;; *) printf '%s' "$n" ;; esac
}

# --- smoke funcional ---

# Dispara generar_programa en el legado DESDE macdata hacia el guest (172.16.128.129:SITEPORT), sin tunel M1:
# todo el runtime vive en macdata. Espejo de guest_health. Imprime "<body>\n<http_code>".
e2e_trigger(){
  local url="http://${PM_GUEST_WINHOST}:${SITEPORT}/$SVC_PATH" body
  body="$(printf '{"planta":"%s","lineaFab":"%s","anof":%s,"semf":%s}' "$PLANTA" "$LINEA" "${ANOF:-0}" "${SEMF:-0}")"
  ssh -o ConnectTimeout=12 "$PM_REMOTE_SSH" "curl -s -m 120 -w '\n%{http_code}' -H 'Content-Type: application/json' -X POST --data '$(wt_esc "$body")' '$url'" 2>/dev/null
}

# Extrae un campo de generar_programaResult del JSON de respuesta WCF (python3 si existe; fallback grep).
e2e_json_field(){  # uso: e2e_json_field <json> <campo>
  local json="$1" field="$2"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c "import sys,json
try:
  d=json.load(sys.stdin); r=d.get('generar_programaResult',d) if isinstance(d,dict) else {}
  v=r.get('$field','') if isinstance(r,dict) else ''
  sys.stdout.write('' if v is None else str(v))
except Exception:
  pass" 2>/dev/null
  else
    printf '%s' "$json" | sed -n "s/.*\"$field\":\"\\([^\"]*\\)\".*/\\1/p" | head -1
  fi
}

e2e_estatus_ok(){ [ "$1" = "1" ] || [ "$1" = "EXITO" ]; }

e2e_params_warn(){
  if [ -z "$LINEA" ] || [ "${ANOF:-0}" = "0" ] || [ "${SEMF:-0}" = "0" ]; then
    ewarn "disparo con params por defecto (lineaFab='$LINEA' anof=$ANOF semf=$SEMF): el caso ON es robusto (el gateway solo usa la planta), pero el caso OFF (Oracle SP) puede no retornar EXITO sin lineaFab/anof/semf reales. Fija PM_E2E_LINEA/ANOF/SEMF."
  fi
}

cmd_smoke(){
  e2e_slot
  e2e_ensure_flag_schema
  e2e_params_warn
  local pass=0 fail=0 before after resp code estatus mtec

  elog "smoke ON: flag carga-backend/$PLANTA = ON; disparo legacy -> debe alcanzar el backend"
  e2e_set_flag 1
  before="$(e2e_orders_count)"
  resp="$(e2e_trigger)"; code="${resp##*$'\n'}"; resp="${resp%$'\n'*}"
  estatus="$(e2e_json_field "$resp" Estatus)"; mtec="$(e2e_json_field "$resp" MensajeTecnico)"
  after="$(e2e_orders_count)"
  elog "  HTTP=$code Estatus=$estatus orders(RT) ${before}->${after} MensajeTecnico=$([ -n "$mtec" ] && echo 'presente(backend)' || echo 'vacio')"
  if [ "$code" = "200" ] && e2e_estatus_ok "$estatus" && [ -n "$mtec" ]; then
    elog "  [PASS] ON: el legado alcanzo el backend (MensajeTecnico = body del backend)"
    if [ "${after:-0}" -gt "${before:-0}" ] 2>/dev/null; then elog "  [info] ordenes RT creadas: $(( after - before ))"
    else ewarn "  ON alcanzo el backend pero sin delta de ordenes (¿sin backlog para lineaFab/anof/semf? es dato, no wiring)"; fi
    pass=$((pass+1))
  else
    ewarn "  [FAIL] ON: no se confirmo el camino backend. Revisa el puente SQL (flag-read), backendBaseUrl y la salud de la API."
    fail=$((fail+1))
  fi

  elog "smoke OFF: flag = OFF; disparo legacy -> fallback Oracle (PGE950RT), backend intacto"
  e2e_set_flag 0
  before="$(e2e_orders_count)"
  resp="$(e2e_trigger)"; code="${resp##*$'\n'}"; resp="${resp%$'\n'*}"
  estatus="$(e2e_json_field "$resp" Estatus)"; mtec="$(e2e_json_field "$resp" MensajeTecnico)"
  after="$(e2e_orders_count)"
  elog "  HTTP=$code Estatus=$estatus orders(RT) ${before}->${after} MensajeTecnico=$([ -n "$mtec" ] && echo presente || echo vacio)"
  # Señal robusta de "tocó el backend" para OFF = se crearon ordenes (delta>0). MensajeTecnico NO sirve aqui:
  # el error del SP Oracle (params/datos) tambien lo llena, sin que el backend se haya invocado.
  local touched=0; [ "${after:-0}" -gt "${before:-0}" ] 2>/dev/null && touched=1
  if [ "$touched" = "1" ]; then
    ewarn "  [FAIL] OFF: el backend fue invocado con el flag OFF (delta de ordenes > 0): el legado no cayo al fallback."
    fail=$((fail+1))
  elif [ "$code" = "200" ] && e2e_estatus_ok "$estatus"; then
    elog "  [PASS] OFF: fallback Oracle sin tocar el backend (Estatus EXITO, sin delta de ordenes)"
    pass=$((pass+1))
  else
    ewarn "  [WARN] OFF: el backend NO fue invocado (correcto, sin delta de ordenes), pero el SP Oracle no retorno EXITO (HTTP=$code Estatus=$estatus). Suele ser lineaFab/anof/semf invalidos (dato), no wiring."
  fi

  # Deja el flag en el estado final deseado (cutover ON por defecto).
  case "$FLAG_FINAL" in on|1|ON) e2e_set_flag 1 ;; off|0|OFF) e2e_set_flag 0 ;; esac
  echo ""
  elog "smoke E2E: $pass PASS / $fail FAIL"
  [ "$fail" -eq 0 ]
}

# --- verbos ---

cmd_up(){
  [ -n "$WT" ] || edie "falta WT=<folder> (worktree de pl-programa-maestro, ruta wt)"
  [ -n "$LEGACY_SRC" ] || edie "falta LEGACYSRC=<path> (fuente del legado en develop: ProgramaMaestroPT.sln + BL/CargaBackendGateway.cs)"
  [ -f "$LEGACY_SRC/ProgramaMaestroPT.sln" ] || edie "LEGACYSRC '$LEGACY_SRC' no es la solucion legado (falta ProgramaMaestroPT.sln)"
  # Guard: la fuente del legado debe traer el wiring de Fase 1 (1903). El main LOCAL del legado NO lo tiene.
  [ -f "$LEGACY_SRC/BL/CargaBackendGateway.cs" ] || edie "LEGACYSRC '$LEGACY_SRC' no trae el gateway de Fase 1 (BL/CargaBackendGateway.cs): apunta a un checkout en develop, no al main local"

  elog "[1/7] backend por slot (wt-up WT=$WT) ..."
  make -C "$BASE_DIR" wt-up WT="$WT" || edie "fallo wt-up"
  e2e_slot
  elog "      slot $E2E_SLOT -> BD $PM_PLANNING_DB"

  elog "[2/7] puente SQL (el shared SQL solo escucha en loopback de macdata) ..."
  if [ -n "$SQL_PM_HOST_OVERRIDE" ]; then
    SQL_PM_HOST="$SQL_PM_HOST_OVERRIDE"; elog "      host SQL por override: $SQL_PM_HOST (sin puente)"
  else
    e2e_bridge_up
    SQL_PM_HOST="${PM_GUEST_GATEWAY},${BRIDGE_PORT}"
  fi

  local api_port pw
  api_port="$(e2e_api_port)"
  pw="$(wt_shared_sql_password)" || edie "no se obtuvo el SA del SQL compartido"
  BACKEND_URL="http://${PM_GUEST_GATEWAY}:${api_port}"

  elog "[3/7] legacy-launch + inyeccion (backendBaseUrl=$BACKEND_URL; ConStrPm=$SQL_PM_HOST/$PM_PLANNING_DB) ..."
  PM_LEGACY_BACKEND_URL="$BACKEND_URL" \
  PM_LEGACY_SQL_PM_HOST="$SQL_PM_HOST" \
  PM_LEGACY_SQL_PM_DB="$PM_PLANNING_DB" \
  PM_LEGACY_SQL_PM_USER="sa" \
  PM_LEGACY_SQL_PM_PASS="$pw" \
  make -C "$BASE_DIR" legacy-launch SOLUTION="$LEGACY_SRC" TUNNEL="$TUNNEL" FORCE="$FORCE" \
    || edie "fallo legacy-launch"

  elog "[4/7] validando guest -> SQL del flag (fail-fast del puente) ..."
  e2e_check_guest_sql

  elog "[5/7] activando feature flag carga-backend/$PLANTA = ON ..."
  e2e_ensure_flag_schema
  e2e_set_flag 1

  elog "[6/7] precondicion de red (e2e-net-check) ..."
  PM_API_PORT="$api_port" "$BASE_DIR/scripts/e2e-net-check.sh" || ewarn "net-check con FAIL (continuo; revisa arriba)"

  elog "[7/7] smoke E2E funcional (legacy-driven) ..."
  cmd_smoke; local smoke_rc=$?

  case "$FLAG_FINAL" in on|1|ON) e2e_set_flag 1 ;; off|0|OFF) e2e_set_flag 0 ;; esac
  e2e_summary "$api_port"
  return $smoke_rc
}

cmd_down(){
  elog "bajando E2E ..."
  make -C "$BASE_DIR" legacy-down TUNNEL="$TUNNEL" >/dev/null 2>&1 && elog "tunel del legado cerrado" || ewarn "no se cerro el tunel"
  if [ -n "$WT" ]; then make -C "$BASE_DIR" wt-down WT="$WT" || ewarn "wt-down con aviso"
  else ewarn "sin WT=<folder>: no se baja la API del slot (pasa WT para bajarla)"; fi
  e2e_bridge_down
  elog "E2E abajo (data tier, SQL compartido y bus singletons intactos)"
}

e2e_summary(){  # uso: e2e_summary <api_port>
  local api_port="$1"
  printf '\n'
  printf '  +----------------------------------------------------------------+\n'
  printf '  |  E2E Programa Maestro -- arriba                                |\n'
  printf '  +----------------------------------------------------------------+\n'
  printf '   Backend (slot %s):   http://%s:%s   (BD %s)\n' "$E2E_SLOT" "$PM_GUEST_GATEWAY" "$api_port" "$PM_PLANNING_DB"
  printf '   SQL del flag:        %s  (puente %s)\n' "$SQL_PM_HOST" "$BRIDGE_NAME"
  printf '   Legacy (login):      http://localhost:%s/%s/Login.aspx\n' "$TUNNEL" "$VDIR"
  printf '   Feature flag:        carga-backend/%s = %s\n' "$PLANTA" "$FLAG_FINAL"
  printf '   Smoke / cierre:      make e2e-smoke WT=%s   |   make e2e-down WT=%s\n' "$WT" "$WT"
  printf '\n'
}

case "$VERB" in
  up)    cmd_up ;;
  smoke) cmd_smoke ;;
  down)  cmd_down ;;
  *) echo "uso: $0 {up|smoke|down}  (WT=<folder> LEGACYSRC=<path>)"; exit 2 ;;
esac
