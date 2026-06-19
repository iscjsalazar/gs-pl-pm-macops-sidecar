#!/usr/bin/env bash
# Driver del lanzamiento del legado CargaPlantaPT_LN. La logica vive aqui; el Makefile es el catalogo de verbos.
# Corre en la maquina de desarrollo (M1) y orquesta por SSH: data tier (intel) + VM Windows + build/deploy.
# Idempotente: verifica antes de levantar y NO relanza lo que ya esta arriba (salvo PM_LEGACY_FORCE=1).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"                         # .../gs-pl-pm-macops-sidecar (pm.sh/Makefile co-ubicados)

# --- Config (defaults; el Makefile traduce vars cortas a estas PM_LEGACY_*) ---
MACDATA="${PM_LEGACY_MACDATA:-macdata}"                       # alias SSH de la mac Intel
WINHOST="${PM_LEGACY_WINHOST:-172.16.128.129}"               # IP del guest Windows (NAT interna de macdata)
SITE_PORT="${PM_LEGACY_SITE_PORT:-8080}"                     # puerto IIS del legado en el guest
TUNNEL_PORT="${PM_LEGACY_TUNNEL_PORT:-18080}"                # puerto local (M1) del tunel SSH -> guest:SITE_PORT
SQL_PORT="${PM_LEGACY_SQL_PORT:-1433}"                       # SQL del data tier en macdata
ORACLE_PORT="${PM_LEGACY_ORACLE_PORT:-1521}"                 # Oracle del data tier en macdata
PROFILE="${PM_LEGACY_PROFILE:-full}"                         # sql | full (el legado necesita Oracle ControlPiso)
DATATIER="${PM_LEGACY_DATATIER:-1}"                          # 0 = no gestionar el data tier
FORCE="${PM_LEGACY_FORCE:-0}"                                # 1 = rebuild/redeploy aunque ya este arriba
HW_REMOTE="${PM_LEGACY_HW_REMOTE:-~/pm-host-windows}"        # checkout de host-windows EN macdata
STAGE_REMOTE="${PM_LEGACY_STAGE_REMOTE:-~/pm-host-windows/artifacts/stage}"  # stage de fuente EN macdata
SRC_LOCAL="${PM_LEGACY_SRC_LOCAL:-$HERE/../pl-pm-legacy}"     # fuente del legado EN M1 (repo aplanado: la solucion esta en la raiz)

APP_PATH="health.aspx"                                        # ruta de humo que publica deploy-iis.ps1 (raiz del site)

