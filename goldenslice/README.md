# goldenslice — seed local desde datos íntegros de PROD (ventana FY2026 sem 18–25)

Materializa una **golden slice** (corte real de PROD, nueva y SEPARADA de los seeds de `containers/`) para sembrar un slot y correr el intake RES punta a punta con datos reales. Solicitud `260718-1636_feat_all_datos-prod-integros-seed-oracle-ln-e2e`.

## Contenido de la slice (RES)

- **Oracle `PGE_CTRLPISO`** — firme/plan/órdenes/bobinas/backlog/INFODIS/calendario + 21 catálogos (29 tablas).
- **Oracle `DIS_CTP`** — tablas de diseño (4).
- **LN `erpln106`** cía 115/116 — 16 tablas (transaccional windowed + masters item/order-scoped).
- Excluidos (no-RES, verificado): `CATBAAN` (cía 006/007), `PROD_INF` (planta TRI). Ver decision-log D17.

## Generador

`generate.py --src <dir-extraccion> --out build/` lee los CSV extraídos (`oracle/<owner>/…`, `ln/<base>/c<cia>*.csv`) + el DDL (`ddl/*_columns.csv`) y emite en `build/`:

- `oracle/<OWNER>/00-create-user.sql` — crea el owner como esquema propio (D6).
- `oracle/<OWNER>/01-create-tables.sql` — `CREATE TABLE` desde el DDL (tipos reales; columnas Baan `$` citadas).
- `oracle/<OWNER>/<TABLA>.ctl` — sqlldr direct-path (multi-INFILE por chunk; columnas `DATE` con `TO_DATE(SUBSTR(...,1,19),'YYYY-MM-DD HH24:MI:SS')`).
- `ln/01-create-tables.sql` — `CREATE TABLE` LN (SQL Server; `datetime2` por los 7 dígitos fraccionales).
- `ln/02-bulk-insert.sql` — `BULK INSERT` por tabla/chunk (`FORMAT='CSV', FIRSTROW=2`).

## Reglas de chunk (aprendidas en vivo)

- Oracle: cap `maxRowsHard=10000` por request ⇒ chunk por semana / rango fecha / `ORA_HASH mod N`.
- LN: el binding es `maxBodyBytes=245760` (gzip), no las filas ⇒ tablas anchas (`ttdsls401`, `ttisfc001`, `INFODIS`) van por `ABS(CHECKSUM(<key>)) % N` / `ORA_HASH(<key>) mod N` con N alto. **Detectar `[TOO_LARGE]`**: un grep de `rows=` matchea el conteo en la línea de error y da falso positivo; validar por `[OK]` y por conteo de filas del CSV.

## Carga (`seed-slot.sh`, `make goldenslice-seed SLOT=<N>`)

- **Oracle**: por owner, `CREATE USER` + `CREATE TABLE` + `sqlldr` (CSV concatenado por tabla, `CHARACTERSET AL32UTF8`). Tras cargar, `DBMS_UTILITY.COMPILE_SCHEMA ×2` recompila los packages (el DROP+CREATE los invalida; deja VALID el camino del intake, quedan INVALID los que referencian objetos fuera del subset RES).
- **LN** (BD aislada `pm_gs_ln_wt<N>`): `CREATE TABLE` + `BULK INSERT`. Los CSV se convierten a **UTF-16LE + BOM** en el staging remoto y el loader usa `DATAFILETYPE='widechar', ROWTERMINATOR='\n'`: BULK INSERT en SQL Server Linux **no soporta `CODEPAGE`** y con CSV UTF-8 truncaría los `nvarchar(N)` acentuados por bytes.
- **Tablas LN schema-only** (`LN_SCHEMA_ONLY` en `generate.py`): `ttcibd001115`, `ttxpcf925116` se emiten VACÍAS (CREATE sin BULK). El intake las consulta pero su scope RES es 0 filas en PROD (fiel); además satisfacen el guard de completitud LN del sidecar.
- **Knob `STEP=oracle|ln|all`** para re-seed parcial.

## `make goldenslice-up` — `up.sh`

Un comando levanta el ambiente E2E completo sembrado con la golden slice, accesible desde la M1:

1. Worktrees canónicos `gs_pm_goldenslice` + `gs_legacy_goldenslice` en `origin/develop` (`git stash` + `checkout`, preserva cambios locales).
2. `make wt-up` (slot + Oracle propio); el slot se auto-asigna y se deriva por `wt_slot_lookup`.
3. `make goldenslice-seed SLOT=<N> BUILD=build-wt<N>` (Oracle multi-owner + recompila + LN aislada UTF-16). El build de la golden slice se regenera **por slot** (`build-wt<N>`, gitignored) para que varios golden concurrentes no compartan el mismo directorio.
4. `PM_WT_LN_DB=pm_gs_ln_wt<N> make e2e-up`: recrea el pm-api apuntando a la **LN golden** (no el `pm_erpln106` compartido; el guard ve la golden completa y no siembra handcrafted), levanta el frontend IIS con su wiring, activa el flag `carga-backend/RES` e imprime las URLs (backend + legado).

