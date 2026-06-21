# gs-pl-pm-macops-sidecar — orquestación local (data tier + API + legado)

Carpeta única que reúne la maquinaria de CI/CD local del Programa Maestro. Un solo `Makefile` expone dos
familias de verbos sobre el mismo data tier:

- **`pm-*`** — data tier (SQL Server + Oracle + Service Bus emulador) + API real (`PL.PM.Bootstrapper.Api`) + pruebas de integración
  del backend `pl-programa-maestro`.
- **`legacy-*`** — compilar y correr el legado `CargaPlantaPT_LN` en un host Windows headless (VM en `macdata`).

El `Makefile` es una capa fina; la lógica vive en bash: `pm.sh` + `lib/common.sh` (familia `pm-*`) y
`legacy.sh` (familia `legacy-*`). El data tier es **compartido**: `legacy-data-up` lo levanta reusando
`pm-run TARGET=intel`, y ambos consumen el mismo esquema/seed (provisto por la solicitud `db-setup-containers`).

## Estructura

```
gs-pl-pm-macops-sidecar/
├── README.md            # este archivo
├── Makefile             # catalogo unico de verbos (pm-* / legacy-*)
├── .env.example         # plantilla (2 secciones: pm-* en la M1, legacy-* en macdata)
├── pm.sh                # driver del data tier + API (corre en la M1)
├── lib/common.sh        # libreria de pm.sh (rutas, carga de .env, puertos, docker compose)
├── remote-intel/
│   └── bootstrap-intel.sh   # aprovisiona colima/docker en la mac Intel (una vez)
├── legacy.sh            # driver del lanzamiento del legado (M1; orquesta por SSH)
├── INSTALL-fusion.md    # instalar VMware Fusion (manual; brew lo deshabilitó)
├── packer/              # windows-server-core.pkr.hcl + Autounattend.xml.tmpl + provision/
├── scripts/             # build-vm · vm-up · stage-app · build-app · deploy-app · deploy-iis.ps1 · diag · ...
└── artifacts/           # TODO lo descargado/pesado (GITIGNORED; solo .gitkeep se versiona)
```

## Modelo de ejecución

- El **data tier** corre en contenedores. `TARGET=local` usa colima en esta máquina; `TARGET=intel` los corre
  en la mac Intel (`macdata`) vía SSH (rsync de `containers/` + `docker compose`).
- La **API** real corre como proceso en **esta** máquina (M1). Las **pruebas de integración** son clientes HTTP
  contra esa API y asumen el data tier arriba.
- En el **modo E2E** (`make e2e-backend`, Opción C), la API corre en su propio contenedor en `macdata`, unido a la
  red del data tier, de modo que el guest Windows del legado la alcanza por la pasarela NAT de VMware
  (`172.16.128.1`). Ver §Comandos E2E.
- El **legado** compila y corre en una VM Windows Server 2022 Core headless en `macdata`, operada por SSH; el
  acceso desde la M1 es por túnel SSH (ver §Comandos legado e `INSTALL-fusion.md`).
- La solución (`pl-programa-maestro`) sólo **lee** variables de entorno (`ConnectionStrings__Planning`,
  `ASPNETCORE_URLS`, `PM_API_BASE_URL`). El orquestador no escribe dentro de la solución: la frontera
  wrapper↔solución se mantiene.

## Comandos — data tier + API (`pm-*`)

| Comando | Acción |
| --- | --- |
| `make pm-run` | Levanta y siembra el data tier (SQL; `PROFILE=full` agrega Oracle). |
| `make pm-watch` | `pm-run` con logs en vivo. |
| `make pm-seed` | Re-siembra el SQL (idempotente). |
| `make pm-api` / `make pm-api-down` | Levanta / detiene la API real en esta máquina (M1). |
| `make pm-test` | Inner-loop: reusa la API si responde y corre `dotnet test` (default `PROFILE=sql`; acota con `FILTER=`/`TESTPROJECT=`, fuerza API con `APIFORCE=1`). |
| `make pm-test-clean` | **Gate** limpio: `pm-run` (up+seed) + API fresca (`api-down`+`api`) + toda la suite con `PROFILE=full` (Oracle + bus). |
| `make pm-down` / `make pm-nuke` | Baja el data tier (conserva / borra volúmenes). |
| `make pm-ps` / `make pm-logs` / `make pm-port` | Estado / logs / puertos publicados del data tier. |
| `make pm-bootstrap-intel REMOTE=macdata` | Aprovisiona colima/docker en la mac Intel (una vez). |

