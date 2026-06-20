# Catalogo unico de verbos de gs-pl-pm-macops-sidecar: data tier + API real (pm-*) y lanzamiento del legado (legacy-*).
# Capa fina; la logica vive en bash (pm.sh + lib/common.sh para pm-*, legacy.sh para legacy-*).
#
# Data tier + API + tests (pm-*):
#   make pm-run                   # local: levanta + seedea SQL
#   make pm-run PROFILE=full      # local: + Oracle + Service Bus emulador
#   make pm-seed                  # re-seed idempotente (SQL)
#   make pm-api / pm-api-down     # levanta / detiene la API real en ESTA mac (M1)
#   make pm-test                  # inner-loop: reusa la API si responde + dotnet test (default PROFILE=sql)
#   make pm-test-clean            # GATE limpio: pm-run (up+seed) + API fresca + TODA la suite (fija PROFILE=full)
#   make pm-test FILTER='FullyQualifiedName~RtSync'   # acota por filtro (inner-loop)
#   make pm-test APIFORCE=1                            # relanza la API (api-down+api) antes de testear; no reusa
#   make pm-down / pm-nuke        # baja el data tier (conserva / borra volumenes)   [pm-nuke: ver aviso abajo]
#   make pm-ps / pm-logs / pm-port
#   make pm-run TARGET=intel REMOTE=macdata SQLHOST=macdata   # data tier en la Intel (requiere 'macdata' en /etc/hosts del M1; ver README)
#   make pm-run PROJECT=pm-ag2 OFFSET=10                      # 2o stack en paralelo (SQL/Oracle/API/bus +10)
#   make pm-bootstrap-intel REMOTE=macdata                   # aprovisiona colima/docker en la Intel (1 vez)
#   # Gate: el comando verde es 'pm-test-clean' (perfil full = Oracle+bus, API fresca). 'pm-test' a secas corre sql-only.
#   # Vars del bus/Ln: PM_LN_DB (erpln106), PM_SERVICEBUS_HOST, PM_SB_HOST_PORT (5672+OFFSET), PM_SB_SA_PASSWORD.
#
# Backend en modo E2E (Opción C; API co-localizada con el data tier en macdata, alcanzable por el guest legado):
#   make e2e-backend                         # data tier (intel) + API en macdata; imprime la URL guest (172.16.128.1:5180)
#   make e2e-backend DATATIER=0              # solo la API (asume el data tier ya arriba)
#   make e2e-backend APIFORCE=1              # relanza la API en macdata (no reusa la que esté arriba)
#   make e2e-backend-down                    # detiene la API E2E en macdata
#   make e2e-net-check                       # smoke de conectividad (M1 + guest -> backend/data tier)
#   # Prereq: 'dotnet' (SDK .NET 10) y firewall abierto en macdata; 'macdata' resoluble en /etc/hosts del M1 (ver README).
#
# Aprovisionamiento aislado por worktree (wt-*; SQL compartido de nvoslabs + bus PM-owned, en macdata):
#   make wt-up WT=<folder>                    # aprovisiona el entorno del worktree (slot, seed, API); intel-only
#   make wt-up WT=<folder> SOLUTION=<path>    # fuerza la raiz de la solucion del worktree (build de la API)
#   make wt-down WT=<folder>                  # baja API + BD del worktree; libera el slot (singletons intactos)
#   make wt-ls                                # lista el registro de slots (folder -> slot)
#   make wt-status                            # estado de los contenedores PM por worktree y del bus
#   make wt-seed-ln                           # asegura la referencia LN compartida (pm_erpln106) una vez
#   # Slot 0..N-1 (N=SLOTS, default 4) -> proyecto pm-wt<N>, API :5180+N*10, BD pm_planning_wt<N>, bus prefix wt<N>.
#   # Vars del SQL compartido (override): SHAREDSQL_NET/HOST/PORT/PASSWORD (default red nvoslabsc3-sharedsql-dt, sqlserver:1433).
#   # WT se autodetecta con git rev-parse si se corre dentro del worktree. Requiere REMOTE=macdata.
#
# Legado CargaPlantaPT_LN (legacy-*; data tier solo en intel/macdata):
#   make legacy-launch                       # todo: data tier (intel) + VM + build + deploy + tunel + URL
#   make legacy-launch FORCE=1               # fuerza rebuild/redeploy aunque ya este arriba
#   make legacy-launch SITEPORT=8048 TUNNEL=18048   # puertos no-default
#   make legacy-launch DATATIER=0            # no gestiona el data tier (asume ya provisto)
#   make legacy-status                       # estado de data tier / VM / app / tunel
#   make legacy-url                          # imprime URL y puertos de acceso
#   make legacy-build / legacy-deploy / legacy-vm-up / legacy-data-up / legacy-tunnel
#   make legacy-down                         # cierra el tunel SSH
#
# Data tier COMPARTIDO: legacy-data-up lo levanta via pm-run (TARGET=intel). El perfil del legado se
# controla con LEGACY_PROFILE (default full: requiere Oracle ControlPiso); el de pm con PROFILE (default sql).
# AVISO pm-nuke: legacy-* comparte el stack 'pm-local'; 'pm-nuke' borra volumenes -> re-siembra el seed pero
#   NO lo que el legado haya escrito en vivo. Aislar agentes por stack (PROJECT/OFFSET levanta tambien su bus).

