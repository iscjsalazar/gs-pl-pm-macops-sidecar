# gs-pl-pm-macops-sidecar — orquestación local (data tier + API + legado)

Carpeta única que reúne la maquinaria de CI/CD local del Programa Maestro. Un solo `Makefile` expone varias
familias de verbos sobre el mismo data tier:

- **`pm-*`** — data tier (SQL Server + Oracle + Service Bus emulador) + API real (`PL.PM.Bootstrapper.Api`) + pruebas de integración
  del backend `pl-programa-maestro`.
- **`legacy-*`** — compilar y correr el legado `CargaPlantaPT_LN` en un host Windows headless (VM en `macdata`).
- **`wt-*`** — aprovisionamiento aislado por worktree (un slot con su BD y API, sobre el SQL compartido de nvoslabs).
- **`e2e-*`** — **orquestación E2E completa** (`e2e-up`/`e2e-smoke`/`e2e-url`/`e2e-down`: backend + legado con inyección de config + feature flag + smoke funcional legacy-driven); el modo `e2e-backend` está **DEPRECADO** con tombstone (ver §Comandos — backend en modo E2E).

El `Makefile` es una capa fina; la lógica vive en bash: `pm.sh` + `lib/common.sh` (`pm-*`), `legacy.sh` (`legacy-*`),
`wt.sh` + `lib/worktrees.sh` (`wt-*`) y `scripts/e2e.sh` (`e2e-*`). El data tier es **compartido**: `legacy-data-up`
lo levanta reusando `pm-run TARGET=intel`, y ambos consumen el mismo esquema/seed (provisto por la solicitud
`db-setup-containers`).

El catálogo del `Makefile` marca cada verbo según la norma de slots (`gs-pl-pm-guidelines/process-e2e-local-slots.md` §5): **`[WT obligatorio]`** exige `WT=<worktree>` con slot asignado, **`[SLOT obligatorio]`** exige `SLOT=<N>` y **`[DEPRECADO]`** señala un modo sustituido por la vía por slots (corta con exit 2 o avisa sin bloquear).

## Estructura

```
gs-pl-pm-macops-sidecar/
├── README.md            # este archivo
├── Makefile             # catalogo unico de verbos (pm-* / legacy-*)
├── .env.example         # plantilla (2 secciones: pm-* en la M1, legacy-* en macdata)
├── pm.sh                # driver del data tier + API (corre en la M1)
├── wt.sh                # driver del aprovisionamiento por worktree (wt-*; slot + SQL compartido)
├── legacy.sh            # driver del lanzamiento del legado (M1; orquesta por SSH)
├── lib/
│   ├── common.sh        # libreria comun (rutas, carga de .env, puertos, docker compose, helpers remotos)
│   └── worktrees.sh     # logica de wt-* (slot, SQL compartido, seed, API y Oracle por worktree)
├── tools/
│   └── guest-turn/      # turno exclusivo del guest legado singleton (mutex por mkdir; corre en la M1)
├── remote-intel/
│   └── bootstrap-intel.sh   # aprovisiona colima/docker en la mac Intel (una vez)
├── e2e/                 # Dockerfile de la imagen de la API en modo E2E
├── INSTALL-fusion.md    # instalar VMware Fusion (manual; brew lo deshabilitó)
├── packer/              # windows-server-core.pkr.hcl + Autounattend.xml.tmpl + provision/
├── scripts/             # vm-up · guest-lock · stage-app · build-app · deploy-app · deploy-iis.ps1
│                        # site-down · sites-status · read-wiring · guest-mem · e2e-net-check · e2e.sh · diag · ...
└── artifacts/           # TODO lo descargado/pesado (GITIGNORED; solo .gitkeep se versiona)
```

## Modelo de ejecución

- El **data tier** corre en contenedores. `TARGET=local` usa colima en esta máquina; `TARGET=intel` los corre
  en la mac Intel (`macdata`) vía SSH (rsync de `containers/` + `docker compose`).
- La **API** real corre como proceso en **esta** máquina (M1). Las **pruebas de integración** son clientes HTTP
  contra esa API y asumen el data tier arriba.
- La **orquestación E2E completa** (`make e2e-up`) compone el backend por la ruta **wt** (contenedor de la API en `macdata`, unido a la red del data tier y alcanzable por el guest Windows por la pasarela NAT de VMware `172.16.128.1`), el legado con inyección de config, el feature flag y un smoke funcional; **todo el runtime vive en `macdata`** (la M1 sólo orquesta por SSH; el disparo del smoke va `macdata`→guest, sin túnel). Ver §Comandos — orquestación E2E completa. El modo `e2e-backend` (Opción C, API suelta) está **DEPRECADO** con tombstone.
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
| `make pm-test-clean WT=<worktree>` | **Gate** por slot: reusa `cmd_wt_up` (API fresca + BD `pm_planning_wt<N>` + seed + Oracle/bus del slot) + `pm_ef_migrate` por el puente SQL `60211` + toda la suite (`PROFILE=full`). Fuerza `TARGET=intel REMOTE=macdata ORACLE=1`; sustituye al singleton `pm-local` como ambiente de validación. |
| `make pm-down` / `make pm-nuke NUKE=1` | Baja el data tier (conserva / borra volúmenes); `pm-nuke` **exige la confirmación `NUKE=1`** (sin ella corta con exit 2). |
| `make pm-ps` / `make pm-logs` / `make pm-port` | Estado / logs / puertos publicados del data tier. |
| `make pm-bootstrap-intel REMOTE=macdata` | Aprovisiona colima/docker en la mac Intel (una vez). |