Al cierre imprime SIEMPRE un **banner garantizado** (independiente de `make e2e-url`, que puede colgarse) con: slot, URL del legado (`http://localhost:$((18100+SLOT))/ProgramaMaestroLN/`), URL del backend y el comando exacto de reuso (`make goldenslice-relaunch WT=… LEGACYWT=…`). Reimprime la URL de un ambiente ya arriba: `make e2e-url WT=gs_pm_goldenslice`.

### Modo worktree y multi-golden — `WT=<pm-wt> LEGACYWT=<legacy-wt>`

`make goldenslice-up WT=<pm-wt> LEGACYWT=<legacy-wt>` corre el **código de esos worktrees TAL CUAL**, sin tocar su git (sin `fetch`/`stash`/`checkout`): usa el branch actual + los cambios sin commitear (el usuario maneja git por su cuenta, incluido `git pull --rebase origin develop`). Ambas perillas son **obligatorias juntas** (no se adivina el par pm/legado); los worktrees deben pre-existir (créalos con `new-worktree`). Sin `WT`/`LEGACYWT` el comportamiento es **idéntico al canónico** (worktrees desechables en `origin/develop`).

Como el slot se deriva del **nombre** del worktree pm, dos golden con nombres distintos caen en slots aislados y corren **en paralelo** sin pisarse (data tier + app + URL propios). El techo de golden concurrentes lo fija `PM_WT_SLOTS` (default 8) y la RAM/disco de la VM colima (cada golden = 1 Oracle + 1 API + 1 site IIS); el build del legado sigue serializando en el `guest-lock` global.

## `make goldenslice-relaunch WT=<pm-wt> LEGACYWT=<legacy-wt>` — `relaunch.sh`

Actualiza, recompila y relanza AMBAS apps (pm-api .NET + legado ASP.NET) **SIN rehacer el seed**. Reusa el Oracle/LN golden y la BD planning `pm_planning_wt<N>` ya sembradas/cargadas por un `goldenslice-up` previo: recrea el pm-api contra las MISMAS BD, redespliega el legado, reactiva el flag e imprime las URLs. Es `goldenslice-up` MENOS el `goldenslice-seed`, los loaders (`catalog-load`/`intake-load`) y el registro del menú UBO.

Perillas simétricas a `goldenslice-up`: sin argumentos usa los worktrees canónicos en `origin/develop`; con `WT=<pm-wt> LEGACYWT=<legacy-wt>` (**modo worktree**, ambas obligatorias) relanza el **código de esos worktrees tal cual**, sin tocar git.

**Precondición**: el slot del worktree ya existe (Oracle golden + LN golden + BD planning cargada). Si no, corta con error sugiriendo `make goldenslice-up`. El slot se deriva del registro (`wt_slot_lookup`).

1. Worktrees a `origin/develop` (canónico) o **tal cual** (modo worktree, sin `fetch`/`stash`/`checkout`).
2. Recrea el pm-api contra las MISMAS BD (LN golden + planning ya cargada) vía `make wt-up ORACLE=1` con `PM_WT_SKIP_PLANNING_SEED=1` (no re-siembra planning) y el env final del golden (LN golden + Tools ON). NO llama `goldenslice-seed`: el Oracle/LN golden y la BD planning persisten intactos en el motor compartido.
3. Recompila y redespliega el legado vía `make e2e-up` con `PM_E2E_SKIP_WTUP=1` (el pm-api ya lo recreó el paso 2) + `PM_E2E_SKIP_SMOKE=1` (ambiente arriba; smoke aparte con `make e2e-smoke`). El rebuild del legado (`PM_E2E_FORCE`) se decide así: `FORCE=1` manual lo fuerza; en **modo worktree** se fuerza SIEMPRE (no hay SHA before/after que diffear porque golden no mueve HEAD), con escape `LEGACYBUILD=0` para omitirlo; en modo canónico se fuerza solo si el SHA del worktree legado cambió. Reactiva el flag `carga-backend/RES` e imprime las URLs.
4. Imprime el **banner garantizado** (igual que `goldenslice-up`). NO seed, NO `catalog-load`/`intake-load`, NO menú (ya registrado). Si el pull (modo canónico) trae migraciones EF que tocan el schema de catálogos, fuerza el re-warm de catálogos.

Los tiempos por fase se persisten en `artifacts/goldenslice-timing/goldenslice-relaunch-<UTC>.log`.
