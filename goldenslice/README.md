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

## `make goldenslice-up` (sin parámetros, D18) — `up.sh`

Un comando levanta el ambiente E2E completo sembrado con la golden slice, accesible desde la M1:

1. Worktrees canónicos `gs_pm_goldenslice` + `gs_legacy_goldenslice` en `origin/develop` (`git stash` + `checkout`, preserva cambios locales).
2. `make wt-up` (slot + Oracle propio); el slot se auto-asigna y se deriva por `wt_slot_lookup`.
3. `make goldenslice-seed SLOT=<N>` (Oracle multi-owner + recompila + LN aislada UTF-16).
4. `PM_WT_LN_DB=pm_gs_ln_wt<N> make e2e-up`: recrea el pm-api apuntando a la **LN golden** (no el `pm_erpln106` compartido; el guard ve la golden completa y no siembra handcrafted), levanta el frontend IIS con su wiring, activa el flag `carga-backend/RES` e imprime las URLs (backend + legado).

Reimprime la URL de un ambiente ya arriba: `make e2e-url WT=gs_pm_goldenslice`.

## `make goldenslice-relaunch WT=<worktree>` — `relaunch.sh`

Actualiza, recompila y relanza AMBAS apps (pm-api .NET + legado ASP.NET) con la última `origin/develop` **SIN rehacer el seed**. Reusa el Oracle/LN golden y la BD planning `pm_planning_wt<N>` ya sembradas/cargadas por un `goldenslice-up` previo: recrea el pm-api contra las MISMAS BD, redespliega el legado, reactiva el flag e imprime las URLs. Es `goldenslice-up` MENOS el `goldenslice-seed`, los loaders (`catalog-load`/`intake-load`) y el registro del menú UBO. `WT=` es opcional (default `gs_pm_goldenslice`).

**Precondición**: el slot del worktree ya existe (Oracle golden + LN golden + BD planning cargada). Si no, corta con error sugiriendo `make goldenslice-up`. El slot se deriva del registro (`wt_slot_lookup`).

1. Worktrees canónicos pm (`gs_pm_goldenslice`) + legado (`gs_legacy_goldenslice`) a `origin/develop` (`git stash` + `checkout`, preserva cambios locales, D18).
2. Recrea el pm-api contra las MISMAS BD (LN golden + planning ya cargada) vía `make wt-up ORACLE=1` con `PM_WT_SKIP_PLANNING_SEED=1` (no re-siembra planning) y el env final del golden (LN golden + Tools ON). NO llama `goldenslice-seed`: el Oracle/LN golden y la BD planning persisten intactos en el motor compartido.
3. Recompila y redespliega el legado con la última `develop` vía `make e2e-up` con `PM_E2E_FORCE=1` (fuerza `legacy-build`+`deploy`) + `PM_E2E_SKIP_WTUP=1` (el pm-api ya lo recreó el paso 2) + `PM_E2E_SKIP_SMOKE=1` (ambiente arriba; smoke aparte con `make e2e-smoke`). Reactiva el flag `carga-backend/RES` e imprime las URLs.
4. Reimprime el recuadro de acceso (URLs desde M1). NO seed, NO `catalog-load`/`intake-load`, NO menú (ya registrado). Si el pull trae migraciones EF que tocan el schema de catálogos, AVISA (no recarga en silencio, R4).

Los tiempos por fase se persisten en `artifacts/goldenslice-timing/goldenslice-relaunch-<UTC>.log`.
