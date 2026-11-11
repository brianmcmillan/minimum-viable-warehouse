#!/usr/bin/env bash
# ---------------------------------------------------------------------
# ACTIVITY LOADER -- turn one staged delivery (a STATE snapshot) into
# activities. Each feed is compared with the state the streams already
# imply (v_*_state, the spec's LAST EVER), and only differences become
# activities:
#
#   first sighting   -> signed_up / added / placed_order / was_ordered
#   changed value    -> one updated_<attr> activity per changed attribute
#   re-pointed order -> order_reassigned, in the NEW owner's stream
#   tombstone        -> was_deleted / discontinued / order_deleted /
#                       removed_from_order, basis TOMBSTONE. Always.
#   absence          -> the same activities, basis FULL_ABSENCE -- under
#                       a FULL delivery ONLY. The spec says nothing about
#                       deletes; this is the shared rule filling the gap.
#   unchanged        -> NOTHING. A restatement is not an activity.
#
# `ts` is event time where the source has one (signup_date, placed_at)
# and the extract date the change was OBSERVED otherwise. The source
# never says when Alice changed her email, only when we saw it.
#
# Activities are written in a fixed ORDER BY, and _seq / activity_id
# continue from the stream's maximum, so an ordered replay of the
# archive reproduces every activity exactly. No UPDATE, no DELETE: the
# triggers would refuse them.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"

params="$(sql_scalar "SELECT batch_ts||'|'||file_id FROM act_load_params;")"
[ -n "$params" ] || { echo "FATAL: act_load_params is empty" >&2; exit 1; }
echo "==> Deriving activities (batch_ts=${params%%|*}, record_source=${params#*|})"

# emit <stream> <label> <select returning: ts, customer, activity,
#      feature_json, revenue_impact, link, k>   (k = deterministic sort key)
emit() {
  local stream="$1" label="$2" sel="$3" pfx base before after
  case "$stream" in customer_stream) pfx=cs;; product_stream) pfx=ps;; esac
  base="$(sql_int "$(sql_scalar "SELECT COALESCE(MAX(_seq),0) FROM $stream;")")"
  sql_run "
    WITH x(ts, customer, activity, feature_json, revenue_impact, link, k) AS ($sel)
    INSERT INTO $stream (activity_id, ts, customer, activity, feature_json,
                         revenue_impact, link, _seq, _load_ts, _record_source)
    SELECT printf('$pfx-%06d', $base + ROW_NUMBER() OVER (ORDER BY x.k, x.activity, x.ts)),
           x.ts, x.customer, x.activity, x.feature_json, x.revenue_impact, x.link,
           $base + ROW_NUMBER() OVER (ORDER BY x.k, x.activity, x.ts),
           p.batch_ts, p.file_id
    FROM x CROSS JOIN act_load_params p;"
  after="$(sql_scalar "SELECT COALESCE(MAX(_seq),0) FROM $stream;")"
  [ "$after" -eq "$base" ] || printf "    %-15s %-22s: %s activit(ies)\n" "$stream" "$label" "$((after - base))"
}

