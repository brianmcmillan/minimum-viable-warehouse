-- =====================================================================
-- DV2.0 :: STAGE LEVEL 2  (views: system columns + intra-batch dedup)
-- ---------------------------------------------------------------------
-- The training package computes hash keys and hashdiffs here. This
-- implementation uses NATURAL business keys -- hash keys are an optional
-- optimisation in the standard (parallel loads, MPP joins), not a
-- requirement, and at single-writer SQLite scale they buy nothing.
--
-- diff_str is EXACTLY the string a hash-keyed implementation would feed
-- into md5(...) for the hashdiff: the descriptive attributes, trimmed,
-- NULL-coalesced, pipe-delimited. Comparing it to the newest satellite
-- row's diff_str is the whole change-detection mechanism.
--
-- Intra-batch dedup: if a delivery carries the same business key twice,
-- the newest row by extract_dt wins (rowid breaks exact ties) -- the same
-- recency rule as the Focal demo's landing dedup.
--
-- rsrc: record source in dot form, per the standard, for row lineage.
-- =====================================================================

CREATE VIEW v_stg_customer_l2 AS
SELECT rsrc, ldts, customer_bk, full_name, email_addr, signup_date,
       COALESCE(TRIM(full_name),'')  || '|' ||
       COALESCE(TRIM(email_addr),'') || '|' ||
       COALESCE(TRIM(signup_date),'')      AS diff_str,
       op, load_mode, extract_dt
FROM (
  SELECT 'CRM.CUSTOMER'                    AS rsrc,
         (SELECT batch_ts FROM dv_load_params) AS ldts,
         TRIM(customer_id)                 AS customer_bk,
         full_name, email_addr, signup_date, op, load_mode, extract_dt,
         ROW_NUMBER() OVER (PARTITION BY TRIM(customer_id)
                            ORDER BY extract_dt DESC, rowid DESC) AS rn
  FROM stg_customer_l1
) WHERE rn = 1;

CREATE VIEW v_stg_product_l2 AS
SELECT rsrc, ldts, product_bk, prod_name, price, currency,
       COALESCE(TRIM(prod_name),'')            || '|' ||
       COALESCE(TRIM(CAST(price AS TEXT)),'')  || '|' ||
       COALESCE(TRIM(currency),'')             AS diff_str,
       op, load_mode, extract_dt
FROM (
  SELECT 'PIM.PRODUCT'                     AS rsrc,
         (SELECT batch_ts FROM dv_load_params) AS ldts,
         TRIM(sku)                         AS product_bk,
         prod_name, price, currency, op, load_mode, extract_dt,
         ROW_NUMBER() OVER (PARTITION BY TRIM(sku)
                            ORDER BY extract_dt DESC, rowid DESC) AS rn
  FROM stg_product_l1
) WHERE rn = 1;

CREATE VIEW v_stg_order_l2 AS
SELECT rsrc, ldts, order_bk, customer_bk, status, amount, currency, placed_at,
       COALESCE(TRIM(status),'')               || '|' ||
       COALESCE(TRIM(CAST(amount AS TEXT)),'') || '|' ||
       COALESCE(TRIM(currency),'')             || '|' ||
       COALESCE(TRIM(placed_at),'')            AS diff_str,
       op, load_mode, extract_dt
FROM (
  SELECT 'OMS.ORDER'                       AS rsrc,
         (SELECT batch_ts FROM dv_load_params) AS ldts,
         TRIM(order_ref)                   AS order_bk,
         TRIM(customer_ref)                AS customer_bk,
         status, amount, currency, placed_at, op, load_mode, extract_dt,
         ROW_NUMBER() OVER (PARTITION BY TRIM(order_ref)
                            ORDER BY extract_dt DESC, rowid DESC) AS rn
  FROM stg_order_l1
) WHERE rn = 1;

CREATE VIEW v_stg_order_line_l2 AS
SELECT rsrc, ldts, order_bk, product_bk, op, load_mode, extract_dt
FROM (
  SELECT 'OMS.ORDER_LINE'                  AS rsrc,
         (SELECT batch_ts FROM dv_load_params) AS ldts,
         TRIM(order_ref)                   AS order_bk,
         TRIM(sku)                         AS product_bk,
         op, load_mode, extract_dt,
         ROW_NUMBER() OVER (PARTITION BY TRIM(order_ref), TRIM(sku)
                            ORDER BY extract_dt DESC, rowid DESC) AS rn
  FROM stg_order_line_l1
) WHERE rn = 1;
