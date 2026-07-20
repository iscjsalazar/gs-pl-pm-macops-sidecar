#!/usr/bin/env python3
"""Genera el esquema (DDL) y los loaders bulk de la golden slice desde los CSV extraidos de PROD.

Entrada:  un directorio de extraccion (data CSV por owner/tabla + DDL de columnas).
Salida:   build/ con, por owner Oracle, CREATE USER + CREATE TABLE + un .ctl sqlldr por tabla;
          y para LN (SQL Server), CREATE TABLE + BULK INSERT por tabla.

No toca los seeds existentes de containers/. Solo lee los CSV extraidos y emite artefactos nuevos.
"""
import csv, os, glob, sys, argparse, re

# ---- mapeo de tipos ----------------------------------------------------------

def ora_type(dt, length, prec, scale):
    dt = (dt or "").upper()
    if dt in ("VARCHAR2", "VARCHAR", "CHAR", "NVARCHAR2", "NCHAR"):
        n = int(length) if length else 4000
        n = min(max(n, 1), 4000)
        return f'VARCHAR2({n})'
    if dt == "NUMBER":
        if prec:
            return f'NUMBER({int(prec)},{int(scale or 0)})'
        return 'NUMBER'
    if dt in ("FLOAT", "BINARY_FLOAT", "BINARY_DOUBLE"):
        return 'FLOAT'
    if dt == "DATE":
        return 'DATE'
    if dt.startswith("TIMESTAMP"):
        return 'TIMESTAMP'
    if dt in ("CLOB", "NCLOB", "LONG"):
        return 'CLOB'
    if dt in ("BLOB", "RAW", "LONG RAW"):
        return 'CLOB'  # se guarda como texto en la slice
    return 'VARCHAR2(4000)'


def ss_type(dt, length, prec, scale):
    dt = (dt or "").lower()
    if dt in ("varchar", "char", "nvarchar", "nchar", "text", "ntext"):
        n = int(length) if length not in (None, "", "-1") else -1
        base = "nvarchar" if dt.startswith("n") else "varchar"
        return f'{base}(max)' if (n == -1 or n > 4000) else f'{base}({max(n,1)})'
    if dt in ("int", "bigint", "smallint", "tinyint", "bit"):
        return dt
    if dt in ("decimal", "numeric"):
        return f'decimal({int(prec or 18)},{int(scale or 0)})'
    if dt in ("float", "real"):
        return 'float'
    if dt in ("datetime", "datetime2", "smalldatetime", "date", "time"):
        return 'datetime2'  # los CSV traen 7 dígitos fraccionales (datetime solo 3)
    if dt in ("money", "smallmoney"):
        return 'decimal(19,4)'
    return 'nvarchar(max)'


# ---- lectura de DDL ----------------------------------------------------------

def read_oracle_ddl(path):
    """-> {table: [(col, type_sql, is_date)]}"""
    tables = {}
    with open(path, newline='') as f:
        for r in csv.DictReader(f):
            t = r['TABLE_NAME']
            col = r['COLUMN_NAME']
            typ = ora_type(r['DATA_TYPE'], r.get('DATA_LENGTH'), r.get('DATA_PRECISION'), r.get('DATA_SCALE'))
            is_date = typ in ('DATE', 'TIMESTAMP')
            tables.setdefault(t, []).append((col, typ, is_date))
    return tables


def read_ln_ddl(path):
    tables = {}
    with open(path, newline='') as f:
        for r in csv.DictReader(f):
            t = r['TABLE_NAME']
            col = r['COLUMN_NAME']
            typ = ss_type(r['DATA_TYPE'], r.get('CHARACTER_MAXIMUM_LENGTH'), r.get('NUMERIC_PRECISION'), r.get('NUMERIC_SCALE'))
            tables.setdefault(t, []).append((col, typ))
    return tables


# ---- localizar CSV de datos por tabla ---------------------------------------

def data_csvs(root, subpath, table):
    """Devuelve la lista de CSV de datos de una tabla (maneja chunks en subdir y archivo suelto)."""
    cands = []
    d = os.path.join(root, subpath, table)
    if os.path.isdir(d):
        cands += sorted(glob.glob(os.path.join(d, '*.csv')))
    for p in (os.path.join(root, subpath, '_catalogs', table + '.csv'),
              os.path.join(root, subpath, table + '.csv')):
        if os.path.isfile(p):
            cands.append(p)
    # excluir superseded/_meta
    return [c for c in cands if '_superseded' not in c and '/_' not in os.path.relpath(c, root).replace(os.sep, '/')[ -len(os.path.basename(c))-2:]]


# ---- generacion Oracle -------------------------------------------------------

def q(col):  # quote identifier (Baan $ / palabras reservadas)
    return '"' + col + '"'