# --- Variables data tier + API (pm-*) ---
TARGET      ?= local
PROFILE     ?= sql
PROJECT     ?= pm-local
OFFSET      ?= 0
PORT_MODE   ?= offset
REMOTE      ?=
CONTEXT     ?=
SQLHOST     ?= 127.0.0.1
APIPORT     ?=
FILTER      ?=
TESTPROJECT ?=
APIFORCE    ?= 0

PM_ENV = PM_TARGET=$(TARGET) PM_PROFILE=$(PROFILE) PM_PROJECT=$(PROJECT) \
         PM_PORT_OFFSET=$(OFFSET) PM_PORT_MODE=$(PORT_MODE) PM_REMOTE_SSH=$(REMOTE) \
         PM_REMOTE_DOCKER_CONTEXT=$(CONTEXT) PM_TEST_SQL_HOST=$(SQLHOST) PM_API_PORT=$(APIPORT) \
         PM_TEST_FILTER='$(FILTER)' PM_TEST_PROJECT='$(TESTPROJECT)' PM_API_FORCE=$(APIFORCE)

# --- Variables legado (legacy-*) ---
MACDATA       ?= macdata
WINHOST       ?= 172.16.128.129
SITEPORT      ?= 8080
TUNNEL        ?= 18080
SQLPORT       ?= 1433
ORACLEPORT    ?= 1521
LEGACY_PROFILE?= full
DATATIER      ?= 1
FORCE         ?= 0
MAX           ?= 40

LEGACY_ENV = PM_LEGACY_MACDATA=$(MACDATA) PM_LEGACY_WINHOST=$(WINHOST) PM_LEGACY_SITE_PORT=$(SITEPORT) \
             PM_LEGACY_TUNNEL_PORT=$(TUNNEL) PM_LEGACY_SQL_PORT=$(SQLPORT) PM_LEGACY_ORACLE_PORT=$(ORACLEPORT) \
             PM_LEGACY_PROFILE=$(LEGACY_PROFILE) PM_LEGACY_DATATIER=$(DATATIER) PM_LEGACY_FORCE=$(FORCE)

# --- Variables E2E (Opción C: API co-localizada con el data tier en macdata, alcanzable por el guest) ---
# macdata vista DESDE el guest (pasarela NAT de VMware):
GATEWAY   ?= 172.16.128.1
# llave SSH al guest (residente en macdata; el ~ se mantiene literal y se expande EN macdata):
GUESTKEY  ?= ~/pm-host-windows/artifacts/ssh/id_pmwin
# WINHOST (IP del guest) y DATATIER (1=levanta el data tier antes de la API) se reusan de las vars del legado.

# GUESTKEY va entre comillas simples para que el ~ NO se expanda en el M1 (la llave vive en macdata).
E2E_ENV = $(PM_ENV) PM_GUEST_GATEWAY=$(GATEWAY) PM_GUEST_WINHOST=$(WINHOST) \
          PM_GUEST_KEY='$(GUESTKEY)' PM_E2E_DATATIER=$(DATATIER)

# --- Variables aprovisionamiento por worktree (wt-*) ---
WT          ?=
SLOTS       ?= 4
SOLUTION    ?=
SHAREDSQL_NET   ?=
SHAREDSQL_HOST  ?=
SHAREDSQL_PORT  ?=
SHAREDSQL_PASSWORD ?=

WT_ENV = $(PM_ENV) WT=$(WT) PM_WT_SLOTS=$(SLOTS) PM_WT_SOLUTION_DIR='$(SOLUTION)' \
         PM_SHARED_SQL_NETWORK=$(SHAREDSQL_NET) PM_SHARED_SQL_HOST=$(SHAREDSQL_HOST) \
         PM_SHARED_SQL_PORT=$(SHAREDSQL_PORT) PM_SHARED_SQL_PASSWORD='$(SHAREDSQL_PASSWORD)'