# ------------------------------- CRM.CUSTOMER -------------------------------
if [ "$(feed_rows stg_customer_l1)" -gt 0 ]; then
  mode="$(feed_mode stg_customer_l1)"; echo "    CRM.CUSTOMER   [$mode]"

  emit customer_stream signed_up "
    SELECT datetime(COALESCE(s.signup_date, s.extract_dt)) AS ts, s.customer_id AS customer,
           'signed_up' AS activity,
           json_object('full_name', s.full_name, 'email_addr', s.email_addr,
                       'signup_date', s.signup_date) AS feature_json,
           NULL AS revenue_impact, NULL AS link, s.customer_id AS k
    FROM v_stg_customer_l2 s
    WHERE s.op = 'UPSERT'
      AND NOT EXISTS (SELECT 1 FROM v_customer_state c WHERE c.customer_id = s.customer_id)"

  emit customer_stream restored "
    SELECT datetime(s.extract_dt), s.customer_id, 'restored',
           json_object('full_name', s.full_name, 'email_addr', s.email_addr,
                       'signup_date', s.signup_date), NULL, NULL, s.customer_id
    FROM v_stg_customer_l2 s JOIN v_customer_state c ON c.customer_id = s.customer_id
    WHERE s.op = 'UPSERT' AND c.alive = 0"

  emit customer_stream 'updated_<attr>' "
    SELECT datetime(s.extract_dt) AS ts, s.customer_id AS customer, 'updated_name' AS activity,
           json_object('full_name', s.full_name) AS feature_json, NULL AS revenue_impact,
           NULL AS link, s.customer_id AS k
    FROM v_stg_customer_l2 s JOIN v_customer_state c ON c.customer_id = s.customer_id
    WHERE s.op = 'UPSERT' AND c.alive = 1 AND s.full_name IS NOT c.full_name
    UNION ALL
    SELECT datetime(s.extract_dt), s.customer_id, 'updated_email',
           json_object('email_addr', s.email_addr), NULL, NULL, s.customer_id
    FROM v_stg_customer_l2 s JOIN v_customer_state c ON c.customer_id = s.customer_id
    WHERE s.op = 'UPSERT' AND c.alive = 1 AND s.email_addr IS NOT c.email_addr
    UNION ALL
    SELECT datetime(s.extract_dt), s.customer_id, 'updated_signup_date',
           json_object('signup_date', s.signup_date), NULL, NULL, s.customer_id
    FROM v_stg_customer_l2 s JOIN v_customer_state c ON c.customer_id = s.customer_id
    WHERE s.op = 'UPSERT' AND c.alive = 1 AND s.signup_date IS NOT c.signup_date"

  emit customer_stream 'was_deleted (tombstone)' "
    SELECT datetime(s.extract_dt), s.customer_id, 'was_deleted',
           json_object('basis', 'TOMBSTONE'), NULL, NULL, s.customer_id
    FROM v_stg_customer_l2 s JOIN v_customer_state c ON c.customer_id = s.customer_id
    WHERE s.op = 'DELETE' AND c.alive = 1"

  if [ "$mode" = "FULL" ]; then
    emit customer_stream 'was_deleted (absence)' "
      SELECT (SELECT datetime(MAX(extract_dt)) FROM stg_customer_l1), c.customer_id, 'was_deleted',
             json_object('basis', 'FULL_ABSENCE'), NULL, NULL, c.customer_id
      FROM v_customer_state c
      WHERE c.alive = 1
        AND NOT EXISTS (SELECT 1 FROM v_stg_customer_l2 s WHERE s.customer_id = c.customer_id)"
  fi
fi