```bash
# Gate (check verde): ambiente limpio de cero
make pm-test-clean

# Inner-loop: data tier arriba + iterar tests (rápido, sql)
make pm-run
make pm-test
make pm-test FILTER='FullyQualifiedName~RtSync'
make pm-test TESTPROJECT=tests/PL.PM.IntegrationTests/PL.PM.IntegrationTests.csproj

# Data tier en la mac Intel (macdata) + API en esta máquina
#   requiere 'macdata' resoluble como host (ver §Requisito de host)
make pm-run TARGET=intel REMOTE=macdata SQLHOST=macdata
make pm-test-clean SQLHOST=macdata

# Dos stacks en paralelo (offset desplaza puertos de SQL/Oracle/API/bus)
make pm-run PROJECT=pm-ag2 OFFSET=10
make pm-test-clean PROJECT=pm-ag2 OFFSET=10
```

## Comandos — legado `CargaPlantaPT_LN` (`legacy-*`)

El data tier del legado corre **solo en intel** (`macdata`). `legacy-launch` es idempotente: no relanza lo que
ya está arriba (usar `FORCE=1` para forzar rebuild/redeploy).

| Comando | Acción |
| --- | --- |
| `make legacy-launch` | Todo: data tier (intel) + VM + build + deploy + túnel + URL. |
| `make legacy-data-up` | Asegura el data tier en intel (reusa `pm-run TARGET=intel`). |
| `make legacy-vm-up` | Asegura la VM Windows (omite si ya corre). |
| `make legacy-build` / `make legacy-deploy` | Compila en el guest / publica en IIS (omite si health 200, salvo `FORCE`). |
| `make legacy-tunnel` / `make legacy-down` | Abre / cierra el túnel SSH M1 → guest. |
| `make legacy-status` / `make legacy-url` | Estado de cada pieza / URL y puertos de acceso. |
| `make legacy-diag` / `make legacy-diag-logs` | Habilita log de errores detallado / vuelca errores ASP.NET. |

```bash
make legacy-launch                         # lanzamiento end-to-end
make legacy-launch FORCE=1                 # fuerza rebuild/redeploy
make legacy-launch SITEPORT=8048 TUNNEL=18048   # puertos no-default
make legacy-status                         # estado data tier / VM / app / túnel
make legacy-down                           # cierra el túnel
```

## Comandos — backend en modo E2E (`e2e-*`, Opción C)

Para el camino end-to-end (legado en la VM → API .NET 10 → data tier), la API corre en **su propio contenedor en
`macdata`**, unido a la red del data tier. El contenedor resuelve `sqlserver`/`oracle`/`servicebus` por nombre de
servicio (puertos internos) y publica el puerto E2E (`5180`); así el guest Windows lo alcanza por la misma pasarela
NAT de VMware (`172.16.128.1`) que ya usa para el Oracle del data tier, sin abrir el firewall del M1 ni depender de
su IP DHCP. La imagen se construye desde la solución rsync-eada (`Dockerfile` en `e2e/`, vía `docker build -f-`); la
API recibe su configuración sólo por entorno (`ASPNETCORE_*`, `ConnectionStrings__*`): la solución no conoce al wrapper.

| Comando | Acción |
| --- | --- |
| `make e2e-backend` | Levanta el data tier (intel), construye la imagen de la API y corre el contenedor `<PROJECT>-api`; imprime la URL que ve el guest (`http://172.16.128.1:5180`). |
| `make e2e-backend DATATIER=0` | Sólo la API (asume el data tier ya arriba y su red creada). |
| `make e2e-backend APIFORCE=1` | Recrea el contenedor de la API (no reusa el que esté arriba). |
| `make e2e-backend-down` | Elimina el contenedor de la API E2E en `macdata`. |
| `make e2e-net-check` | Smoke de conectividad: M1 → data tier/API y guest → backend/data tier (`PROFILE=full`). |

```bash
make e2e-backend            # data tier (intel) + contenedor de la API en macdata; guest -> http://172.16.128.1:5180
make e2e-net-check          # verifica guest->backend y la resolución del data tier
PM_E2E_CHECK_GUEST=0 make e2e-net-check   # omite los checks del guest (VM apagada)
make e2e-backend-down       # elimina el contenedor de la API E2E
```

Prerrequisitos en `macdata`:

- `docker` (colima del data tier). No requiere el SDK de .NET en el host: el build ocurre en el stage `sdk:10.0`
  de la imagen; el contenedor de runtime usa `aspnet:10.0`.
- Firewall de `macdata` que permita la conexión entrante del guest al puerto `5180` (el data tier ya admite el
  tráfico del guest hacia sus puertos publicados por Docker).