log(){ printf '== %s\n' "$*"; }
warn(){ printf 'AVISO: %s\n' "$*" >&2; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ssh_md(){ ssh "$MACDATA" "$@"; }

# Health del legado consultado DESDE macdata hacia el guest (evita depender del tunel).
guest_health(){ ssh_md "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://$WINHOST:$SITE_PORT/$APP_PATH" 2>/dev/null; }

# Empuja los scripts de host-windows (M1) al checkout en macdata, para que los verbos
# remotos corran la version actual. No toca artifacts/ ni .env (propios de macdata).
_SYNCED=0
sync_remote(){
  [ "$_SYNCED" = "1" ] && return 0
  log "sincronizando host-windows (scripts/packer) -> $MACDATA:$HW_REMOTE"
  ssh_md "mkdir -p $HW_REMOTE" || true
  rsync -a -e ssh "$HERE/scripts" "$HERE/packer" "$MACDATA:$HW_REMOTE/" \
    || die "fallo el sync de host-windows hacia $MACDATA"
  _SYNCED=1
}

# --- Verbos ---

data_up(){
  if [ "$DATATIER" = "0" ]; then log "data tier: omitido (DATATIER=0)"; return 0; fi
  log "data tier (intel): verificando puertos en $MACDATA (SQL:$SQL_PORT Oracle:$ORACLE_PORT)"
  if ssh_md "nc -z -G 3 127.0.0.1 $SQL_PORT && nc -z -G 3 127.0.0.1 $ORACLE_PORT" 2>/dev/null; then
    log "data tier ya arriba -> no se relanza"
    return 0
  fi
  log "data tier abajo -> levantando via pm.sh (TARGET=intel PROFILE=$PROFILE)"
  # El data tier del legado (Oracle ControlPiso + Infor LN con su seed) lo provisiona la solicitud
  # db-setup-containers; aqui solo se asegura que los contenedores/puertos esten arriba en intel.
  make -C "$HERE" pm-run TARGET=intel REMOTE="$MACDATA" SQLHOST="$MACDATA" PROFILE="$PROFILE" \
    || die "fallo al levantar el data tier en intel"
}

vm_up(){
  sync_remote
  log "VM Windows: asegurando (idempotente) en $MACDATA"
  ssh_md "WINHOST=$WINHOST bash $HW_REMOTE/scripts/vm-up.sh" || die "no se pudo asegurar la VM"
}

stage_build(){
  sync_remote
  if [ "$FORCE" != "1" ] && [ "$(guest_health)" = "200" ]; then
    log "app ya desplegada (health 200) -> se omite build (PM_LEGACY_FORCE=1 para forzar)"
    return 0
  fi
  [ -d "$SRC_LOCAL" ] || die "fuente del legado no encontrada: $SRC_LOCAL (ver g2: pl-pm-legacy)"
  log "sincronizando fuente M1 -> macdata stage"
  ssh_md "mkdir -p $STAGE_REMOTE" || true
  rsync -a --delete \
    -e ssh \
    --exclude='.git/' \
    "$SRC_LOCAL/" "$MACDATA:$STAGE_REMOTE/CargaPlantaPT_LN/" || die "fallo el rsync de la fuente"
  log "staging fuente macdata -> guest + build (VS Build Tools)"
  ssh_md "WINHOST=$WINHOST bash $HW_REMOTE/scripts/stage-app.sh" || die "fallo el staging al guest"
  ssh_md "WINHOST=$WINHOST bash $HW_REMOTE/scripts/build-app.sh" || die "fallo el build en el guest"
}

deploy(){
  sync_remote
  if [ "$FORCE" != "1" ] && [ "$(guest_health)" = "200" ]; then
    log "app ya sirviendo (health 200) -> se omite deploy (PM_LEGACY_FORCE=1 para forzar)"
    return 0
  fi
  log "deploy a IIS del guest (site :$SITE_PORT)"
  ssh_md "WINHOST=$WINHOST SITE_PORT=$SITE_PORT bash $HW_REMOTE/scripts/deploy-app.sh" || die "fallo el deploy"
}

diag(){
  sync_remote
  log "habilitando log de errores detallado (Health Monitoring -> Event Log) + reciclando pool en $MACDATA"
  ssh_md "WINHOST=$WINHOST bash $HW_REMOTE/scripts/diag.sh" || die "fallo al habilitar el log de errores"
}

diag_logs(){
  sync_remote
  log "errores ASP.NET del Event Log del guest (detalle completo; var MAX=${MAX:-40})"
  ssh_md "WINHOST=$WINHOST MAX=${MAX:-40} bash $HW_REMOTE/scripts/diag-logs.sh" || die "fallo al leer los logs"
}

tunnel_up(){
  if pgrep -f "$TUNNEL_PORT:$WINHOST:$SITE_PORT" >/dev/null 2>&1; then
    log "tunel ya activo (localhost:$TUNNEL_PORT) -> no se relanza"
    return 0
  fi
  log "abriendo tunel SSH: localhost:$TUNNEL_PORT -> $WINHOST:$SITE_PORT (via $MACDATA)"
  ssh -f -N -L "$TUNNEL_PORT:$WINHOST:$SITE_PORT" "$MACDATA" || die "no se pudo abrir el tunel"
}

tunnel_down(){
  if pgrep -f "$TUNNEL_PORT:$WINHOST:$SITE_PORT" >/dev/null 2>&1; then
    pkill -f "$TUNNEL_PORT:$WINHOST:$SITE_PORT" && log "tunel cerrado (localhost:$TUNNEL_PORT)"
  else
    log "no hay tunel activo"
  fi
}

print_url(){
  local code; code="$(guest_health)"
  printf '\n'
  printf '  +----------------------------------------------------------------+\n'
  printf '  |  Legado CargaPlantaPT_LN -- acceso                             |\n'
  printf '  +----------------------------------------------------------------+\n'
  printf '   App (humo):   http://localhost:%s/health.aspx\n' "$TUNNEL_PORT"
  printf '   App (login):  http://localhost:%s/ProgramaMaestroLN/Login.aspx\n' "$TUNNEL_PORT"
  printf '   Tunel:        localhost:%s  ->  %s:%s  (via %s)\n' "$TUNNEL_PORT" "$WINHOST" "$SITE_PORT" "$MACDATA"
  printf '   Data tier:    %s  SQL:%s  Oracle:%s\n' "$MACDATA" "$SQL_PORT" "$ORACLE_PORT"
  printf '   Health guest: HTTP %s\n' "${code:-sin respuesta}"
  printf '   Parar tunel:  make -C gs-pl-pm-macops-sidecar legacy-down\n'
  printf '\n'
  [ "$code" = "200" ] || warn "health != 200: revisar deploy/conn strings (rutas /ProgramaMaestroLN/ requieren vdir; ver runbook H-10)."
}

status(){
  log "estado del lanzamiento"
  printf '   data tier (%s): ' "$MACDATA"
  ssh_md "nc -z -G 3 127.0.0.1 $SQL_PORT && nc -z -G 3 127.0.0.1 $ORACLE_PORT" 2>/dev/null \
    && echo "arriba (SQL:$SQL_PORT Oracle:$ORACLE_PORT)" || echo "abajo"
  printf '   VM/guest (%s): ' "$WINHOST"
  ssh_md "nc -z -G 3 $WINHOST 22" 2>/dev/null && echo "SSH arriba" || echo "sin SSH"
  printf '   app health: HTTP %s\n' "$(guest_health)"
  printf '   tunel local:%s: ' "$TUNNEL_PORT"
  pgrep -f "$TUNNEL_PORT:$WINHOST:$SITE_PORT" >/dev/null 2>&1 && echo "activo" || echo "inactivo"
}

launch(){
  data_up
  vm_up
  stage_build
  deploy
  tunnel_up
  print_url
}

usage(){
  cat <<EOF
legacy.sh <verbo>  (orquesta el lanzamiento del legado; idempotente)
  launch        data tier (intel) + VM + build + deploy + tunel + URL (todo, inteligente)
  data-up       asegura el data tier en intel (omite si ya esta arriba)
  vm-up         asegura la VM Windows (omite si ya corre)
  build         sincroniza fuente + build en el guest (omite si health 200, salvo FORCE)
  deploy        publica en IIS del guest (omite si health 200, salvo FORCE)
  diag          habilita log de errores DETALLADO (Health Monitoring -> Event Log) + recicla el pool
  diag-logs     vuelca los errores ASP.NET del Event Log del guest (var MAX=40)
  tunnel        abre el tunel SSH M1 -> guest (omite si ya activo)
  status        reporta estado de cada pieza
  url           imprime la URL/puertos de acceso
  down          cierra el tunel SSH
Variables (PM_LEGACY_*): MACDATA WINHOST SITE_PORT TUNNEL_PORT SQL_PORT ORACLE_PORT PROFILE DATATIER FORCE
EOF
}

case "${1:-}" in
  launch)   launch ;;
  data-up)  data_up ;;
  vm-up)    vm_up ;;
  build)    stage_build ;;
  deploy)   deploy ;;
  diag)     diag ;;
  diag-logs) diag_logs ;;
  tunnel)   tunnel_up ;;
  status)   status ;;
  url)      print_url ;;
  down)     tunnel_down ;;
  ""|help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