# ------------------------------- PIM.PRODUCT --------------------------------
if [ "$(feed_rows stg_product_l1)" -gt 0 ]; then
  mode="$(feed_mode stg_product_l1)"; echo "    PIM.PRODUCT    [$mode]"

  emit product_stream added "
    SELECT datetime(s.extract_dt) AS ts, s.sku AS customer, 'added' AS activity,
           json_object('prod_name', s.prod_name, 'price', s.price, 'currency', s.currency) AS feature_json,
           NULL AS revenue_impact, NULL AS link, s.sku AS k
    FROM v_stg_product_l2 s
    WHERE s.op = 'UPSERT'
      AND NOT EXISTS (SELECT 1 FROM v_product_state p WHERE p.sku = s.sku)"

  emit product_stream restored "
    SELECT datetime(s.extract_dt), s.sku, 'restored',
           json_object('prod_name', s.prod_name, 'price', s.price, 'currency', s.currency),
           NULL, NULL, s.sku
    FROM v_stg_product_l2 s JOIN v_product_state p ON p.sku = s.sku
    WHERE s.op = 'UPSERT' AND p.alive = 0"

  emit product_stream 'updated_<attr>' "
    SELECT datetime(s.extract_dt) AS ts, s.sku AS customer, 'updated_name' AS activity,
           json_object('prod_name', s.prod_name) AS feature_json, NULL AS revenue_impact,
           NULL AS link, s.sku AS k
    FROM v_stg_product_l2 s JOIN v_product_state p ON p.sku = s.sku
    WHERE s.op = 'UPSERT' AND p.alive = 1 AND s.prod_name IS NOT p.prod_name
    UNION ALL
    SELECT datetime(s.extract_dt), s.sku, 'updated_price',
           json_object('price', s.price), NULL, NULL, s.sku
    FROM v_stg_product_l2 s JOIN v_product_state p ON p.sku = s.sku
    WHERE s.op = 'UPSERT' AND p.alive = 1 AND s.price IS NOT p.price
    UNION ALL
    SELECT datetime(s.extract_dt), s.sku, 'updated_currency',
           json_object('currency', s.currency), NULL, NULL, s.sku
    FROM v_stg_product_l2 s JOIN v_product_state p ON p.sku = s.sku
    WHERE s.op = 'UPSERT' AND p.alive = 1 AND s.currency IS NOT p.currency"

  emit product_stream 'discontinued (tombstone)' "
    SELECT datetime(s.extract_dt), s.sku, 'discontinued',
           json_object('basis', 'TOMBSTONE'), NULL, NULL, s.sku
    FROM v_stg_product_l2 s JOIN v_product_state p ON p.sku = s.sku
    WHERE s.op = 'DELETE' AND p.alive = 1"

  if [ "$mode" = "FULL" ]; then
    emit product_stream 'discontinued (absence)' "
      SELECT (SELECT datetime(MAX(extract_dt)) FROM stg_product_l1), p.sku, 'discontinued',
             json_object('basis', 'FULL_ABSENCE'), NULL, NULL, p.sku
      FROM v_product_state p
      WHERE p.alive = 1
        AND NOT EXISTS (SELECT 1 FROM v_stg_product_l2 s WHERE s.sku = p.sku)"
  fi
fi

# --------------------------------- OMS.ORDER --------------------------------
# Order activities live in the OWNER's customer stream; link = order_ref.
if [ "$(feed_rows stg_order_l1)" -gt 0 ]; then
  mode="$(feed_mode stg_order_l1)"; echo "    OMS.ORDER      [$mode]"

  emit customer_stream placed_order "
    SELECT datetime(COALESCE(s.placed_at, s.extract_dt)) AS ts, s.customer_ref AS customer,
           'placed_order' AS activity,
           json_object('status', s.status, 'amount', s.amount, 'currency', s.currency,
                       'placed_at', s.placed_at) AS feature_json,
           s.amount AS revenue_impact, s.order_ref AS link, s.order_ref AS k
    FROM v_stg_order_l2 s
    WHERE s.op = 'UPSERT'
      AND NOT EXISTS (SELECT 1 FROM v_order_state o WHERE o.order_ref = s.order_ref)"

  emit customer_stream order_restored "
    SELECT datetime(s.extract_dt), s.customer_ref, 'order_restored',
           json_object('status', s.status, 'amount', s.amount, 'currency', s.currency,
                       'placed_at', s.placed_at), NULL, s.order_ref, s.order_ref
    FROM v_stg_order_l2 s JOIN v_order_state o ON o.order_ref = s.order_ref
    WHERE s.op = 'UPSERT' AND o.alive = 0"

  emit customer_stream order_reassigned "
    SELECT datetime(s.extract_dt), s.customer_ref, 'order_reassigned',
           json_object('from_customer', o.customer_ref), NULL, s.order_ref, s.order_ref
    FROM v_stg_order_l2 s JOIN v_order_state o ON o.order_ref = s.order_ref
    WHERE s.op = 'UPSERT' AND o.alive = 1 AND s.customer_ref IS NOT o.customer_ref"

  emit customer_stream order_updated "
    SELECT datetime(s.extract_dt), s.customer_ref, 'order_updated',
           json_object('status', s.status, 'amount', s.amount, 'currency', s.currency,
                       'placed_at', s.placed_at), NULL, s.order_ref, s.order_ref
    FROM v_stg_order_l2 s JOIN v_order_state o ON o.order_ref = s.order_ref
    WHERE s.op = 'UPSERT' AND o.alive = 1
      AND (s.status IS NOT o.status OR s.amount IS NOT o.amount
           OR s.currency IS NOT o.currency OR s.placed_at IS NOT o.placed_at)"

  emit customer_stream 'order_deleted (tombstone)' "
    SELECT datetime(s.extract_dt), o.customer_ref, 'order_deleted',
           json_object('basis', 'TOMBSTONE'), NULL, s.order_ref, s.order_ref
    FROM v_stg_order_l2 s JOIN v_order_state o ON o.order_ref = s.order_ref
    WHERE s.op = 'DELETE' AND o.alive = 1"

  if [ "$mode" = "FULL" ]; then
    emit customer_stream 'order_deleted (absence)' "
      SELECT (SELECT datetime(MAX(extract_dt)) FROM stg_order_l1), o.customer_ref, 'order_deleted',
             json_object('basis', 'FULL_ABSENCE'), NULL, o.order_ref, o.order_ref
      FROM v_order_state o
      WHERE o.alive = 1
        AND NOT EXISTS (SELECT 1 FROM v_stg_order_l2 s WHERE s.order_ref = o.order_ref)"
  fi