- En el M1, `macdata` resoluble en `/etc/hosts` (ver §Requisito de host) para `make e2e-net-check` y para alcanzar
  la API por la LAN.

La inyección de esa URL en el config del legado y el feature flag que deriva la carga al backend pertenecen a
otras solicitudes (orquestación E2E y feature flag); aquí sólo se habilita la conectividad de red.

## Comandos — aprovisionamiento por worktree (`wt-*`)

Para trabajar varias solicitudes en paralelo, cada worktree obtiene un entorno aislado a partir de un **slot**
(`0..N-1`, `N=SLOTS`, default 4). El comando reusa el **SQL compartido de nvoslabs** y un **bus PM-owned**
singleton; por worktree levanta una BD de producto y un contenedor de API construido **desde el código del
worktree**. Es **intel-only** (el SQL compartido y el bus viven en `macdata`); `make` fuerza `TARGET=intel`,
`REMOTE=macdata`.

Del slot `N` se derivan: proyecto `pm-wt<N>`, API `:5180+N*10`, BD `pm_planning_wt<N>` y prefijo de bus `wt<N>`.

> **Dos sentidos de "worktree" (distintos).** Estos verbos `wt-*` aprovisionan el **runtime** por worktree
> (un slot con su BD, puertos y contenedor de API). El "worktree" que aprovisionan es un **git worktree del
> repo de código** (`pl-programa-maestro` / `pl-pm-legacy`), típicamente en `pm-cc-wrapper/worktrees/<folder>`,
> que sirve de contexto de build de la API. Es distinto de un **git worktree del propio sidecar**: el sidecar
> resuelve su raíz por marcador (no por su ubicación física), así que los verbos `make` funcionan tanto desde
> el checkout central como desde un worktree del sidecar, compartiendo el estado con el central. Ver
> §Rutas y worktrees.

| Comando | Acción |
| --- | --- |
| `make wt-up WT=<folder>` | Asigna el slot, asegura los singletons (SQL compartido alcanzable, referencia LN `pm_erpln106`, bus `pm-shared`), siembra `pm_planning_wt<N>`, construye y corre `pm-wt<N>-api`; imprime los endpoints. |
| `make wt-up WT=<folder> SOLUTION=<path>` | Fuerza la raíz de la solución del worktree (contexto de build de la API). |
| `make wt-down WT=<folder>` | Baja la API y la BD del worktree y libera el slot; deja los singletons compartidos intactos. |
| `make wt-ls` | Lista el registro de slots (`folder → slot`). |
| `make wt-status` | Estado de los contenedores PM por worktree y del bus. |
| `make wt-seed-ln` | Asegura la referencia LN compartida `pm_erpln106` (paso deliberado de una vez; idempotente). |

```bash
make wt-up WT=feat_pm_mi-solicitud      # aprovisiona; WT se autodetecta con git rev-parse dentro del worktree
make wt-status                           # contenedores pm-wt* + bus pm-shared
make wt-down WT=feat_pm_mi-solicitud     # baja API + BD del worktree; libera el slot
```

El **slot** se asigna desde un registro gitignored `.worktrees/slots.tsv` (lock por `mkdir`, slot libre más bajo,
autodetección por `git rev-parse --show-toplevel`). La conexión al SQL compartido es parametrizable
(`SHAREDSQL_NET`/`HOST`/`PORT`/`PASSWORD`; default red `nvoslabsc3-sharedsql-dt`, `sqlserver:1433`, password
autodescubierta del contenedor). La referencia LN propia de PM se siembra una sola vez con guard de completitud
(no re-siembra si ya está poblada). **Oracle ControlPiso por worktree y el legado multi-sitio** no entran en este
núcleo (sirven a la vía legada/E2E): quedan como follow-up.

Prerrequisitos en `macdata`: el SQL compartido de nvoslabs corriendo (red `nvoslabsc3-sharedsql-dt`), `colima`
del data tier activo y las imágenes base de .NET (`sdk:10.0`/`aspnet:10.0`) disponibles.

## Variables

`make help` lista los comandos. El `Makefile` traduce variables cortas a las `PM_*` / `PM_LEGACY_*` que consumen
los drivers. Los puertos del data tier se derivan en un solo lugar (`compute_ports` en `lib/common.sh`).

