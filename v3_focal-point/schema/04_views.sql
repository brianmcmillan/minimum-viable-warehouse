-- =====================================================================
-- SEMANTIC VIEWS -- give MEANING back to the generic data layer.
-- ---------------------------------------------------------------------
-- The physical rows only make sense once type_key is joined back to the
-- metadata. These views do exactly that: they are the "read model".
-- Change a label in meta_atomic_context and every view reflects it
-- instantly -- no data migration, no DDL. That is dynamic semantic
-- correction in action.
-- =====================================================================

-- Current active descriptor per (key, atomic context) for each entity.
CREATE VIEW v_customer_desc_current AS
SELECT customer_key, type_key, val_str, val_num, uom, sta_tmstp, end_tmstp, eff_tmstp
FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_key,type_key
             ORDER BY eff_tmstp DESC, ver_tmstp DESC) rn FROM customer_desc)
WHERE rn=1 AND row_st='Y';

CREATE VIEW v_product_desc_current AS
SELECT product_key, type_key, val_str, val_num, uom, sta_tmstp, end_tmstp, eff_tmstp
FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY product_key,type_key
             ORDER BY eff_tmstp DESC, ver_tmstp DESC) rn FROM product_desc)
WHERE rn=1 AND row_st='Y';

CREATE VIEW v_order_desc_current AS
SELECT order_key, type_key, val_str, val_num, uom, sta_tmstp, end_tmstp, eff_tmstp
FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY order_key,type_key
             ORDER BY eff_tmstp DESC, ver_tmstp DESC) rn FROM order_desc)
WHERE rn=1 AND row_st='Y';

-- ---- Wide, business-friendly reconstructions (pivot by type_key) ----
CREATE VIEW v_customer AS
SELECT f.customer_key,
       (SELECT customer_idfr FROM customer_idfr i
         WHERE i.customer_key=f.customer_key AND i.row_st='Y' LIMIT 1) AS customer_ref,
       MAX(CASE WHEN d.type_key=10 THEN d.val_str  END) AS customer_name,
       MAX(CASE WHEN d.type_key=11 THEN d.val_str  END) AS email,
       MAX(CASE WHEN d.type_key=12 THEN d.sta_tmstp END) AS signup_date
FROM customer_focal f
LEFT JOIN v_customer_desc_current d ON d.customer_key=f.customer_key
GROUP BY f.customer_key;

CREATE VIEW v_product AS
SELECT f.product_key,
       (SELECT product_idfr FROM product_idfr i
         WHERE i.product_key=f.product_key AND i.row_st='Y' LIMIT 1) AS sku,
       MAX(CASE WHEN d.type_key=20 THEN d.val_str END) AS product_name,
       MAX(CASE WHEN d.type_key=21 THEN d.val_num END) AS price,
       MAX(CASE WHEN d.type_key=21 THEN d.uom     END) AS currency
FROM product_focal f
LEFT JOIN v_product_desc_current d ON d.product_key=f.product_key
GROUP BY f.product_key;

CREATE VIEW v_order AS
SELECT f.order_key,
       (SELECT order_idfr FROM order_idfr i
         WHERE i.order_key=f.order_key AND i.row_st='Y' LIMIT 1) AS order_ref,
       MAX(CASE WHEN d.type_key=30 THEN d.val_str  END) AS status,
       MAX(CASE WHEN d.type_key=31 THEN d.val_num  END) AS amount,
       MAX(CASE WHEN d.type_key=31 THEN d.uom      END) AS currency,
       MAX(CASE WHEN d.type_key=32 THEN d.sta_tmstp END) AS placed_at,
       (SELECT c.customer_name FROM order_customer_x x
          JOIN v_customer c ON c.customer_key=x.customer_key
         WHERE x.order_key=f.order_key AND x.type_key=90 AND x.row_st='Y' LIMIT 1) AS placed_by
FROM order_focal f
LEFT JOIN v_order_desc_current d ON d.order_key=f.order_key
GROUP BY f.order_key;

-- ---- Self-describing "everything" view: proves meaning lives in metadata ----
-- Every current fact in the warehouse, decoded via the semantic key.
CREATE VIEW v_all_facts AS
SELECT ac.entity_id, k.ek AS entity_key, ac.context_name,
       ac.type_key, k.val_str, k.val_num, k.uom, k.sta_tmstp, k.eff_tmstp
FROM (
  SELECT 'CUSTOMER' e, customer_key ek, type_key, val_str, val_num, uom, sta_tmstp, eff_tmstp FROM v_customer_desc_current
  UNION ALL
  SELECT 'PRODUCT', product_key, type_key, val_str, val_num, uom, sta_tmstp, eff_tmstp FROM v_product_desc_current
  UNION ALL
  SELECT 'ORDER', order_key, type_key, val_str, val_num, uom, sta_tmstp, eff_tmstp FROM v_order_desc_current
) k
JOIN meta_atomic_context ac ON ac.type_key=k.type_key;

-- ---- Full history of a single atomic context (bi-temporal timeline) ----
CREATE VIEW v_order_status_history AS
SELECT (SELECT order_idfr FROM order_idfr i WHERE i.order_key=d.order_key AND i.row_st='Y' LIMIT 1) AS order_ref,
       d.order_key, d.eff_tmstp, d.ver_tmstp, d.row_st, d.val_str AS status
FROM order_desc d WHERE d.type_key=30
ORDER BY d.order_key, d.eff_tmstp, d.ver_tmstp;

-- ---- Operational lineage: which pipeline SQL produced each fact ----
CREATE VIEW v_lineage AS
SELECT 'ORDER' AS entity, d.order_key AS entity_key, ac.context_name,
       d.row_st, d.eff_tmstp, p.pipeline, p.batch_ts
FROM order_desc d
JOIN meta_atomic_context ac ON ac.type_key=d.type_key
JOIN meta_procinst p ON p.inst_key=d.inst_key;