```bash
# Gate (check verde) por slot: ambiente limpio del slot del worktree
make pm-test-clean WT=<worktree>

# Inner-loop: data tier arriba + iterar tests (rápido, sql)
make pm-run
make pm-test
make pm-test FILTER='FullyQualifiedName~RtSync'
make pm-test TESTPROJECT=tests/PL.PM.IntegrationTests/PL.PM.IntegrationTests.csproj

# Data tier en la mac Intel (macdata) + API en esta máquina
#   requiere 'macdata' resoluble como host (ver §Requisito de host)
make pm-run TARGET=intel REMOTE=macdata SQLHOST=macdata
make pm-test SQLHOST=macdata

# [DEPRECADO] Stacks compose manuales del data tier: como ambiente de trabajo la vía es el slot (make wt-up WT=)
make pm-run PROJECT=pm-ag2 OFFSET=10      # avisa DEPRECADO sin bloquear (offset desplaza puertos de SQL/Oracle/API/bus)
```

## Comandos — legado `CargaPlantaPT_LN` (`legacy-*`)

El data tier del legado corre **solo en intel** (`macdata`). `legacy-launch` es idempotente: no relanza lo que
ya está arriba (usar `FORCE=1` para forzar rebuild/redeploy).

| Comando | Acción |
| --- | --- |
| `make legacy-launch SLOT=<N>` | Todo, sobre el **sitio del slot** (`pm-wt<N>`:`8100+N`, árbol `C:\wt<N>`, túnel `18100+N`): data tier (intel) + VM + build + deploy + túnel + URL. **`SLOT` es mandatorio** (sin él corta con exit 2). |
| `make legacy-launch SINGLETON=1` | **[DEPRECADO]** Escape deliberado de la **vía legada** singleton (site `pm`:8080, árbol `C:\src`): avisa `[VIA LEGADA]` y toma el turno `guest-turn`. |
| `make legacy-data-up` | Asegura el data tier en intel (reusa `pm-run TARGET=intel`). |
| `make legacy-vm-up` | Asegura la VM Windows (omite si ya corre). |
| `make legacy-build SLOT=<N>` / `make legacy-deploy SLOT=<N>` | Compila en el guest / publica en IIS sobre el **árbol del slot** (`C:\wt<N>`); omite si health 200, salvo `FORCE`. **`SLOT` es mandatorio** (exit 2 sin él); `SINGLETON=1` es el escape deprecado hacia el árbol singleton. |
| `make legacy-tunnel` / `make legacy-down` | Abre / cierra el túnel SSH M1 → guest (`legacy-down` libera además el turno del guest). |
| `make legacy-site-down SLOT=<N>` | Desmonta el sitio del slot (site, pool, árbol, raíz, zip, scripts, regla de firewall) y su stage en `macdata`. **Nunca** opera el singleton. |
| `make legacy-sites-status` | Lista los sitios `pm*` del guest cruzados con el registro de slots; marca huérfanos. |
| `make legacy-turn-status` / `make legacy-turn-heartbeat` / `make legacy-turn-release` | Estado / refresco / liberación del turno exclusivo del guest singleton. |
| `make legacy-status` / `make legacy-url` | Estado de cada pieza / URL y puertos de acceso. |
| `make legacy-diag` / `make legacy-diag-logs` | Habilita log de errores detallado / vuelca errores ASP.NET. |

```bash
make legacy-launch SLOT=3                  # vía canónica per-slot: site pm-wt3:8103, árbol C:\wt3, túnel 18103
make legacy-launch SLOT=3 FORCE=1          # fuerza rebuild/redeploy
make legacy-launch SINGLETON=1             # [DEPRECADO] escape de la vía legada singleton (avisa [VIA LEGADA]; toma el turno)
# [DEPRECADO] SITEPORT=/TUNNEL= ad-hoc: los puertos los deriva el slot (8100+N / 18100+N); fijarlos a mano reintroduce colisiones
make legacy-status                         # estado data tier / VM / app / túnel
make legacy-down                           # cierra el túnel y libera el turno del guest
```

### Dos vías, dos locks

La **vía singleton** (vía legada **DEPRECADA**; se alcanza sólo con el escape deliberado `SINGLETON=1` — sin `SLOT` ni `SINGLETON=1`, `legacy-launch`/`legacy-build`/`legacy-deploy` cortan con exit 2) comparte un único sitio `pm`:8080, un único árbol `C:\src` y un único `Web.config`: el `stage` de una sesión borra el árbol de la otra y el `deploy` reescribe su configuración. Por eso está protegida por un **turno exclusivo** (`tools/guest-turn/guest-turn.sh`, mismo patrón que `deploy-turn`: mutex por `mkdir`, identidad por pid + `lstart`, heartbeat con TTL, reclamo por `mv` al *graveyard* — nunca `rm`). Una segunda sesión que intente `legacy-launch`/`build`/`deploy` sobre el singleton recibe **exit 3** y no toca nada. El turno se **mantiene** mientras la sesión usa el sitio y se libera con `make legacy-down` o `make legacy-turn-release`. `guest-turn.sh status` reporta **siempre** la edad de retención y, superado `GUEST_TURN_HOLD_WARN` (default 14400 s / 4 h), imprime `AVISO: RETENCION PROLONGADA` con el comando de rescate (`release` propio; `release --force --reason` ajeno); el aviso está cableado también en `make legacy-sites-status` y en `make wt-gc`.

A diferencia de `deploy-turn`, el reclamo automático exige que el **proceso dueño esté muerto**. Un turno cuyo
heartbeat envejeció pero cuya dueña sigue viva **no se roba**: esa sesión probablemente esté navegando la UI, y
desplegar encima le reescribiría el `Web.config` que está usando — justo lo que el lock existe para impedir. Un turno
vivo pero abandonado se libera con `guest-turn.sh release --force --reason "<texto>"` (orden explícita del usuario,
queda en la bitácora). `GUEST_TURN_STEAL_STALE=1` revierte la política.