def gen_oracle(owner, tables, root, subpath, out):
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, f'00-create-user.sql'), 'w') as f:
        f.write(f"-- golden slice: owner {owner}\n")
        f.write(f"DECLARE v NUMBER; BEGIN SELECT COUNT(*) INTO v FROM all_users WHERE username='{owner}';\n")
        f.write(f"  IF v=0 THEN EXECUTE IMMEDIATE 'CREATE USER {owner} IDENTIFIED BY goldenslice'; END IF; END;\n/\n")
        f.write(f"GRANT CONNECT,RESOURCE,UNLIMITED TABLESPACE TO {owner};\n")
    ddl = open(os.path.join(out, '01-create-tables.sql'), 'w')
    manifest = []
    for t, cols in sorted(tables.items()):
        csvs = data_csvs(root, subpath, t)
        if not csvs:
            continue
        # CREATE TABLE
        coldefs = ",\n  ".join(f'{q(c)} {ty}' for c, ty, _ in cols)
        ddl.write(f'\nBEGIN EXECUTE IMMEDIATE \'DROP TABLE {owner}.{q(t)} CASCADE CONSTRAINTS\'; EXCEPTION WHEN OTHERS THEN NULL; END;\n/\n')
        ddl.write(f'CREATE TABLE {owner}.{q(t)} (\n  {coldefs}\n);\n')
        # .ctl (usa el header del primer CSV para ordenar columnas)
        header = open(csvs[0], newline='').readline().strip().split(',')
        by_name = {c.upper(): (c, ty, isd) for c, ty, isd in cols}
        ctl_cols = []
        for h in header:
            hu = h.strip().upper()
            if hu in by_name:
                c, ty, isd = by_name[hu]
                if isd:
                    ctl_cols.append(f'{q(c)} "TO_DATE(SUBSTR(:{q(c)[1:-1]},1,19),\'YYYY-MM-DD HH24:MI:SS\')"')
                else:
                    ctl_cols.append(f'{q(c)} CHAR(4000)')
            else:
                ctl_cols.append(f'"{h.strip()}" FILLER CHAR(4000)')
        # Concatena los chunks en UN CSV (un solo header) co-locado con el .ctl: sqlldr multi-INFILE con
        # OPTIONS(SKIP=1) solo salta el header del PRIMER archivo -> los headers de los demas chunks entrarian
        # como datos. Concatenar evita ese bug (y da un solo INFILE con SKIP=1).
        combined = os.path.join(out, f'{t}.csv')
        with open(combined, 'w') as cf:
            for i, c in enumerate(csvs):
                with open(c, encoding='utf-8', errors='replace') as srcf:
                    lines = srcf.readlines()
                cf.writelines(lines if i == 0 else lines[1:])
        infiles = f"INFILE '{t}.csv'"
        ctl = (f"OPTIONS (SKIP=1, ERRORS=100000)\nLOAD DATA\nCHARACTERSET AL32UTF8\n{infiles}\n"
               f'INTO TABLE {owner}.{q(t)}\nAPPEND\nFIELDS TERMINATED BY \',\' OPTIONALLY ENCLOSED BY \'"\'\n'
               f"TRAILING NULLCOLS\n(\n  " + ",\n  ".join(ctl_cols) + "\n)\n")
        open(os.path.join(out, f'{t}.ctl'), 'w').write(ctl)
        manifest.append((t, len(csvs)))
    ddl.close()
    return manifest


# ---- generacion LN (SQL Server) ---------------------------------------------

def ln_data_csvs(root, table):
    """DDL table = base + 3-digit company (twhinp100115) -> ln/<base>/c<company>*.csv"""
    base, comp = table[:-3], table[-3:]
    d = os.path.join(root, 'ln', base)
    if not os.path.isdir(d):
        return []
    return sorted(glob.glob(os.path.join(d, f'c{comp}*.csv')))


# Tablas LN que el intake CONSULTA pero cuyo scope RES es 0 filas en PROD (verificado por COUNT contra la
# ventana): deben EXISTIR (si no, la query truena con "invalid object name") pero van VACIAS (fiel a PROD).
#   ttxpcf925116: antimagnetico (ItemLnGateway); 0 filas para los items de la ventana en PROD.
# Satisface ademas el guard de completitud WT_LN_TABLES del sidecar (presencia por nombre).
#
# ttcibd001115 ya NO pertenece a este conjunto: es el maestro de articulos en la compania FISICA 115
# (t_item = CIAF), que BacklogLnGateway INNER-joina; materializarla vacia colapsaba el backlog a 0 lineas.
# PROD confirma que la cia 115 cubre el 100% de los items de la ventana (6485/6485); se siembra desde
# ln/ttcibd001/c115*.csv (extraccion item-scoped). Sin ese CSV la tabla no se emite y WT_LN_TABLES falla
# ruidoso (un LN vacio es una ALARMA, no un estado fiel), en vez de re-crear el defecto de 0 lineas.
LN_SCHEMA_ONLY = {'ttxpcf925116'}


