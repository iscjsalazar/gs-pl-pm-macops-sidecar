# Catalogo unico de verbos de gs-pl-pm-macops-sidecar: data tier + API real (pm-*) y lanzamiento del legado (legacy-*).
# Capa fina; la logica vive en bash (pm.sh + lib/common.sh para pm-*, legacy.sh para legacy-*).
# Marcas (norma de slots, process-e2e-local-slots.md): [WT obligatorio] = exige WT=<worktree> con slot;
# [SLOT obligatorio] = exige SLOT=<N>; [DEPRECADO] = modo sustituido por la via por slots (corta o avisa; §5).
#
# Data tier + API + tests (pm-*):
#   make pm-run                   # local: levanta el data tier + migra EF (crea BD/DDL) + seed data-only
#   make pm-run PROFILE=full      # local: + Oracle + Service Bus emulador
#   make pm-watch                 # pm-run + queda siguiendo los logs del data tier (Ctrl-C corta)
#   make pm-migrate               # aplica solo las migraciones EF (crea BD y DDL; EF = dueno del DDL)
#   make pm-seed                  # re-seed data-only idempotente (requiere la BD ya migrada)
#   make pm-api / pm-api-down     # levanta / detiene la API real en ESTA mac (M1)
#   make pm-test                  # inner-loop: reusa la API si responde + dotnet test (default PROFILE=sql)
#   [WT obligatorio] make pm-test-clean WT=<worktree>   # GATE limpio POR SLOT: wt-up (slot API+BD+seed+Oracle) + migrate por puente + suite; sin WT/slot falla (exit 2)
#   make pm-test FILTER='FullyQualifiedName~RtSync'   # acota por filtro (inner-loop)
#   make pm-test APIFORCE=1                            # relanza la API (api-down+api) antes de testear; no reusa
#   make pm-unit                  # unit tests puros (*.UnitTests): sin Docker, sin red, sin data tier; FILTER= acota
#   make pm-format               # formatea los .cs modificados vs develop (delega a scripts/format.sh in-repo)
#   make pm-format-check         # gate de formato changed-vs-develop (delega a scripts/format-check.sh); sin data tier
#   make pm-down                  # baja el data tier (conserva volumenes)
#   make pm-nuke NUKE=1           # borra contenedores+volumenes; sin NUKE=1 corta (exit 2). Ver AVISO pm-nuke abajo
#   make pm-ps / pm-logs / pm-port
#   make pm-run TARGET=intel REMOTE=macdata SQLHOST=macdata   # data tier en la Intel (requiere 'macdata' en /etc/hosts del M1; ver README)
#   [DEPRECADO] make pm-run PROJECT=pm-ag2 OFFSET=10          # como ambiente de trabajo: PROJECT/OFFSET solo vale para el singleton pm-local; usa make wt-up WT=<worktree> (§5)
#   make pm-bootstrap-intel REMOTE=macdata                   # aprovisiona colima/docker en la Intel (1 vez)
#   make help                     # imprime este catalogo (grep del encabezado)
#   # Gate: el comando verde es 'pm-test-clean' (perfil full = Oracle+bus, API fresca). 'pm-test' a secas corre sql-only.
#   # Vars del bus/Ln: PM_LN_DB (erpln106), PM_SERVICEBUS_HOST, PM_SB_HOST_PORT (5672+OFFSET), PM_SB_SA_PASSWORD.
#
# Backend en modo E2E (Opción C) — via DEPRECADA (§5; la sustituyen wt-up / e2e-up por slot):
#   [DEPRECADO] make e2e-backend                         # data tier (intel) + API en macdata; imprime la URL guest (172.16.128.1:5180)
#   [DEPRECADO] make e2e-backend DATATIER=0              # solo la API (asume el data tier ya arriba)
#   [DEPRECADO] make e2e-backend APIFORCE=1              # relanza la API en macdata (no reusa la que esté arriba)
#   [DEPRECADO] make e2e-backend-down                    # detiene la API E2E en macdata
#   make e2e-net-check                       # smoke de conectividad (M1 + guest -> backend/data tier)
#   # Prereq: 'dotnet' (SDK .NET 10) y firewall abierto en macdata; 'macdata' resoluble en /etc/hosts del M1 (ver README).
#
# Orquestacion E2E completa (ruta wt: backend(slot) + legacy con inyeccion + flag + smoke funcional legacy-driven):
#   [WT obligatorio] make e2e-up    WT=<wt-pm> LEGACYSRC=<path-legacy-develop>   # todo: data tier + backend(slot) + puente SQL + legacy(+inyeccion) + flag ON + smoke
#   [WT obligatorio] make e2e-up    ... LINEA=<cod> ANOF=<aaaa> SEMF=<sem>       # params reales del disparo (el caso OFF/Oracle los exige)
#   [WT obligatorio] make e2e-up    ... FORCE=1                                  # re-deploya el legado (re-inyecta wiring; necesario si cambia el slot)
#   [WT obligatorio] make e2e-smoke WT=<wt-pm>                                   # solo el smoke funcional (ON->backend, OFF->Oracle)
#   [WT obligatorio] make e2e-url   WT=<wt-pm>                                   # reimprime la URL de acceso del slot (re-levanta el tunel si murio)
#   [WT obligatorio] make e2e-down  WT=<wt-pm>                                   # baja tunel + site + API + Oracle del slot (singletons intactos)
#   [WT obligatorio] make e2e-oracle-counts WT=<wt-pm>                           # conteos de PGE950RT en el Oracle del slot Y en el singleton
#                                                               #   (evidencia de aislamiento: corre antes y despues de una carga OFF)
#   # WT = worktree de pl-programa-maestro (PL.PM.sln) EN develop; LEGACYSRC = fuente del legado EN develop (trae el gateway de Fase 1).
#   # El shared SQL (nvoslabs) solo escucha en loopback de macdata -> e2e-up levanta un puente socat (BRIDGEPORT=60211) para el guest.
#   # Inyeccion en el deploy: backendBaseUrl (appSettings) + ConStrPm (Config\connections.config, catalogo pm_planning_wt<N>).
#
# Aprovisionamiento aislado por worktree (wt-*; SQL compartido de nvoslabs + bus PM-owned, en macdata):
#   [WT obligatorio] make wt-up WT=<folder>                    # aprovisiona el entorno del worktree (slot, seed, API); intel-only
#   [WT obligatorio] make wt-up WT=<folder> ORACLE=1           # + Oracle ControlPiso propio del slot (lazy; la via e2e-up lo enciende)
#   [WT obligatorio] make wt-up WT=<folder> SOLUTION=<path>    # fuerza la raiz de la solucion del worktree (build de la API)
#   [WT obligatorio] make wt-down WT=<folder>                  # baja API + Oracle + BD del worktree; libera el slot (singletons intactos)
#   [WT obligatorio] make wt-info WT=<folder>                  # imprime la derivacion COMPLETA del slot ("que slot es mio")
#   make wt-ls                                # lista el registro de slots (folder -> slot)
#   make wt-status                            # estado de los contenedores PM por worktree y del bus
#   make wt-gc / make wt-gc FORCE=1           # cruza registro/API/Oracle/sites: lista (o retira) huerfanos
#   make wt-seed-ln                           # asegura la referencia LN compartida (pm_erpln106) una vez
#   # Slot 0..N-1 (N=SLOTS, default 8) -> proyecto pm-wt<N>, API :5180+N*10, BD pm_planning_wt<N>, bus prefix wt<N>,
#   #   site IIS pm-wt<N>::8100+N, tunel :18100+N, Oracle pm-wt<N>-oracle-1::15210+N. Ver README (tabla canonica).
#   # Vars del SQL compartido (override): SHAREDSQL_NET/HOST/PORT/PASSWORD (default red nvoslabsc3-sharedsql-dt, sqlserver:1433).
#   # WT se autodetecta con git rev-parse si se corre dentro del worktree. Requiere REMOTE=macdata.
#
# Legado CargaPlantaPT_LN (legacy-*; data tier solo en intel/macdata):
#   [SLOT obligatorio] make legacy-launch                       # todo: data tier (intel) + VM + build + deploy + tunel + URL
#   [SLOT obligatorio] make legacy-launch FORCE=1               # fuerza rebuild/redeploy aunque ya este arriba
#   [SLOT obligatorio] make legacy-launch SLOT=3                # via per-slot: site pm-wt3:8103, arbol C:\wt3, tunel 18103
#   [DEPRECADO] make legacy-launch SITEPORT=… TUNNEL=…  # puertos ad-hoc: el slot los deriva; §5 de la guía
#   [SLOT obligatorio] make legacy-launch DATATIER=0            # no gestiona el data tier (asume ya provisto)
#   make legacy-status                       # estado de data tier / VM / app / tunel
#   make legacy-url                          # imprime URL y puertos de acceso
#   [SLOT obligatorio] make legacy-build / legacy-deploy
#   make legacy-vm-up / legacy-data-up       # asegura la VM Windows / el data tier en intel (idempotentes)
#   make legacy-tunnel                       # abre el tunel SSH M1->guest (SLOT=<N> deriva el puerto; TUNNEL= ad-hoc avisa DEPRECADO)
#   make legacy-diag                         # habilita el log de errores detallado del guest + recicla el pool
#   make legacy-diag-logs MAX=40             # vuelca los errores ASP.NET del Event Log del guest
#   make legacy-down                         # cierra el tunel SSH y libera el turno del guest singleton
#   [SLOT obligatorio] make legacy-site-down SLOT=3             # desmonta el site per-slot del guest (nunca el singleton)
#   make legacy-sites-status                 # sites 'pm*' del guest cruzados con el registro de slots
#   make legacy-turn-status / legacy-turn-release   # turno exclusivo del guest singleton (site pm:8080, C:\src)
#   make legacy-turn-heartbeat               # refresca el heartbeat del turno propio (sesiones largas de uso del site)
#   # Via LEGADA (escape SINGLETON=1, deprecada §5): un solo site/arbol/Web.config -> tomado por 'guest-turn'
#   #   (una sesion a la vez). Via PER-SLOT (SLOT=N): sites paralelos, sin turno. En ambas, stage->build->deploy
#   #   lo serializa un lock que vive en macdata (scripts/guest-lock.sh): MSBuild, IIS y los vCPU de la VM son compartidos.
#
# Data tier COMPARTIDO: legacy-data-up lo levanta via pm-run (TARGET=intel). El perfil del legado se
# controla con LEGACY_PROFILE (default full: requiere Oracle ControlPiso); el de pm con PROFILE (default sql).
# AVISO pm-nuke: legacy-* comparte el stack 'pm-local'; 'pm-nuke' borra volumenes -> re-siembra el seed pero
#   NO lo que el legado haya escrito en vivo (por eso exige NUKE=1). Aislar sesiones = via por slots
#   (make wt-up WT=<worktree>); PROJECT/OFFSET queda solo para stacks compose manuales del data tier.

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
# Confirmacion de pm-nuke: borra los volumenes del stack (compartidos con el legado en vivo) -> exige NUKE=1.
NUKE        ?= 0
# Override de la raiz del arbol (autodetectada por marcador gs-pl-pm-macops-sidecar/ si se omite); util si el
# sidecar corre fuera del layout estandar. WT/SOLUTION (def. en el bloque wt-*) seleccionan el codigo a operar.
WRAPPER     ?=