.PHONY: pm-run pm-watch pm-seed pm-api pm-api-down pm-test pm-test-clean pm-down pm-nuke pm-ps pm-logs pm-port pm-bootstrap-intel \
        wt-up wt-down wt-ls wt-status wt-seed-ln \
        e2e-backend e2e-backend-down e2e-net-check \
        legacy-launch legacy-data-up legacy-vm-up legacy-build legacy-deploy legacy-diag legacy-diag-logs \
        legacy-tunnel legacy-status legacy-url legacy-down help

# --- data tier + API ---
pm-run:      ; $(PM_ENV) ./pm.sh run
pm-watch:    ; $(PM_ENV) ./pm.sh run --watch
pm-seed:     ; $(PM_ENV) ./pm.sh seed
pm-api:      ; $(PM_ENV) ./pm.sh api
pm-api-down: ; $(PM_ENV) ./pm.sh api-down
pm-test:     ; $(PM_ENV) ./pm.sh test
pm-test-clean: PROFILE  := full
pm-test-clean: APIFORCE := 1
pm-test-clean: ; $(PM_ENV) ./pm.sh test-clean
pm-down:     ; $(PM_ENV) ./pm.sh down
pm-nuke:     ; $(PM_ENV) ./pm.sh nuke
pm-ps:       ; $(PM_ENV) ./pm.sh ps
pm-logs:     ; $(PM_ENV) ./pm.sh logs
pm-port:     ; $(PM_ENV) ./pm.sh port
pm-bootstrap-intel: ; @test -n "$(REMOTE)" || { echo "falta REMOTE=<host-ssh-intel>"; exit 2; }; ssh $(REMOTE) 'bash -s' < remote-intel/bootstrap-intel.sh

# --- backend en modo E2E (Opción C): API en macdata, alcanzable por el guest ---
# 'override' fija el contrato del modo E2E aun frente a un override de línea de comando (TARGET/REMOTE/PROFILE
# deben ser intel/macdata/full); el host del SQL en E2E lo fuerza el driver (pm.sh cmd_api_e2e), no esta capa.
e2e-backend:      override TARGET  := intel
e2e-backend:      override REMOTE  := macdata
e2e-backend:      override PROFILE := full
e2e-backend:      ; $(E2E_ENV) ./pm.sh e2e-backend
e2e-backend-down: override TARGET  := intel
e2e-backend-down: override REMOTE  := macdata
e2e-backend-down: ; $(E2E_ENV) ./pm.sh e2e-backend-down
e2e-net-check:    override REMOTE  := macdata
e2e-net-check:    override PROFILE := full
e2e-net-check:    ; $(E2E_ENV) ./scripts/e2e-net-check.sh

# --- aprovisionamiento por worktree (wt-*): intel-only (SQL compartido + bus en macdata) ---
# 'override TARGET' fuerza intel (el SQL compartido vive en el docker de macdata); REMOTE default macdata
# (override por linea de comando permitido si el alias SSH difiere).
wt-up:      override TARGET := intel
wt-up:      REMOTE := macdata
wt-up:      ; $(WT_ENV) ./wt.sh up
wt-down:    override TARGET := intel
wt-down:    REMOTE := macdata
wt-down:    ; $(WT_ENV) ./wt.sh down
wt-status:  override TARGET := intel
wt-status:  REMOTE := macdata
wt-status:  ; $(WT_ENV) ./wt.sh status
wt-seed-ln: override TARGET := intel
wt-seed-ln: REMOTE := macdata
wt-seed-ln: ; $(WT_ENV) ./wt.sh seed-ln
wt-ls:      ; $(WT_ENV) ./wt.sh ls

# --- legado ---
legacy-launch:    ; $(LEGACY_ENV) ./legacy.sh launch
legacy-data-up:   ; $(LEGACY_ENV) ./legacy.sh data-up
legacy-vm-up:     ; $(LEGACY_ENV) ./legacy.sh vm-up
legacy-build:     ; $(LEGACY_ENV) ./legacy.sh build
legacy-deploy:    ; $(LEGACY_ENV) ./legacy.sh deploy
legacy-diag:      ; $(LEGACY_ENV) ./legacy.sh diag
legacy-diag-logs: ; $(LEGACY_ENV) MAX=$(MAX) ./legacy.sh diag-logs
legacy-tunnel:    ; $(LEGACY_ENV) ./legacy.sh tunnel
legacy-status:    ; $(LEGACY_ENV) ./legacy.sh status
legacy-url:       ; $(LEGACY_ENV) ./legacy.sh url
legacy-down:      ; $(LEGACY_ENV) ./legacy.sh down

help: ; @grep -E '^#' Makefile | sed 's/^# \{0,1\}//'
