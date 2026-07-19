#!/usr/bin/env bash
# Corre EN macdata. Recrea el contenedor de la API del slot preservando su env/redes/puerto y agregando las
# vars que habilitan los tools dev de carga (Tools:CatalogLoad + Tools:IntakeLoad) con su allowlist = el propio
# slot (destino DEV). NO toca wt_up_api ni ningun otro slot: solo recrea ESTE contenedor con env extra. Se usa
# desde goldenslice/up.sh (make goldenslice-up) para poder disparar catalog-load/intake-load contra el golden.
set -eo pipefail
C="${1:?falta nombre del contenedor API (pm-wt<N>-api)}"
PLANNING_DB="${2:?falta la BD planning del slot (pm_planning_wt<N>)}"

command -v jq >/dev/null || { echo "jq no disponible en macdata"; exit 2; }
docker inspect "$C" >/dev/null 2>&1 || { echo "contenedor $C no existe"; exit 2; }

IMG="$(docker inspect -f '{{.Config.Image}}' "$C")"
HOSTPORT="$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$C" | jq -r '."8080/tcp"[0].HostPort')"
NETS=(); while IFS= read -r l; do NETS+=("$l"); done < <(docker inspect -f '{{json .NetworkSettings.Networks}}' "$C" | jq -r 'keys[]')
# env viejo -> array, quitando cualquier Tools__CatalogLoad__*/Tools__IntakeLoad__* previo (idempotente)
OLDENV=(); while IFS= read -r l; do OLDENV+=("$l"); done < <(docker inspect -f '{{json .Config.Env}}' "$C" | jq -r '.[]' | grep -vE '^Tools__(CatalogLoad|IntakeLoad)__')

# allowlist = destino DEV del propio slot (server del connstring compartido + BD del slot). CleanLoad=true para
# que intake-load haga full-refresh de las insumo (las 3 de convergencia se vacian y recargan; las 6 de estrategia
# full-refresh) desde el golden Oracle.
EXTRA=(
  "Tools__CatalogLoad__Enabled=true"
  "Tools__CatalogLoad__AllowedServers__0=sqlserver,1433"
  "Tools__CatalogLoad__AllowedServers__1=sqlserver"
  "Tools__CatalogLoad__AllowedDatabases__0=${PLANNING_DB}"
  "Tools__IntakeLoad__Enabled=true"
  "Tools__IntakeLoad__CleanLoad=true"
  "Tools__IntakeLoad__AllowedServers__0=sqlserver,1433"
  "Tools__IntakeLoad__AllowedServers__1=sqlserver"
  "Tools__IntakeLoad__AllowedDatabases__0=${PLANNING_DB}"
)

ARGS=(); for e in "${OLDENV[@]}" "${EXTRA[@]}"; do ARGS+=(--env "$e"); done

echo "[gs-tools] recreando $C (img=$IMG puerto=$HOSTPORT:8080 redes=${NETS[*]}) con Tools:CatalogLoad + Tools:IntakeLoad ON ..."
docker rm -f "$C" >/dev/null 2>&1 || true
docker create --name "$C" --network "${NETS[0]}" -p "${HOSTPORT}:8080" "${ARGS[@]}" "$IMG" >/dev/null
for n in "${NETS[@]:1}"; do docker network connect "$n" "$C" >/dev/null; done
docker start "$C" >/dev/null

for i in $(seq 1 90); do
  if curl -fsS -o /dev/null --max-time 4 "http://127.0.0.1:${HOSTPORT}/health/live" 2>/dev/null; then
    echo "[gs-tools] API up (~${i}s) con CatalogLoad + IntakeLoad habilitados"; exit 0
  fi
  [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = true ] || { echo "[gs-tools] el contenedor murio; docker logs $C"; exit 1; }
  sleep 1
done
echo "[gs-tools] la API no respondio /health/live"; exit 1