PM_ENV = PM_TARGET=$(TARGET) PM_PROFILE=$(PROFILE) PM_PROJECT=$(PROJECT) \
         PM_PORT_OFFSET=$(OFFSET) PM_PORT_MODE=$(PORT_MODE) PM_REMOTE_SSH=$(REMOTE) \
         PM_REMOTE_DOCKER_CONTEXT=$(CONTEXT) PM_TEST_SQL_HOST=$(SQLHOST) PM_API_PORT=$(APIPORT) \
         PM_TEST_FILTER='$(FILTER)' PM_TEST_PROJECT='$(TESTPROJECT)' PM_API_FORCE=$(APIFORCE) \
         WT=$(WT) PM_SOLUTION_DIR='$(SOLUTION)' PM_WRAPPER_DIR='$(WRAPPER)'

# --- Variables legado (legacy-*) ---
# SLOT vacio = via singleton (site 'pm':8080, arbol C:\src). SLOT=<N> = via per-slot (site 'pm-wt<N>':8100+N).
# SITEPORT/TUNNEL vacios = los deriva legacy.sh del slot (8100+N / 18100+N) o usa el default singleton
# (8080/18080). Fijarlos a mano solo para puertos no-default.
# ATENCION (contrato duro): estas asignaciones son un PREFIJO de la linea de comando, asi que GANAN sobre el
# entorno heredado. Un valor per-slot (p. ej. el puerto del Oracle del slot) debe viajar como VARIABLE DE MAKE
# (make legacy-launch ORACLEPORT=15213), nunca por env: el env se pisa aqui en silencio.
MACDATA       ?= macdata
WINHOST       ?= 172.16.128.129
SLOT          ?=
SINGLETON     ?= 0
SITEPORT      ?=
TUNNEL        ?=
SQLPORT       ?= 1433
ORACLEPORT    ?= 1521
DBHOST        ?= 172.16.128.1
LEGACY_PROFILE?= full
DATATIER      ?= 1
FORCE         ?= 0
MAX           ?= 40