| Var `make` | Familia | Default | Rol |
| --- | --- | --- | --- |
| `TARGET` | pm | `local` | `local` (colima) o `intel` (macdata vía SSH). |
| `PROFILE` | pm | `sql` | `sql` o `full` (agrega Oracle). |
| `PROJECT` | pm | `pm-local` | Nombre del proyecto compose; aísla stacks en paralelo. |
| `OFFSET` | pm | `0` | Desplaza puertos por agente (SQL, Oracle y API). |
| `SQLHOST` | pm | `127.0.0.1` | Host del SQL/bus; para `intel`, el alias `macdata` (requiere mapearlo en `/etc/hosts`, ver §Requisito de host). |
| `APIPORT` | pm | `5180 + OFFSET` | Puerto de la API en la M1. |
| `FILTER` | pm | (vacío) | Filtro `--filter` de `dotnet test`. |
| `TESTPROJECT` | pm | `PL.PM.sln` | Proyecto/solución a probar. |
| `REMOTE` | pm | (vacío) | Alias/host SSH de la mac Intel. |
| `APIFORCE` | pm | `0` | `1` relanza la API (`api-down`+`api`) antes de testear. `pm-test-clean` lo fija. |
| `GATEWAY` | e2e | `172.16.128.1` | IP de `macdata` vista desde el guest (pasarela NAT); URL del backend para el guest. |
| `GUESTKEY` | e2e | `~/pm-host-windows/.../id_pmwin` | Llave SSH al guest, residente en `macdata` (el `~` se expande allá). |
| `WINHOST` | e2e/legacy | `172.16.128.129` | IP NAT del guest Windows (reusada del legado). |
| `DATATIER` | e2e/legacy | `1` | `0` = no gestiona el data tier (asume ya provisto). |
| `MACDATA` | legacy | `macdata` | Alias SSH de la mac Intel que hospeda la VM. |
| `SITEPORT` | legacy | `8080` | Puerto IIS del legado en el guest. |
| `TUNNEL` | legacy | `18080` | Puerto local (M1) del túnel SSH → guest. |
| `LEGACY_PROFILE` | legacy | `full` | Perfil del data tier del legado (requiere Oracle ControlPiso). |
| `DATATIER` | legacy | `1` | `0` = no gestiona el data tier (asume ya provisto). |
| `FORCE` | legacy | `0` | `1` = rebuild/redeploy aunque ya esté arriba. |
| `WT` | wt | (vacío) | Folder del worktree; clave del slot. Se autodetecta con `git rev-parse` dentro del worktree. |
| `SLOTS` | wt | `4` | `N` de slots (`0..N-1`). |
| `SOLUTION` | wt | (worktree o principal) | Raíz de la solución del worktree (contexto de build de la API). |
| `SHAREDSQL_NET` / `_HOST` / `_PORT` / `_PASSWORD` | wt | `nvoslabsc3-sharedsql-dt` / `sqlserver` / `1433` / (autodescubierta) | Conexión al SQL compartido de nvoslabs. |

### Variables de entorno del bus / Ln (data tier `full`)

Con `PROFILE=full` aplican además (en `.env` o por entorno): `PM_LN_DB` (default `erpln106`, BD del proxy LN que
consume la ACL real), `PM_SERVICEBUS_HOST` (default = `SQLHOST`) y `PM_SB_SA_PASSWORD` (default `Sb_Local_2026!`).
El puerto del bus se deriva `PM_SB_HOST_PORT = 5672 + OFFSET`; `make pm-port` lo muestra como `BUS`.

## Requisito de host — `macdata` resoluble (target `intel`)

Para apuntar BD/AMQP a la mac Intel con el **alias** `macdata` (`SQLHOST=macdata`), `macdata` debe resolver como
host en el M1: el alias vive sólo en `~/.ssh/config` (sirve para SSH, no para el cliente SQL/AMQP). Se mapea una
vez en `/etc/hosts` del M1, tomando la IP LAN vía el propio SSH:

```bash
echo "$(ssh macdata 'ipconfig getifaddr en0 || ipconfig getifaddr en1') macdata" | sudo tee -a /etc/hosts
```

Tras esto, `SQLHOST=macdata` sirve para SSH **y** para BD/AMQP. Si la IP de la `macdata` cambia (DHCP), se re-ejecuta.

Para el modo E2E (`make e2e-backend`), la API corre en un contenedor **en** `macdata` y el guest la alcanza por la
pasarela NAT (`172.16.128.1`), no por la IP LAN del M1: no hace falta tocar el firewall del M1. En `macdata` basta
`docker` (no el SDK de .NET) y que su firewall permita la conexión entrante del guest al puerto `5180`. El mapeo
`/etc/hosts` del M1 sigue aplicando para `make e2e-net-check` (probes M1 → `macdata`) y para alcanzar la API por la LAN.