La **vía per-slot** (`SLOT=<N>`) no necesita turno: cada slot tiene sitio, árbol, raíz y configuración propios. Los
árboles per-slot viven **fuera de `C:\src`** a propósito: `legacy.sh` reinstala en cada corrida los scripts del
checkout que la invoca, así que un checkout desactualizado del sidecar ejecutaría el viejo
`Remove-Item C:\src -Recurse` y arrasaría cualquier árbol anidado ahí, con sitios vivos apuntándole.

En **ambas** vías, la sección `stage → build → deploy` la serializa un lock que vive en `macdata`
(`scripts/guest-lock.sh`), no en la M1: MSBuild y sus nodos residentes, el `applicationHost.config` de IIS (los
cmdlets de `WebAdministration` concurrentes fallan al *commitear*) y los vCPU de la VM son recursos compartidos por
todos los sitios. Al vivir en `macdata`, el lock cubre también a sesiones de otras máquinas orquestadoras. Antes de
reclamar un lock rancio consulta al guest: si hay un MSBuild vivo, **no** lo roba.

## Comandos — backend en modo E2E (`e2e-*`, Opción C) — DEPRECADO

**Vía DEPRECADA, solo tombstone permanente** (`gs-pl-pm-guidelines/process-e2e-local-slots.md` §5): `make e2e-backend` y `make e2e-backend-down` cortan con aviso y **exit 2** sin tocar nada — la API suelta en `macdata` no tenía BD, Oracle ni frontend propios y no aislaba nada. El código de la vía `e2e-backend` ya se retiró; solo permanece el tombstone (guard permanente). La sustituye la vía por slot: `make wt-up WT=<worktree>` (solo el backend del slot) o `make e2e-up WT=<wt-pm> LEGACYSRC=<path>` (camino completo).

| Comando | Acción |
| --- | --- |
| `make e2e-backend` / `make e2e-backend-down` | **[DEPRECADO]** Tombstone: cortan con exit 2 y remiten a `make wt-up WT=` / `make wt-down WT=`. |
| `make e2e-net-check` | **Vigente.** Smoke de conectividad: M1 → data tier/API y guest → backend/data tier (`PROFILE=full`). En modo slot (con `WT` / dentro de `e2e-up`) hace **SKIP** de los checks del data tier por offset en vez de fallar sobre puertos inexistentes en la vía wt. `PM_E2E_CHECK_GUEST=0` omite los checks del guest (VM apagada). |

## Comandos — aprovisionamiento por worktree (`wt-*`)

Para trabajar varias solicitudes en paralelo, cada worktree obtiene un entorno aislado a partir de un **slot**
(`0..N-1`, `N=SLOTS`, default 4). El comando reusa el **SQL compartido de nvoslabs** y un **bus PM-owned**
singleton; por worktree levanta una BD de producto y un contenedor de API construido **desde el código del
worktree**. Es **intel-only** (el SQL compartido y el bus viven en `macdata`); `make` fuerza `TARGET=intel`,
`REMOTE=macdata`.

Del slot `N` se derivan **todos** los recursos de la sesión: el backend, su BD, su Oracle ControlPiso y el sitio IIS del legado. Es el contrato «qué slot es mío»; `make wt-info WT=<folder>` lo imprime instanciado.

### Tabla canónica por slot

| Recurso | Valor por slot | Alcance |
| --- | --- | --- |
| Proyecto compose | `pm-wt<N>` | per-slot |
| Contenedor API | `pm-wt<N>-api` en `5180+N*10` | per-slot |
| BD de planning | `pm_planning_wt<N>` (en el SQL compartido) | per-slot |
| Prefijo de bus | `wt<N>` (broker singleton) | per-slot lógico |
| Dirs remotos de build | `pm-solution-wt<N>` / `pm-containers-wt<N>` | per-slot |
| Contenedor Oracle | `pm-wt<N>-oracle-1` en `15210+N` | per-slot (lazy, `ORACLE=1`) |
| Volumen Oracle | `pm-wt<N>_pm-oracle-data` | per-slot |
| Red compose | `pm-wt<N>_default` | per-slot |
| Site y app pool IIS | `pm-wt<N>` con binding `8100+N` | per-slot |
| Árbol fuente en el guest | `C:\wt<N>\CargaPlantaPT_LN` | per-slot |
| Raíz del site (health) | `C:\inetpub\pmroot-wt<N>` | per-slot |
| Túnel SSH en esta M1 | `18100+N` | per-slot |
| Regla de firewall | `PM site pm-wt<N>` | per-slot |
| Vdir de la aplicación | `ProgramaMaestroLN` | **invariante** (el legado hardcodea la raíz virtual absoluta) |
| Motor SQL Server, bus, puente `60211`, `pm_erpln106` | singletons administrados | compartidos |
| Site `pm`:8080, `pmpub`:8090, `pm-local-oracle-1`:1521 | vía legada / standalone | compartidos |

**Bloques de puertos reservados** (`SLOTS=8`, slots `0..7`): API `5180–5250` (stride 10), sitios `8100–8107`, túneles `18100–18107`, Oracle `15210–15217`. Fuera de esos bloques y por tanto intocables: `8080`/`8090` (sites legados), `1521` (`pm-local-oracle-1`), `1571` (`pm-arts-rt-oracle-1`), `60201` (SQL compartido en loopback), `60211` (puente), `60140`/`60141` (nvoslabs).

Conviven **dos strides** a propósito: `N*10` para la API (herencia de `PM_PORT_OFFSET`) y `+1` para sitio, túnel y Oracle (bloques dedicados). No se unifican: cambiar el de la API rompería los slots vivos.