fi

# ------------------------------ OMS.ORDER_LINE ------------------------------
# An order line is something that happens to a PRODUCT: was_ordered in the
# product stream, link = order_ref, ts = the order's placed_at (event
# time). A line re-added after removal is stamped when it was observed.
if [ "$(feed_rows stg_order_line_l1)" -gt 0 ]; then
  mode="$(feed_mode stg_order_line_l1)"; echo "    OMS.ORDER_LINE [$mode]"

  emit product_stream was_ordered "
    SELECT CASE WHEN l.order_ref IS NULL
                THEN datetime(COALESCE(o.placed_at, s.extract_dt))
                ELSE datetime(s.extract_dt) END AS ts,
           s.sku AS customer, 'was_ordered' AS activity, '{}' AS feature_json,
           NULL AS revenue_impact, s.order_ref AS link, s.sku || '|' || s.order_ref AS k
    FROM v_stg_order_line_l2 s
    LEFT JOIN v_order_line_state l ON l.order_ref = s.order_ref AND l.sku = s.sku
    LEFT JOIN v_order_state o ON o.order_ref = s.order_ref
    WHERE s.op = 'UPSERT' AND (l.order_ref IS NULL OR l.on_order = 0)"

  emit product_stream 'removed_from_order (tombstone)' "
    SELECT datetime(s.extract_dt), s.sku, 'removed_from_order',
           json_object('basis', 'TOMBSTONE'), NULL, s.order_ref, s.sku || '|' || s.order_ref
    FROM v_stg_order_line_l2 s
    JOIN v_order_line_state l ON l.order_ref = s.order_ref AND l.sku = s.sku
    WHERE s.op = 'DELETE' AND l.on_order = 1"

  if [ "$mode" = "FULL" ]; then
    emit product_stream 'removed_from_order (absence)' "
      SELECT (SELECT datetime(MAX(extract_dt)) FROM stg_order_line_l1), l.sku, 'removed_from_order',
             json_object('basis', 'FULL_ABSENCE'), NULL, l.order_ref, l.sku || '|' || l.order_ref
      FROM v_order_line_state l
      WHERE l.on_order = 1
        AND NOT EXISTS (SELECT 1 FROM v_stg_order_line_l2 s
                        WHERE s.order_ref = l.order_ref AND s.sku = l.sku)"
  fi
fi