LEGACY_ENV = PM_LEGACY_MACDATA=$(MACDATA) PM_LEGACY_WINHOST=$(WINHOST) PM_LEGACY_SLOT=$(SLOT) \
             PM_LEGACY_SITE_PORT=$(SITEPORT) PM_LEGACY_TUNNEL_PORT=$(TUNNEL) \
             PM_LEGACY_SQL_PORT=$(SQLPORT) PM_LEGACY_ORACLE_PORT=$(ORACLEPORT) PM_LEGACY_DBHOST=$(DBHOST) \
             PM_LEGACY_PROFILE=$(LEGACY_PROFILE) PM_LEGACY_DATATIER=$(DATATIER) PM_LEGACY_FORCE=$(FORCE) \
             PM_LEGACY_SINGLETON=$(SINGLETON) \
             WT=$(WT) PM_LEGACY_SRC_LOCAL='$(SOLUTION)' PM_WRAPPER_DIR='$(WRAPPER)'

# --- Variables E2E (Opción C: API co-localizada con el data tier en macdata, alcanzable por el guest) ---
# macdata vista DESDE el guest (pasarela NAT de VMware):
GATEWAY   ?= 172.16.128.1
# llave SSH al guest (residente en macdata; el ~ se mantiene literal y se expande EN macdata):
GUESTKEY  ?= ~/pm-host-windows/artifacts/ssh/id_pmwin
# WINHOST (IP del guest) y DATATIER (1=levanta el data tier antes de la API) se reusan de las vars del legado.