La fórmula `1521+offset` de `compute_ports` (`lib/common.sh`) sirve a los stacks compose manuales (`pm-run PROJECT=… OFFSET=…`), **no** al Oracle per-slot: con el offset de un slot chocaría con `pm-local-oracle-1` (slot 0 → 1521) y con `pm-arts-rt-oracle-1` (slot 5 → 1571).

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
| `make wt-up WT=<folder> ORACLE=1` | Además aprovisiona el Oracle ControlPiso propio del slot (`pm-wt<N>-oracle-1`) y cablea la API a él (`Parity__LegacySource=oracle`). La vía `e2e-up` siempre lo enciende. |
| `make wt-up WT=<folder> SOLUTION=<path>` | Fuerza la raíz de la solución del worktree (contexto de build de la API). |
| `make wt-down WT=<folder>` | Baja API, Oracle (contenedor **y volumen**) y BD del worktree; verifica su ausencia y sólo entonces libera el slot. Deja los singletons compartidos intactos. |
| `make wt-info WT=<folder>` | Imprime la derivación completa del slot: API, BD, bus, Oracle, site IIS, túnel, rutas del guest, y la sección **Presupuesto** (topes reales: disco/RAM de la VM colima, `docker` reclamable, contadores del guest, slots vivos). |
| `make wt-ls` | Lista el registro de slots (`folder → slot`) y una línea de resumen de presupuesto (disco libre de la VM colima + slots vivos/`SLOTS`). |
| `make wt-status` | Estado de los contenedores PM por worktree (API y Oracle) y del bus. |
| `make wt-gc` / `make wt-gc FORCE=1` | Cruza los cuatro planos (registro · contenedores API · contenedores Oracle · sites IIS y túneles) y lista los huérfanos; con `FORCE=1` los retira. El plano de arrendamientos reclama filas con dueño muerto por TTL **y fantasmas** (dueño muerto + slot sin contenedores vivos, aunque el heartbeat sea fresco). Toma snapshot del registro bajo `wt_registry_lock` y acota el barrido de túneles por `PM_WT_SLOTS_MAX` (mantiene fuera el túnel singleton `18080` y el puente `60211`). Retorna exit≠0 si no pudo limpiar un huérfano (0 si nada). Guard crítico: si el registro es no legible o no adquiere el lock, con `FORCE=1` **aborta sin retirar** (evita `docker rm -f` en masa de sesiones vivas). |
| `make wt-seed-ln` | Asegura la referencia LN compartida `pm_erpln106` (paso deliberado de una vez; idempotente). |

```bash
make wt-up WT=feat_pm_mi-solicitud      # aprovisiona; WT se autodetecta con git rev-parse dentro del worktree
make wt-info WT=feat_pm_mi-solicitud     # "qué slot es mío": puertos, contenedores y rutas del guest
make wt-status                           # contenedores pm-wt* + bus pm-shared
make wt-down WT=feat_pm_mi-solicitud     # baja API + Oracle + BD del worktree; libera el slot
```

El **slot** se asigna desde un registro gitignored `.worktrees/slots.tsv` (lock por `mkdir`, slot libre más bajo,
autodetección por `git rev-parse --show-toplevel`). La conexión al SQL compartido es parametrizable
(`SHAREDSQL_NET`/`HOST`/`PORT`/`PASSWORD`; default red `nvoslabsc3-sharedsql-dt`, `sqlserver:1433`, password
autodescubierta del contenedor). La referencia LN propia de PM se siembra una sola vez con guard de completitud
(no re-siembra si ya está poblada).

**Consistencia registro↔realidad (cura de drift).** El registro (`.worktrees/slots.tsv`) y la realidad (contenedores
`pm-wt<N>-*` en macdata) se reconcilian para que resolver-por-nombre sea confiable, en especial con varios ambientes
en paralelo:

- **Asignación sticky-to-reality.** `wt_slot_assign` recibe el set de slots con contenedores VIVOS (una `docker ps`)
  y **no entrega un slot huérfano** (contenedores vivos sin fila): así el nuevo dueño no colisiona con un env vivo
  que perdió su fila.
- **Release↔teardown atómico.** `wt-down`/`wt-gc`/`wt-reclaim` liberan la fila **solo tras verificar** el retiro de
  la API (`pm-wt<N>-api`) y del Oracle del slot. Una fila nunca desaparece dejando un contenedor vivo huérfano, ni
  se queda apuntando a un slot sin aprovisionar (fantasma).
- **Reclamo de fantasmas.** Una fila con `owner_pid` muerto cuyo slot **no** tiene contenedores vivos es reclamable
  por `wt-reclaim`/`wt-gc FORCE=1` **aunque el heartbeat sea fresco** (un slot nunca aprovisionado no queda pegado
  ~TTL). Se preserva intacta la protección de una dueña VIVA y de un slot vivo con heartbeat fresco (semántica
  pid+heartbeat+TTL); si la sonda de realidad no responde, el reclamo cae a solo-TTL (fail-safe, no siega en masa).
- **Guard de la frontera golden.** `goldenslice-up`/`goldenslice-relaunch`, al resolver un slot por una fila
  pre-existente, fallan ruidoso si ese slot no tiene contenedores vivos mientras hay un env **huérfano** vivo
  (discrepancia) — no deployan al slot fantasma; un tenant legítimo con su propia fila no bloquea.