def gen_ln(tables, root, out):
    os.makedirs(out, exist_ok=True)
    ddl = open(os.path.join(out, '01-create-tables.sql'), 'w')
    load = open(os.path.join(out, '02-bulk-insert.sql'), 'w')
    ddl.write("-- golden slice LN (erpln106)\n")
    manifest = []
    for t, cols in sorted(tables.items()):
        csvs = ln_data_csvs(root, t)
        if not csvs and t not in LN_SCHEMA_ONLY:
            continue
        coldefs = ",\n  ".join(f'[{c}] {ty} NULL' for c, ty in cols)
        ddl.write(f"\nIF OBJECT_ID(N'[dbo].[{t}]',N'U') IS NOT NULL DROP TABLE [dbo].[{t}];\nGO\n")
        ddl.write(f"CREATE TABLE [dbo].[{t}] (\n  {coldefs}\n);\nGO\n")
        base = t[:-3]  # los CSV viven en ln/<base>/; el basename (c116.csv) colisiona entre tablas -> califica por subdir
        for c in csvs:
            # DATAFILETYPE='widechar' + archivo UTF-16LE: BULK INSERT en SQL Server Linux NO soporta CODEPAGE,
            # y con el CSV en UTF-8 el bulk cuenta bytes y trunca los nvarchar(N) en textos acentuados (la 'N'
            # de DISENO son 2 bytes) -> filas rechazadas (con MAXERRORS=10 la tabla entera aborta a 0). El
            # archivo va UTF-16LE (lo convierte seed-slot.sh) y ROWTERMINATOR='\n' matchea el LF ancho.
            load.write(f"BULK INSERT [dbo].[{t}] FROM '$(LN_CSV_DIR)/{base}/{os.path.basename(c)}' "
                       f"WITH (FORMAT='CSV',DATAFILETYPE='widechar',FIELDTERMINATOR=',',ROWTERMINATOR='\\n',FIELDQUOTE='\"',FIRSTROW=2,TABLOCK);\nGO\n")
        manifest.append((t, len(csvs)))
    ddl.close(); load.close()
    return manifest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', required=True, help='dir de extraccion (con oracle/, ln/, ddl/)')
    ap.add_argument('--out', required=True, help='dir de salida build/')
    a = ap.parse_args()
    ora_pge = read_oracle_ddl(os.path.join(a.src, 'ddl', 'oracle_pge_ctrlpiso_columns.csv'))
    ora_dis = read_oracle_ddl(os.path.join(a.src, 'ddl', 'oracle_dis_ctp_columns.csv'))
    ln = read_ln_ddl(os.path.join(a.src, 'ddl', 'ln_erpln106_columns.csv'))
    m1 = gen_oracle('PGE_CTRLPISO', ora_pge, a.src, 'oracle/PGE_CTRLPISO', os.path.join(a.out, 'oracle', 'PGE_CTRLPISO'))
    m2 = gen_oracle('DIS_CTP', ora_dis, a.src, 'oracle/DIS_CTP', os.path.join(a.out, 'oracle', 'DIS_CTP'))
    m3 = gen_ln(ln, a.src, os.path.join(a.out, 'ln'))
    print(f"PGE_CTRLPISO: {len(m1)} tablas -> .ctl")
    print(f"DIS_CTP:      {len(m2)} tablas -> .ctl")
    print(f"LN erpln106:  {len(m3)} tablas -> BULK INSERT")
    for label, m in (('PGE_CTRLPISO', m1), ('DIS_CTP', m2), ('LN', m3)):
        for t, n in m:
            print(f"  {label:12} {t:32} {n} csv")
    # WARNING de skip silencioso: un CSV en _catalogs/ cuyo stem no corresponde a una tabla generada NO se
    # siembra (le paso a CALENDARIO_SYS_2024-2029.csv, que dejo el CALENDARIO del contenedor con fixtures 9G).
    # data_csvs busca _catalogs/<TABLA>.csv exacto; si el nombre trae sufijos, moverlo a un subdir <TABLA>/.
    for owner, subpath, m in (('PGE_CTRLPISO', 'oracle/PGE_CTRLPISO', m1), ('DIS_CTP', 'oracle/DIS_CTP', m2)):
        gen = {t for t, _ in m}
        catdir = os.path.join(a.src, subpath, '_catalogs')
        if os.path.isdir(catdir):
            for c in sorted(glob.glob(os.path.join(catdir, '*.csv'))):
                if os.path.basename(c)[:-4] not in gen:
                    print(f"  AVISO [{owner}]: {os.path.basename(c)} en _catalogs/ NO matchea ninguna tabla generada "
                          f"-> NO se siembra (movelo a un subdir <TABLA>/ para que se cargue)")


if __name__ == '__main__':
    main()
