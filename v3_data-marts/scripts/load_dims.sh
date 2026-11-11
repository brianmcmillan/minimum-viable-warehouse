#!/usr/bin/env bash
# ---------------------------------------------------------------------
# DIMENSION LOADER -- SCD Type 2, mode-aware.
#
# Per SCD2 dimension, three steps, in a fixed order:
#
#   1. EXPIRE (an UPDATE -- this mart mutates, its siblings do not) the
#      current row of every version-worthy business key:
#        * upserted with different diff_str, or upserted while its
#          current version is a deleted-marker (resurrection)
#        * tombstoned (op='DELETE'), ALWAYS
#        * absent from the delivery, ONLY when the delivery is FULL
#   2. INSERT new active versions for the upserted keys that now lack a
#      current row. A NOCHANGE key kept its current row in step 1, so it
#      inserts nothing -- the same quiet no-op as the sibling demos.
#   3. INSERT deleted-marker versions (is_deleted=1, attributes carried
#      from the version just expired) for the delete-worthy keys.
#
# DETERMINISM: surrogate keys are rowids, and every INSERT..SELECT here
# carries ORDER BY <business key> -- SQLite assigns rowids in that
# order, so ordered archive replay reproduces every surrogate key. The
# statement ORDER (2 before 3) is part of that contract; do not swap.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
echo "==> Loading dimensions (SCD2, batch_ts=$BATCH_TS)"
q_bts="$(sql_quote "$BATCH_TS")"

# ---- dim_customer -----------------------------------------------------
if [ "$(feed_rows stg_customer_l1)" -gt 0 ]; then
  mode="$(feed_mode stg_customer_l1)"

  ABS=""
  [ "$mode" = "FULL" ] && ABS="OR (c.is_deleted=0 AND c.customer_ref NOT IN
        (SELECT customer_bk FROM v_stg_customer_l2))"

  # 1. expire
  sql_run "
    UPDATE dim_customer SET row_exp_ts='$q_bts', is_current=0
    WHERE is_current=1 AND customer_ref IN (
      SELECT c.customer_ref FROM dim_customer c
      LEFT JOIN v_stg_customer_l2 s ON s.customer_bk = c.customer_ref
      WHERE c.is_current=1 AND (
            (s.op='UPSERT' AND (s.diff_str <> c.diff_str OR c.is_deleted=1))
         OR (s.op='DELETE' AND c.is_deleted=0)
         $ABS ));"

  # 2. new active versions (new keys + keys whose current was expired)
  sql_run "
    INSERT INTO dim_customer(customer_ref, customer_name, email, signup_date,
                             diff_str, row_eff_ts)
    SELECT s.customer_bk, s.full_name, s.email_addr, s.signup_date,
           s.diff_str, s.ldts
    FROM v_stg_customer_l2 s
    WHERE s.op='UPSERT'
      AND NOT EXISTS (SELECT 1 FROM dim_customer c
                      WHERE c.customer_ref=s.customer_bk AND c.is_current=1)
    ORDER BY s.customer_bk;"

  # 3. deleted-marker versions: expired THIS batch, active, not re-upserted
  sql_run "
    INSERT INTO dim_customer(customer_ref, customer_name, email, signup_date,
                             diff_str, row_eff_ts, is_deleted)
    SELECT c.customer_ref, c.customer_name, c.email, c.signup_date,
           c.diff_str, '$q_bts', 1
    FROM dim_customer c
    WHERE c.row_exp_ts='$q_bts' AND c.is_deleted=0
      AND c.customer_ref NOT IN (SELECT customer_bk FROM v_stg_customer_l2
                                 WHERE op='UPSERT')
    ORDER BY c.customer_ref;"

  n="$(sql_scalar "SELECT COUNT(*) FROM dim_customer WHERE row_eff_ts='$q_bts';")"
  printf "    %-13s [%-11s]: %s new version(s)\n" "dim_customer" "$mode" "$n"
fi

# ---- dim_product ------------------------------------------------------
if [ "$(feed_rows stg_product_l1)" -gt 0 ]; then
  mode="$(feed_mode stg_product_l1)"

  ABS=""
  [ "$mode" = "FULL" ] && ABS="OR (c.is_deleted=0 AND c.sku NOT IN
        (SELECT product_bk FROM v_stg_product_l2))"

  sql_run "
    UPDATE dim_product SET row_exp_ts='$q_bts', is_current=0
    WHERE is_current=1 AND sku IN (
      SELECT c.sku FROM dim_product c
      LEFT JOIN v_stg_product_l2 s ON s.product_bk = c.sku
      WHERE c.is_current=1 AND (
            (s.op='UPSERT' AND (s.diff_str <> c.diff_str OR c.is_deleted=1))
         OR (s.op='DELETE' AND c.is_deleted=0)
         $ABS ));"

  sql_run "
    INSERT INTO dim_product(sku, product_name, price, currency,
                            diff_str, row_eff_ts)
    SELECT s.product_bk, s.prod_name, s.price, s.currency, s.diff_str, s.ldts
    FROM v_stg_product_l2 s
    WHERE s.op='UPSERT'
      AND NOT EXISTS (SELECT 1 FROM dim_product c
                      WHERE c.sku=s.product_bk AND c.is_current=1)
    ORDER BY s.product_bk;"

  sql_run "
    INSERT INTO dim_product(sku, product_name, price, currency,
                            diff_str, row_eff_ts, is_deleted)
    SELECT c.sku, c.product_name, c.price, c.currency, c.diff_str, '$q_bts', 1
    FROM dim_product c
    WHERE c.row_exp_ts='$q_bts' AND c.is_deleted=0
      AND c.sku NOT IN (SELECT product_bk FROM v_stg_product_l2 WHERE op='UPSERT')
    ORDER BY c.sku;"

  n="$(sql_scalar "SELECT COUNT(*) FROM dim_product WHERE row_eff_ts='$q_bts';")"
  printf "    %-13s [%-11s]: %s new version(s)\n" "dim_product" "$mode" "$n"
fi