**Oracle ControlPiso por slot (perezoso).** Sólo lo aprovisiona `ORACLE=1`, porque sólo lo necesita un slot con
frontend: el camino con el feature flag **OFF** ejecuta `PGE950RT` y **escribe** en ControlPiso, así que un Oracle
singleton contaminaría a las demás sesiones. `wt-up` verifica el *readiness* real (sqlplus + `maquinas_pm` poblada +
el puerto publicado coincide) en **cada** corrida, no sólo cuando crea el contenedor: un init abortado a medias deja
el contenedor `Running` con el schema incompleto. Si un slot tiene Oracle vivo y llega `ORACLE=0`, `wt-up` **adopta**
el wiring Oracle con aviso en vez de recrear la API en modo `csv` (divergencia silenciosa). El contenedor se crea con
`--restart=no`: uno de un slot ya liberado no debe resucitar tras un reinicio del docker y robarle el puerto al
siguiente dueño; la recuperación es re-correr `wt-up … ORACLE=1`.

**Teardown del Oracle.** `wt-down` destruye contenedor **y volumen** a propósito (el slot se recicla y los datos
quedaron mutados), por nombre y no por `compose down` (que depende del árbol remoto del worktree y se tragaría el
fallo), y **verifica la ausencia antes de liberar el slot**: si algo sobrevive, el slot no se libera.

**Operación (reglas).** El `health.aspx` comparte pool con la aplicación, así que **no se le hace polling en bucle**:
eso mata el *idle-timeout* de 20 min que sostiene el presupuesto de RAM del guest. El orden canónico de cierre es
`e2e-down` **antes** de `wt-down` (el primero necesita el slot que el segundo libera); si se invierte, `e2e-down`
degrada con aviso y el rescate es `make legacy-site-down SLOT=<N>`. Un slot reutilizado, o conservado con
`PM_E2E_KEEP_FRONT=1`, exige `FORCE=1` en el siguiente `e2e-up` para re-inyectar el wiring.

**Topes operativos.** Guest Windows: ~0.3–0.8 GiB por `w3wp` activo más 1–2 GiB del MSBuild en vuelo. colima
(24 GiB, headroom ~9.3 GiB): ~1.5 GiB por slot E2E (API 0.26–1.47 + XE ~0.7) ⇒ 3–4 Oracles per-slot concurrentes.

**Presupuesto real y gate de disco.** El tope que de verdad limita el aprovisionamiento no es el disco del **host**
(~6.7 TiB, irrelevante) sino el disco de la **VM colima** (`/dev/vdb1`, 80 GiB) donde viven imágenes y volúmenes:
se llenó en D6 (2026-07-05, `CREATE DATABASE pm_planning_wt3` falló al 100%). `make wt-info` imprime una sección
**Presupuesto** con las métricas reales medidas en `macdata` (disco y RAM de la VM colima, `docker system df`
reclamable, contadores del guest vía `scripts/guest-mem.sh`, y slots vivos vs `SLOTS`); `make wt-ls` añade una
línea de resumen (disco libre de la VM colima + slots vivos). Ambos verbos son best-effort: sin `REMOTE=macdata`
o con colima sin responder, la métrica degrada a `n/d` sin abortar.

`make wt-up` **rechaza aprovisionar temprano** (antes del rsync/build/seed) si el disco libre de la VM colima cae
por debajo de `PM_WT_MIN_DISK_GB` (default **6**, ≈4 slots E2E de margen; ~1.3–1.4 GB por volumen Oracle de slot),
nombrando el margen real medido y **qué disco** midió (VM colima, no host). El gate es **fail-open**: si la medición
falla (colima sin responder, parse vacío) avisa y continúa; sólo aborta con una medición exitosa por debajo del
umbral. Para forzar por encima o por debajo del default: `PM_WT_MIN_DISK_GB=<N> make wt-up WT=<folder>`.

**Higiene del disco de la VM.** El rebuild del mismo tag de imagen deja capas *dangling*; `wt-up` corre
`docker image prune -f` (**sólo** dangling) tras el build para que no saturen `/dev/vdb1`. **Nunca** se corre
`docker volume prune`: borraría los volúmenes Oracle per-slot (y cualquier otro) de sesiones vivas.

Prerrequisitos en `macdata`: el SQL compartido de nvoslabs corriendo (red `nvoslabsc3-sharedsql-dt`), `colima`
del data tier activo y las imágenes base de .NET (`sdk:10.0`/`aspnet:10.0`) disponibles.

## Comandos — orquestación E2E completa (`e2e-up` / `e2e-smoke` / `e2e-down`)

`make e2e-up` **compone** los targets de tier ya existentes y agrega el *last-mile* del camino end-to-end:
inyecta el wiring de aplicación al backend .NET 10 en el deploy del legado, activa el feature flag y corre un
**smoke funcional legacy-driven**. Usa la ruta **wt** (backend por slot, ver §Comandos — aprovisionamiento por
worktree). Es idempotente.

**Topología (todo el runtime vive en `macdata`).** La M1 es **solo el orquestador**: ejecuta `make` y maneja por SSH. El backend (contenedor de la API), el SQL compartido, el bus, el data tier y la **VM Windows del legado** corren en `macdata`. El disparo del smoke va **`macdata` → guest directo**, contra el **sitio del slot** (`172.16.128.129:8100+N`); el túnel `localhost:18100+N` que abre `legacy-launch SLOT=<N>` es **solo para acceso humano a la UI**, el smoke no lo usa.

**Puente SQL (socat).** El SQL compartido de nvoslabs se publica solo en el **loopback de `macdata`**
(`127.0.0.1:60201`), inalcanzable desde la VM (que ve a `macdata` por la pasarela NAT `172.16.128.1`). `e2e-up`
levanta un contenedor `pm-e2e-sqlbridge` (socat) unido a la red del SQL compartido, que publica
`0.0.0.0:60211 → sqlserver:1433`; así el legado lee el feature flag en `172.16.128.1:60211`. Oracle ControlPiso
ya está publicado en `0.0.0.0:1521` (alcanzable sin puente).