# GUESTKEY va entre comillas simples para que el ~ NO se expanda en el M1 (la llave vive en macdata).
E2E_ENV = $(PM_ENV) PM_GUEST_GATEWAY=$(GATEWAY) PM_GUEST_WINHOST=$(WINHOST) \
          PM_GUEST_KEY='$(GUESTKEY)' PM_E2E_DATATIER=$(DATATIER)

# --- Variables orquestacion E2E (e2e-up/e2e-smoke/e2e-down): wt + legacy + flag + smoke funcional ---
# Ruta wt: el backend corre por slot (WT=<worktree de pl-programa-maestro con PL.PM.sln); LEGACYSRC = fuente
# del legado en develop (ProgramaMaestroPT.sln + el gateway). El shared SQL solo escucha en loopback de macdata
# -> e2e-up levanta un puente (socat) en BRIDGEPORT para que el guest lea el flag. PLANTA/LINEA/ANOF/SEMF son
# los parametros del disparo (LINEA/ANOF/SEMF solo los usa el camino Oracle/OFF). FLAGFINAL = estado del flag
# al terminar. SQLPMHOST = override del host,puerto del SQL del flag (vacio = puente automatico).
LEGACYSRC ?=
PLANTA    ?= RES
LINEA     ?=
ANOF      ?= 0
SEMF      ?= 0
FLAGFINAL ?= on
BRIDGEPORT?= 60211
SQLPMHOST ?=

