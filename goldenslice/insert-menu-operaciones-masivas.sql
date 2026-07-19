-- Alta de menu: Administracion -> Operaciones Masivas -> 7 paginas UserBulkOperations.  Planta RES.
-- NO hace COMMIT. Revisar el SELECT del final y luego COMMIT; (o ROLLBACK;).
--
-- Por que no es mas corto de lo que se ve:
--   NLSSORT(...BINARY_AI) : en Prolec dev el item es 'Administración' CON acento (en el slot local va sin
--                           acento). El match insensible a acentos funciona en ambos.
--   NOT EXISTS            : sin el, correrlo dos veces inserta un SEGUNDO contenedor y el 2o INSERT revienta
--                           con ORA-00001 (verificado en el slot). Con el, re-correr inserta 0 filas.
--   ACTIVO=1, PAG_DINAMICA=0 : NO pueden ir NULL. El lector del menu hace int.Parse sin guard: un NULL rompe
--                           el render del menu COMPLETO, no solo el item.
--   TO_CHAR(...)          : GRUPO_POSICION es VARCHAR2, POSICION es NUMBER.

-- 1) Contenedor "Operaciones Masivas", colgando de Administracion.
INSERT INTO pge_ctrlpiso.menu_contenido
  (id_contenido, posicion, descripcion, pagina, path_imagen, estilo,
   usuario, fecha_creacion, activo, pag_dinamica, grupo_posicion, colsort)
SELECT m.id_contenido,
       (SELECT MAX(posicion) + 1 FROM pge_ctrlpiso.menu_contenido WHERE id_contenido = m.id_contenido),
       'Operaciones Masivas', NULL, NULL, 'Utils().imagenConf',
       'MIGRACION_UBO', SYSDATE, 1, 0,
       TO_CHAR(a.posicion),
       (SELECT MAX(colsort) + 1 FROM pge_ctrlpiso.menu_contenido WHERE id_contenido = m.id_contenido)
FROM   pge_ctrlpiso.menu m
JOIN   pge_ctrlpiso.menu_contenido a
  ON   a.id_contenido = m.id_contenido
 AND   NVL(a.grupo_posicion, '0') = '0'
 AND   NLSSORT(TRIM(a.descripcion), 'NLS_SORT=BINARY_AI') = NLSSORT('Administracion', 'NLS_SORT=BINARY_AI')
WHERE  m.id_menu = 'PROGMAESTRO'
AND    m.planta  = 'RES'
AND    NOT EXISTS (SELECT 1 FROM pge_ctrlpiso.menu_contenido x
                   WHERE  x.id_contenido = m.id_contenido
                   AND    TRIM(x.descripcion) = 'Operaciones Masivas');

-- 2) Las 7 paginas, colgando del contenedor.
INSERT INTO pge_ctrlpiso.menu_contenido
  (id_contenido, posicion, descripcion, pagina, path_imagen, estilo,
   usuario, fecha_creacion, activo, pag_dinamica, grupo_posicion, colsort)
SELECT om.id_contenido,
       (SELECT MAX(posicion) FROM pge_ctrlpiso.menu_contenido WHERE id_contenido = om.id_contenido) + p.n,
       p.descripcion, p.pagina, NULL, 'Utils().imagenCargaPlanta',
       'MIGRACION_UBO', SYSDATE, 1, 0,
       TO_CHAR(om.posicion),
       (SELECT MAX(colsort) FROM pge_ctrlpiso.menu_contenido WHERE id_contenido = om.id_contenido) + p.n
FROM   (SELECT c.id_contenido, c.posicion
        FROM   pge_ctrlpiso.menu m
        JOIN   pge_ctrlpiso.menu_contenido c ON c.id_contenido = m.id_contenido
        WHERE  m.id_menu = 'PROGMAESTRO'
        AND    m.planta  = 'RES'
        AND    TRIM(c.descripcion) = 'Operaciones Masivas') om
CROSS  JOIN (
  SELECT 1 n, 'Carga de Ordenes (LN)'      descripcion, 'UserBulkOperations/CargaOrdenesLN.aspx'          pagina FROM dual UNION ALL
  SELECT 2,   'Carga de Fechas (Excel)',                'UserBulkOperations/CargaFechasExcel.aspx'               FROM dual UNION ALL
  SELECT 3,   'Consulta Programa Maestro',              'UserBulkOperations/ConsultaProgramaMaestro.aspx'        FROM dual UNION ALL
  SELECT 4,   'Ordenes sin Estatus (LN)',               'UserBulkOperations/OrdenesSinEstatusLN.aspx'            FROM dual UNION ALL
  SELECT 5,   'Resumen de Carga',                       'UserBulkOperations/ResumenCarga.aspx'                   FROM dual UNION ALL
  SELECT 6,   'Backlog (LN)',                           'UserBulkOperations/BacklogLN.aspx'                      FROM dual UNION ALL
  SELECT 7,   'Sincronizacion de Diseno',               'UserBulkOperations/SincronizacionDiseno.aspx'           FROM dual
) p
WHERE  NOT EXISTS (SELECT 1 FROM pge_ctrlpiso.menu_contenido y
                   WHERE  y.id_contenido = om.id_contenido
                   AND    y.pagina = p.pagina);

-- Verificar: 1 contenedor (grp = POSICION de Administracion) + 7 paginas (grp = POSICION del contenedor).
SELECT posicion, grupo_posicion, descripcion, pagina, activo, pag_dinamica
FROM   pge_ctrlpiso.menu_contenido
WHERE  id_contenido = (SELECT id_contenido FROM pge_ctrlpiso.menu
                       WHERE id_menu = 'PROGMAESTRO' AND planta = 'RES')
AND   (TRIM(descripcion) = 'Operaciones Masivas' OR pagina LIKE 'UserBulkOperations/%')
ORDER  BY TO_NUMBER(grupo_posicion), colsort;