**Inyección en el deploy.** Sobre el `Web.config`/`connections.config` **desplegado** en el guest (la frontera:
el repo legado no conoce al wrapper), `deploy-iis.ps1` inyecta `backendBaseUrl` (appSettings) y `ConStrPm`
(reemplazo de tokens `__SQL_PM_*__` en `Config\connections.config`, con override de catálogo a `pm_planning_wt<N>`
para la ruta wt). Los valores viajan en base64 para no romper el quoting SSH→PowerShell.

**Smoke funcional (sin navegador).** El WCF `generar_programa` corre con `authentication="None"` (REST sin auth),
así que el smoke lo dispara con un POST HTTP desde `macdata`. Con el flag **ON**, el legado deriva la carga al
backend (`POST api/v1/demand/backlog/load {"plant":"RT"}`) y la respuesta trae el body del backend en
`MensajeTecnico`. Con el flag **OFF**, cae al SP Oracle `PGE950RT.PROCESOPRINCIPAL` sin tocar el backend. El smoke
discrimina ON por `MensajeTecnico` y OFF por la ausencia de órdenes nuevas (robusto al volumen de datos).

| Comando | Acción |
| --- | --- |
| `make e2e-up WT=<wt-pm> LEGACYSRC=<legacy-develop>` | Todo: `wt-up ORACLE=1` (backend **y Oracle** del slot) + puente SQL + `legacy-launch SLOT=<N>` con inyección + verificación del wiring desplegado + activar el flag ON + `e2e-net-check` + smoke. |
| `make e2e-up ... LINEA=<cod> ANOF=<aaaa> SEMF=<sem>` | Params reales del disparo (el caso OFF/Oracle los exige; el ON los ignora). |
| `make e2e-up ... FORCE=1` | Re-deploya el legado (re-inyecta el wiring; necesario si el slot se reutiliza o se conservó el sitio). |
| `make e2e-smoke WT=<wt-pm>` | Solo el smoke funcional; dispara contra el **sitio del slot** (`8100+N`). Asume `e2e-up` ya dejó todo arriba. |
| `make e2e-playwright WT=<wt-pm> LEGACYSRC=<legacy-develop>` | Runner focal de Núcleos: escenario `tnuc02`, tag `@nucleos-full`, proyecto `plant-res`, flag `subordinate-nucleos-backend` y estado `PM_E2E_NUCLEOS_FLAG_STATE`; ejecuta la matriz OFF/ON y deja evidencia por slot. |
| `make e2e-url WT=<wt-pm>` | Reimprime el **recuadro de acceso del slot** (URL del site y del túnel) y **re-levanta el túnel si murió**. Asume el ambiente ya arriba. |
| `make e2e-down WT=<wt-pm>` | Baja el túnel y el **sitio del slot**, y luego API + Oracle + BD del slot (`wt-down`). El puente y los demás singletons quedan intactos. |
| `make e2e-down ... PM_E2E_KEEP_FRONT=1` | Conserva el sitio del legado (reusarlo exige `FORCE=1` en el siguiente `e2e-up`). |
| `make e2e-down ... PM_E2E_BRIDGE_DOWN=1` | Baja también el puente `60211`. **Compartido**: bajarlo hace que los demás slots lean el flag como OFF. |
| `make e2e-oracle-counts WT=<wt-pm>` | Fotografía de las tablas que muta `PGE950RT` en el Oracle **del slot** y en el singleton `pm-local-oracle-1`, más las filas de menú de ambos. Es el instrumento de evidencia del aislamiento: se corre antes y después de una carga con el flag OFF. |

```bash
make e2e-up WT=<wt-pm-develop> LEGACYSRC=<ruta-legacy-develop> LINEA=<cod> ANOF=<aaaa> SEMF=<sem>
make e2e-smoke WT=<wt-pm-develop>     # re-corre solo el smoke
make e2e-down  WT=<wt-pm-develop>     # cierra túnel + sitio + API + Oracle del slot
```

### Runner focal Playwright de Núcleos

`e2e-playwright` falla cerrado antes de consultar un lease o tocar red si `WT`, `SOLUTION`, `LEGACYSRC`,
escenario, manifest, spec, planta, proyecto, flag, timeout o retries no satisfacen el contrato focal. `WT` puede
ser el nombre bajo `worktrees/` o su ruta absoluta; si se proporciona también `SOLUTION`, ambos deben resolver
al mismo árbol físico con `PL.PM.sln`. Un valor inexistente, exterior o divergente nunca cae al checkout central.
Los componentes `..` y cualquier symlink del `WT` se rechazan aunque terminen resolviendo dentro de
`worktrees/`. Sin `WT`, los comandos standalone existentes conservan el checkout central. Para recuperación,
`e2e-down` consulta primero la clave literal del lease: puede cerrar el site y túnel residuales aunque el árbol
del worktree ya haya sido retirado.

El orden protegido es OFF → seed `tnuc02` → spec exacto `tnuc02.spec.ts` OFF → ON → el mismo spec ON →
teardown → restauración del flag. Un fallo OFF no omite ON y cualquier fallo de seed parcial, sub-run,
teardown, restauración o descarga conserva el resultado rojo. Los comandos remotos tienen watchdog y
`PWRETRIES=0` por defecto. `INT`/`TERM` intentan teardown y restauración best-effort; `SIGKILL` no puede
atraparse, por lo que la recuperación consiste en repetir el seed idempotente y el runner bajo el mismo slot.