# PM_E2E_SITE_PORT: e2e.sh ya lo leia pero nadie lo exportaba (el smoke disparaba siempre contra :8080).
E2E_ORCH_ENV = $(E2E_ENV) WT=$(WT) PM_E2E_LEGACY_SRC='$(LEGACYSRC)' PM_E2E_PLANTA=$(PLANTA) \
               PM_E2E_LINEA='$(LINEA)' PM_E2E_ANOF=$(ANOF) PM_E2E_SEMF=$(SEMF) PM_E2E_FLAG_FINAL=$(FLAGFINAL) \
               PM_E2E_TUNNEL='$(TUNNEL)' PM_E2E_SITE_PORT='$(SITEPORT)' PM_E2E_FORCE=$(FORCE) \
               PM_E2E_BRIDGE_PORT=$(BRIDGEPORT) PM_E2E_SQL_PM_HOST='$(SQLPMHOST)'

# --- Variables aprovisionamiento por worktree (wt-*) ---
# SLOTS: 8 slots (0..7) -> bloques reservados API 5180+N*10, site 8100+N, tunel 18100+N, Oracle 15210+N.
# ORACLE=1: aprovisiona el Oracle ControlPiso propio del slot (lazy; la via e2e-up lo enciende siempre).
WT          ?=
SLOTS       ?= 8
ORACLE      ?= 0
SOLUTION    ?=
SHAREDSQL_NET   ?=
SHAREDSQL_HOST  ?=
SHAREDSQL_PORT  ?=
SHAREDSQL_PASSWORD ?=

WT_ENV = $(PM_ENV) WT=$(WT) PM_WT_SLOTS=$(SLOTS) PM_WT_ORACLE=$(ORACLE) PM_WT_GC_FORCE=$(FORCE) \
         PM_WT_SOLUTION_DIR='$(SOLUTION)' \
         PM_SHARED_SQL_NETWORK=$(SHAREDSQL_NET) PM_SHARED_SQL_HOST=$(SHAREDSQL_HOST) \
         PM_SHARED_SQL_PORT=$(SHAREDSQL_PORT) PM_SHARED_SQL_PASSWORD='$(SHAREDSQL_PASSWORD)'

.PHONY: pm-run pm-watch pm-migrate pm-seed pm-api pm-api-down pm-test pm-test-clean pm-unit pm-format pm-format-check pm-down pm-nuke pm-ps pm-logs pm-port pm-bootstrap-intel \
        wt-up wt-down wt-ls wt-info wt-status wt-gc wt-seed-ln \
        e2e-backend e2e-backend-down e2e-net-check e2e-up e2e-smoke e2e-url e2e-down e2e-oracle-counts \
        legacy-launch legacy-data-up legacy-vm-up legacy-build legacy-deploy legacy-diag legacy-diag-logs \
        legacy-tunnel legacy-status legacy-url legacy-down legacy-site-down legacy-sites-status \
        legacy-turn-status legacy-turn-heartbeat legacy-turn-release help

