#!/usr/bin/env bash
# Smoke de conectividad del camino E2E (req1.2 / req2 de la solicitud e2e-network-prereqs).
# No modifica nada: solo prueba alcanzabilidad y reporta PASS/FAIL/SKIP. Degrada con elegancia si una
# pieza no está arriba (no aborta a mitad). Topología (Opción C): el data tier y la API .NET 10 corren en
# la Intel (macdata); el guest Windows (legado) los alcanza por la pasarela NAT de VMware (GATEWAY).
#
#   make e2e-net-check                         # smoke completo (M1 + guest)
#   PM_E2E_CHECK_GUEST=0 make e2e-net-check    # omite la sección del guest (VM apagada)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
set +e   # common.sh fija 'set -e'; el smoke NO debe abortar a mitad: reporta PASS/FAIL y sigue.
load_env

MD="${PM_REMOTE_SSH:-macdata}"          # alias SSH de la Intel
GWIN="$PM_GUEST_WINHOST"                # IP NAT del guest Windows
GKEY="$PM_GUEST_KEY"                    # llave SSH al guest (residente en macdata)
GW="$PM_GUEST_GATEWAY"                  # macdata vista desde el guest (pasarela NAT)
APIP="$PM_API_PORT"
SQLP="$PM_SQL_HOST_PORT"
ORAP="$PM_ORACLE_HOST_PORT"
BUSP="$PM_SB_HOST_PORT"

PASS=0; FAIL=0
ok()   { local l="$1" c="$2"; if eval "$c" >/dev/null 2>&1; then printf '  [PASS] %s\n' "$l"; PASS=$((PASS+1)); else printf '  [FAIL] %s\n' "$l"; FAIL=$((FAIL+1)); fi; }
skip() { printf '  [SKIP] %s\n' "$1"; }

# Ejecuta PowerShell en el guest (vía macdata -> ssh con llave -> guest). Imprime la salida del comando.
guest_ps() {
  local ps="$1"
  ssh -o ConnectTimeout=10 "$MD" \
    "ssh -i $GKEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12 Administrator@$GWIN \"powershell -NoProfile -Command '$ps'\"" 2>/dev/null
}

echo "== Smoke E2E de red (perfil=$PM_PROFILE) =="
echo "   Intel(macdata)=$MD  guest=$GWIN  gateway(guest->macdata)=$GW  api:$APIP  sql:$SQLP  oracle:$ORAP  bus:$BUSP"

echo "-- M1 -> Intel / data tier / API --"
ok "M1 alcanza la Intel por SSH ($MD)"                 "ssh -o ConnectTimeout=8 $MD true"
ok "'macdata' resuelve a IP en el M1 (/etc/hosts)"     "dscacheutil -q host -a name $MD | grep -q ip_address"
if [ -n "${WT:-}" ]; then
  # Via slot (WT=<folder>): el data tier NO publica 1433/1521/5672+offset en el host de macdata. El SQL se
  # alcanza por el puente 60211, el Oracle del slot por 15210+N y el bus por 15672; estos checks M1-directos por
  # offset no aplican y darian FAIL espurio. Se omiten (la via wt no expone esos puertos por offset).
  skip "M1 -> data tier SQL/Oracle/bus por offset (via slot WT=$WT: SQL por puente 60211, Oracle 15210+N, bus 15672)"
else
  ok "M1 -> data tier SQL ($MD:$SQLP)"                   "nc -z -G 6 $MD $SQLP"
  if [ "$PM_PROFILE" = "full" ]; then
    ok "M1 -> data tier Oracle ($MD:$ORAP)"              "nc -z -G 6 $MD $ORAP"
    ok "M1 -> data tier bus/AMQP ($MD:$BUSP)"            "nc -z -G 6 $MD $BUSP"
  else
    skip "data tier Oracle/bus (perfil != full)"
  fi
fi
ok "API .NET 10 viva en la Intel (local 127.0.0.1)"    "ssh -o ConnectTimeout=8 $MD \"curl -fsS -o /dev/null --max-time 8 http://127.0.0.1:$APIP/health/live\""
ok "M1 -> API en la LAN ($MD:$APIP/health/live)"        "curl -fsS -o /dev/null --max-time 8 http://$MD:$APIP/health/live"

echo "-- guest (VM legado) -> backend / data tier --"
if [ "${PM_E2E_CHECK_GUEST:-1}" != "1" ]; then
  skip "sección del guest deshabilitada (PM_E2E_CHECK_GUEST=0)"
elif [ -z "$(guest_ps 'hostname')" ]; then
  skip "guest no alcanzable por SSH (¿VM apagada? ver 'make legacy-status'); se omiten sus checks"
else
  ok "guest -> backend TCP ($GW:$APIP)"                 "guest_ps '(Test-NetConnection -ComputerName $GW -Port $APIP -WarningAction SilentlyContinue).TcpTestSucceeded' | grep -qi true"
  ok "guest -> backend /health/live (HTTP 200)"         "guest_ps 'try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 http://$GW:$APIP/health/live).StatusCode } catch { 0 }' | grep -q 200"
  if [ "$PM_PROFILE" = "full" ]; then
    ok "guest -> data tier Oracle TCP ($GW:$ORAP)"      "guest_ps '(Test-NetConnection -ComputerName $GW -Port $ORAP -WarningAction SilentlyContinue).TcpTestSucceeded' | grep -qi true"
  fi
  ok "guest -> data tier SQL TCP ($GW:$SQLP)"           "guest_ps '(Test-NetConnection -ComputerName $GW -Port $SQLP -WarningAction SilentlyContinue).TcpTestSucceeded' | grep -qi true"
fi

echo "== Resultado: $PASS PASS / $FAIL FAIL =="
[ "$FAIL" -eq 0 ]