El stage excluye `.env`, repositorios, dependencias y resultados previos. Las credenciales viajan delimitadas
por stdin y no se persisten. `PWINSTALL=1` sólo autoriza instalar Chromium; no instala toolchains ni hace
pull de imágenes. Si el seeder necesita la imagen .NET ya cacheada, cada contenedor fallback recibe identidad
única y se detiene/retira explícitamente en éxito, fallo, timeout, `INT` o `TERM`. `WARM=1` puede invocar
`legacy-launch` para recompilar y desplegar exclusivamente al IIS
local del slot en `macdata`: esto no es un despliegue a Prolec dev y no toca servicios ni configuración remotos.
Los assets `tnuc02` se integran por separado; la ejecución física OFF/ON ocurre
únicamente cuando el ambiente focal completo esté listo.

```bash
make e2e-playwright \
  WT=<wt-pm> SOLUTION=<misma-ruta-wt-pm> LEGACYSRC=<ruta-absoluta-wt-legacy> \
  PWSCENARIO=tnuc02 PWGREP=@nucleos-full PWPROJECT=plant-res \
  PWFLAGKEY=subordinate-nucleos-backend PWSTATEENV=PM_E2E_NUCLEOS_FLAG_STATE
```

**Aislamiento del camino OFF.** `e2e-up` siempre enciende el Oracle del slot y le apunta el `conStringOracle` del
sitio, así que una carga con el flag **OFF** (que ejecuta `PGE950RT` y muta `ordenes`, `tipge951`,
`ordenes_nuevas_pm_t` y `resumen_carga_pm`) sólo toca `pm-wt<N>-oracle-1`. `pm-local-oracle-1` queda intacto.

**Verificación del wiring.** El valor efectivo de `backendBaseUrl` / `conStringOracle` / `ConStrPm` sólo existe en
el guest (el repo versiona *placeholders*). Como el `deploy` se omite cuando el health responde 200, `e2e-up` **lee**
el wiring realmente desplegado (`scripts/read-wiring.sh`) y, si diverge, re-despliega con `FORCE=1` en vez de correr
el smoke sobre el Oracle o el backend de otra sesión.

El `ORACLEPORT` del slot viaja como **variable de make** (`make legacy-launch … ORACLEPORT=<puerto>`), nunca por
entorno: `LEGACY_ENV` expande `PM_LEGACY_ORACLE_PORT=$(ORACLEPORT)` como prefijo de la línea de comando de cada
receta `legacy-*`, así que un valor pasado por env se pisaría en silencio y **todos** los frontends acabarían
apuntando al Oracle singleton `:1521`.

Prerrequisitos:

- **Fuentes en `origin/develop`**: `WT` es un worktree de `pl-programa-maestro` (con `PL.PM.sln`) y `LEGACYSRC`
  la fuente del legado, **ambos en `origin/develop`** (traen el gateway y el feature flag de Fase 1; el `main`
  local del legado o un `develop` desactualizado **no** los tienen). `e2e-up` aborta si la fuente legada no trae
  `BL/CargaBackendGateway.cs`.
- **Esquema del feature flag**: la API aplica las migraciones EF al arrancar (incluida `FeatureManagement`), así
  que con un backend de `origin/develop` la tabla/vista del flag se crean solas. `e2e.sh` además asegura el
  esquema de forma idempotente (`e2e_ensure_flag_schema`) como **red de seguridad** para builds desactualizados.
- `macdata` con el SQL compartido de nvoslabs y la VM Windows arriba; imagen `alpine/socat` (se baja sola la
  primera vez). Firewall de `macdata` que permita al guest el puerto del puente (`60211`); `e2e-up` valida
  guest→SQL y aborta con guía si no pasa.

## Variables

`make help` lista los comandos. El `Makefile` traduce variables cortas a las `PM_*` / `PM_LEGACY_*` que consumen
los drivers. Los puertos del data tier se derivan en un solo lugar (`compute_ports` en `lib/common.sh`).

| Var `make` | Familia | Default | Rol |
| --- | --- | --- | --- |
| `TARGET` | pm | `local` | `local` (colima) o `intel` (macdata vía SSH). |
| `PROFILE` | pm | `sql` | `sql` o `full` (agrega Oracle). |
| `PROJECT` | pm | `pm-local` | Nombre del proyecto compose; sólo para stacks compose manuales del data tier (**DEPRECADO** como ambiente de trabajo: la vía es el slot). |
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
| `SITEPORT` | legacy | (vacío: lo deriva el slot, `8100+N`; singleton `8080`) | Puerto IIS del legado en el guest. Fijarlo ad-hoc está **DEPRECADO**. |
| `TUNNEL` | legacy | (vacío: lo deriva el slot, `18100+N`; singleton `18080`) | Puerto local (M1) del túnel SSH → guest. Fijarlo ad-hoc está **DEPRECADO** (avisa sin bloquear). |
| `LEGACY_PROFILE` | legacy | `full` | Perfil del data tier del legado (requiere Oracle ControlPiso). |
| `DATATIER` | legacy | `1` | `0` = no gestiona el data tier (asume ya provisto). |
| `FORCE` | legacy | `0` | `1` = rebuild/redeploy aunque ya esté arriba. |
| `WT` | wt | (vacío) | Folder del worktree; clave del slot. Se autodetecta con `git rev-parse` dentro del worktree. |
| `SLOTS` | wt | `4` | `N` de slots (`0..N-1`). |
| `SOLUTION` | wt | (worktree o principal) | Raíz de la solución del worktree (contexto de build de la API). |
| `SHAREDSQL_NET` / `_HOST` / `_PORT` / `_PASSWORD` | wt | `nvoslabsc3-sharedsql-dt` / `sqlserver` / `1433` / (autodescubierta) | Conexión al SQL compartido de nvoslabs. |