# --- data tier + API ---
pm-run:      ; $(PM_ENV) ./pm.sh run
pm-watch:    ; $(PM_ENV) ./pm.sh run --watch
pm-migrate:  ; $(PM_ENV) ./pm.sh migrate              # aplica solo las migraciones EF (crea BD y DDL)
pm-seed:     ; $(PM_ENV) ./pm.sh seed                 # re-seed data-only (requiere la BD ya migrada)
pm-api:      ; $(PM_ENV) ./pm.sh api
pm-api-down: ; $(PM_ENV) ./pm.sh api-down
pm-test:     ; $(PM_ENV) ./pm.sh test
pm-test-clean: override TARGET := intel        # el data tier del slot vive en macdata (como wt-up)
pm-test-clean: REMOTE  := macdata
pm-test-clean: PROFILE := full
pm-test-clean: ORACLE  := 1                     # gate full: aprovisiona el Oracle ControlPiso del slot
pm-test-clean: ; $(WT_ENV) ./pm.sh test-clean   # gate limpio POR SLOT (WT=<worktree pl-programa-maestro>)
pm-unit:     ; $(PM_ENV) ./pm.sh unit           # unit tests puros (*.UnitTests): sin Docker, sin red, sin data tier
pm-format:       ; $(PM_ENV) ./pm.sh format          # formatea .cs modificados vs develop (delega a scripts/format.sh in-repo)
pm-format-check: ; $(PM_ENV) ./pm.sh format-check    # gate de formato changed-vs-develop (delega a scripts/format-check.sh)
pm-down:     ; $(PM_ENV) ./pm.sh down
# Guard de confirmacion (patron in-recipe de pm-bootstrap-intel): sin NUKE=1 corta antes de invocar pm.sh.
pm-nuke:     ; @[ "$(NUKE)" = "1" ] || { echo "pm-nuke borra los volumenes del stack (compartidos con el legado en vivo): confirma con make pm-nuke NUKE=1" >&2; exit 2; }; $(PM_ENV) ./pm.sh nuke
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

# --- orquestacion E2E completa (ruta wt): data tier + backend(slot) + puente SQL + legacy(+inyeccion) + flag + smoke ---
# 'override' fija intel/macdata como en wt-up (backend, SQL compartido y bus viven en macdata).
e2e-up:    override TARGET  := intel
e2e-up:    override REMOTE  := macdata
e2e-up:    ; $(E2E_ORCH_ENV) ./scripts/e2e.sh up
e2e-smoke: override TARGET  := intel
e2e-smoke: override REMOTE  := macdata
e2e-smoke: ; $(E2E_ORCH_ENV) ./scripts/e2e.sh smoke
e2e-url:   override TARGET  := intel
e2e-url:   override REMOTE  := macdata
e2e-url:   ; $(E2E_ORCH_ENV) ./scripts/e2e.sh url
e2e-down:  override TARGET  := intel
e2e-down:  override REMOTE  := macdata
e2e-down:  ; $(E2E_ORCH_ENV) ./scripts/e2e.sh down
e2e-oracle-counts: override TARGET := intel
e2e-oracle-counts: override REMOTE := macdata
e2e-oracle-counts: ; $(E2E_ORCH_ENV) ./scripts/e2e.sh oracle-counts

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
wt-gc:      override TARGET := intel
wt-gc:      REMOTE := macdata
wt-gc:      ; $(WT_ENV) ./wt.sh gc
wt-seed-ln: override TARGET := intel
wt-seed-ln: REMOTE := macdata
wt-seed-ln: ; $(WT_ENV) ./wt.sh seed-ln
wt-ls:      ; $(WT_ENV) ./wt.sh ls
wt-info:    ; $(WT_ENV) ./wt.sh info

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
legacy-site-down:    ; $(LEGACY_ENV) ./legacy.sh site-down
legacy-sites-status: ; $(LEGACY_ENV) ./legacy.sh sites-status
legacy-turn-status:    ; $(LEGACY_ENV) ./legacy.sh turn-status
legacy-turn-heartbeat: ; $(LEGACY_ENV) ./legacy.sh turn-heartbeat
legacy-turn-release:   ; $(LEGACY_ENV) ./legacy.sh turn-release

help: ; @grep -E '^#' Makefile | sed 's/^# \{0,1\}//'