## Gate vs inner-loop

- **`make pm-test-clean`** es el **gate**: levanta+seedea el data tier, relanza la API fresca y corre toda la
  suite con `PROFILE=full` (Oracle + Service Bus). Único comando para "¿pasa todo en limpio?".
- **`make pm-test`** es el **inner-loop**: rápido, `PROFILE=sql`, reusa la API arriba; acota con
  `FILTER=`/`TESTPROJECT=` (o `APIFORCE=1` para relanzar la API). La suite de mensajería sólo corre con `full`.

## Paralelismo

La unidad de aislamiento es el **stack completo**, no la suite. `make pm-run PROJECT=pm-ag2 OFFSET=10` levanta su
propio SQL/Oracle/API **y su propio bus** (`5672+OFFSET`). El bus **no** se comparte entre suites concurrentes:
las entidades de `Config.json` son fijas y los tests drenan subscriptions, así que dos agentes contra el mismo
stack competirían por los mismos mensajes. Regla: un agente = un stack (`PROJECT`/`OFFSET`).

> **Aviso `pm-nuke`:** `legacy-*` comparte el stack `pm-local`; `pm-nuke` borra volúmenes — se re-siembra el seed,
> pero no lo que el legado haya escrito en vivo.

> **Aviso `TARGET=intel` desde varios checkouts:** `pm-run TARGET=intel` y `e2e-backend` hacen `rsync --delete`
> a rutas fijas en `macdata` (`PM_REMOTE_DIR=pm-containers`, `PM_REMOTE_SOLUTION_DIR=pm-solution`), que **no** se
> derivan de `PROJECT`/`OFFSET`. Dos checkouts del sidecar (el central y un worktree) ejecutando contra `intel`
> en paralelo se pisan ese contexto remoto aunque usen `PROJECT` distinto. Para correrlos a la vez, además de
> `PROJECT`/`OFFSET` hay que fijar `PM_REMOTE_DIR` y `PM_REMOTE_SOLUTION_DIR` distintos por checkout. Los `wt-*`
> sí aíslan el contexto de build por slot (`pm-solution-wt<N>`).

## Rutas y worktrees

El sidecar localiza los repos hermanos y su propio estado por una **raíz canónica** (`WRAPPER_DIR`), que se
resuelve subiendo el árbol hasta el primer ancestro que contiene `gs-pl-pm-macops-sidecar/` (override:
`PM_WRAPPER_DIR`). Por eso los verbos `make` funcionan igual desde el checkout central que desde un **git
worktree del propio sidecar** (`pm-cc-wrapper/worktrees/<folder>`): la raíz no depende de la ubicación física
del script.

- **Estado compartido con el central.** El `.env` (`gs-pl-pm-macops-sidecar/.env`) y el registro de slots
  (`.worktrees/slots.tsv`) se resuelven SIEMPRE en el **checkout central**, no en el worktree. Así un worktree
  hereda credenciales/config y comparte la contabilidad de slots, sin fragmentarla ni colisionar en `macdata`.
- **Qué código operan los `pm-*`/`legacy-*`.** Por defecto, el **central** (`pl-programa-maestro` /
  `pl-pm-legacy`). Para apuntar a un **worktree de código**: `WT=<folder>` (worktree bajo `worktrees/<folder>`)
  o `SOLUTION=<ruta>`; también se autodetecta si el comando se corre **dentro** de un worktree de código (su
  toplevel git bajo `worktrees/*` con `PL.PM.sln`). Un worktree del propio sidecar (sin `PL.PM.sln`) NO se
  confunde con la solución: cae al central.

## Configuración (`.env`)

`.env.example` documenta dos destinos (ver cabecera del archivo):

- **`gs-pl-pm-macops-sidecar/.env`** (en la M1) — variables `PM_*` de la familia `pm-*` (incluidas las del bus/Ln); lo carga `lib/common.sh`.
- **`~/pm-host-windows/.env`** (en `macdata`) — variables del legado (`HW`, `ART`, `VMNAME`, `ISO`, ...); lo
  cargan los scripts de build/VM que corren allá por SSH.

## Regla de oro — `artifacts/`

Todo lo descargado o generado pesado (ISO de Windows, imágenes/VMs, instaladores, caches de Packer, salidas de
build) va **exclusivamente** a `artifacts/`, que está **gitignored** (junto con `.env` y `packer/Autounattend.xml`).
El resto (scripts, packer, drivers) sí se versiona. Verificar con `git status` antes de cualquier commit.