Env-only (sin var `make` corta, se pasa por entorno): `PM_WT_MIN_DISK_GB` (default `6`) — umbral del gate de disco
de `wt-up` sobre la VM colima; ver §Topes operativos. Ej.: `PM_WT_MIN_DISK_GB=8 make wt-up WT=<folder>`.
`PM_WT_SLOTS_MAX` (default `8`) — cota superior del bloque de slots/túneles que escanea `wt-gc` (mantiene el túnel
singleton `18080` y el puente `60211` fuera de la detección de huérfanos). `GUEST_TURN_HOLD_WARN` (default `14400`,
segundos) — umbral del aviso de retención prolongada del turno del guest.

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

Para la vía E2E por slot (`make wt-up` / `make e2e-up`), la API corre en un contenedor **en** `macdata` y el guest la alcanza por la pasarela NAT (`172.16.128.1`), no por la IP LAN del M1: no hace falta tocar el firewall del M1. En `macdata` basta `docker` (no el SDK de .NET) y que su firewall permita la conexión entrante del guest al puerto de la API del slot (`5180+N*10`). El mapeo `/etc/hosts` del M1 sigue aplicando para `make e2e-net-check` (probes M1 → `macdata`) y para alcanzar la API por la LAN.

## Gate vs inner-loop

- **`make pm-test-clean WT=<worktree>`** es el **gate por slot**: reusa el aprovisionamiento del slot (API fresca
  + BD `pm_planning_wt<N>` + seed + Oracle/bus del slot) + `pm_ef_migrate` por el puente `60211`, y corre toda la
  suite con `PROFILE=full` (Oracle + Service Bus). Único comando para "¿pasa todo en limpio?" en el slot aislado;
  fuerza `TARGET=intel REMOTE=macdata ORACLE=1` y sustituye al singleton `pm-local` como ambiente de validación.
- **`make pm-test`** es el **inner-loop**: rápido, `PROFILE=sql`, reusa la API arriba; acota con
  `FILTER=`/`TESTPROJECT=` (o `APIFORCE=1` para relanzar la API). La suite de mensajería sólo corre con `full`.
- **`make pm-unit [WT=<worktree>] [FILTER=…]`** corre los **unit tests puros** (`*.UnitTests`): sin Docker, sin red y sin data tier; es la superficie de la evidencia **unit** por separado. El gate integral sigue siendo `make pm-test-clean WT=<worktree>`.

## Paralelismo

La unidad de aislamiento de **sesiones** es el **slot** (`make wt-up WT=<worktree>`; ver §Comandos — aprovisionamiento por worktree). `PROJECT`/`OFFSET` queda **solo** para stacks compose manuales del data tier y está **DEPRECADO como ambiente de trabajo**: `make pm-run PROJECT=… OFFSET=…` emite un warning deprecado sin bloquear. Para esos stacks manuales sigue aplicando la regla histórica: cada stack levanta su propio SQL/Oracle/API **y su propio bus** (`5672+OFFSET`); el bus **no** se comparte entre suites concurrentes (las entidades de `Config.json` son fijas y los tests drenan subscriptions, así que dos agentes contra el mismo stack competirían por los mismos mensajes) — un agente = un stack.

> **Aviso `pm-nuke`:** `legacy-*` comparte el stack `pm-local`; `pm-nuke` borra volúmenes — se re-siembra el seed, pero no lo que el legado haya escrito en vivo. Por eso **exige la confirmación `NUKE=1`** (`make pm-nuke NUKE=1`); sin ella corta con exit 2.

> **Aviso `TARGET=intel` desde varios checkouts:** `pm-run TARGET=intel` hace `rsync --delete` a rutas fijas en `macdata` (`PM_REMOTE_DIR=pm-containers`, `PM_REMOTE_SOLUTION_DIR=pm-solution`), que **no** se derivan de `PROJECT`/`OFFSET` (`e2e-backend`, que compartía ese contexto remoto, hoy es un tombstone **DEPRECADO**). Dos checkouts del sidecar (el central y un worktree) ejecutando contra `intel` en paralelo se pisan ese contexto remoto aunque usen `PROJECT` distinto. Para correrlos a la vez, además de `PROJECT`/`OFFSET` hay que fijar `PM_REMOTE_DIR` y `PM_REMOTE_SOLUTION_DIR` distintos por checkout. Los `wt-*` sí aíslan el contexto de build por slot (`pm-solution-wt<N>`).

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
- **El checkout central no acumula diffs operativos sin commitear.** Un ajuste aplicado en caliente sobre el
  central (un `prune`, un flag, un fix de script) se versiona de inmediato desde un worktree (commit + PR) o
  queda registrado como pendiente rastreable; no se deja como cambio suelto en el árbol. El central se mantiene
  en su rama de integración (`main`) sin `git status` sucio: un diff acumulado ahí lo ejecutan en silencio todas
  las sesiones que invocan `make` desde el central, con código que no está en `origin`.

## Configuración (`.env`)

`.env.example` documenta dos destinos (ver cabecera del archivo):

- **`gs-pl-pm-macops-sidecar/.env`** (en la M1) — variables `PM_*` de la familia `pm-*` (incluidas las del bus/Ln); lo carga `lib/common.sh`.
- **`~/pm-host-windows/.env`** (en `macdata`) — variables del legado (`HW`, `ART`, `VMNAME`, `ISO`, ...); lo
  cargan los scripts de build/VM que corren allá por SSH.

## Regla de oro — `artifacts/`

Todo lo descargado o generado pesado (ISO de Windows, imágenes/VMs, instaladores, caches de Packer, salidas de
build) va **exclusivamente** a `artifacts/`, que está **gitignored** (junto con `.env` y `packer/Autounattend.xml`).
El resto (scripts, packer, drivers) sí se versiona. Verificar con `git status` antes de cualquier commit.
