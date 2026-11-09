#!/usr/bin/env bash
# =====================================================================
# Unified Star Schema test suite -- the shared delivery scenarios against
# an insert-only core, plus the USS-specific behaviours: tables without
# foreign keys, one bridge stage per table, transitive keys, measures on
# their own stage (no fan trap), every member present (no chasm trap),
# a materialised decode, the re-point re-derived, and exact rebuild.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/uss_test).db}"
export ARCHIVE_DB="${DB%.db}_archive.db"
PASS=0; FAIL=0; FEED_N=0; SKIPPED=0
LOGDIR="$(mktemp -d)"; trap 'rm -rf "$LOGDIR"' EXIT

q(){  local out rc=0; out="$("$SQLITE" "$DB" "$1" 2>&1)" || rc=$?
      [ "$rc" -eq 0 ] || { printf "  \033[31mSQL ERROR\033[0m %s\n    %s\n" "$out" "$1" >&2
                           printf '<SQL-ERROR>'; return 0; }
      printf '%s' "$out"; }
aq(){ local out rc=0
      out="$("$SQLITE" -cmd "ATTACH DATABASE '$ARCHIVE_DB' AS arch" "$DB" "$1" 2>&1)" || rc=$?
      [ "$rc" -eq 0 ] || { printf "  \033[31mSQL ERROR\033[0m %s\n    %s\n" "$out" "$1" >&2
                           printf '<SQL-ERROR>'; return 0; }
      printf '%s' "$out"; }
ck(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1";
      else FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s  (got '%s', expected '%s')\n" "$1" "$2" "$3"; fi; }
ck_abort(){ local label="$1" db="$2" sql="$3" want="$4" out
      out="$("$SQLITE" "$db" "$sql" 2>&1)"
      case "$out" in *"$want"*) PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$label";;
        *) FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s  (got '%s')\n" "$label" "$out";; esac; }

census(){ q "SELECT group_concat(t||'='||n,' ') FROM (
    SELECT 1 o,'cust' t,COUNT(*) n FROM core_customer
    UNION ALL SELECT 2,'prod',  COUNT(*) FROM core_product
    UNION ALL SELECT 3,'ord',   COUNT(*) FROM core_order
    UNION ALL SELECT 4,'line',  COUNT(*) FROM core_order_line
    ORDER BY o);"; }

bridge(){ q "SELECT stage, COALESCE(_key_customer,''), COALESCE(_key_product,''),
                    COALESCE(_key_orders,''), COALESCE(_key_order_line,''),
                    COALESCE(order_amount,''), COALESCE(line_count,'')
             FROM _bridge ORDER BY 1,2,3,4,5;"; }

snap(){ q "
  SELECT 'c', customer_id, load_ts, COALESCE(full_name,'')||'/'||COALESCE(email_addr,''),
         change_type||'/'||COALESCE(delete_basis,'')||'/'||record_source FROM core_customer
  UNION ALL
  SELECT 'p', sku, load_ts, COALESCE(prod_name,'')||'/'||COALESCE(price,''),
         change_type||'/'||COALESCE(delete_basis,'')||'/'||record_source FROM core_product
  UNION ALL
  SELECT 'o', order_ref, load_ts, COALESCE(customer_ref,'')||'/'||COALESCE(status,'')||'/'||COALESCE(amount,''),
         change_type||'/'||COALESCE(delete_basis,'')||'/'||record_source FROM core_order
  UNION ALL
  SELECT 'l', order_ref||'+'||sku, load_ts, '',
         change_type||'/'||COALESCE(delete_basis,'')||'/'||record_source FROM core_order_line
  ORDER BY 1,2,3;"; bridge; }

# One bridge row per table row, stage by stage -- the USS invariant.
stages_ok(){ q "SELECT
    (SELECT COUNT(*) FROM _bridge WHERE stage='Customer')   = (SELECT COUNT(*) FROM customer)
AND (SELECT COUNT(*) FROM _bridge WHERE stage='Product')    = (SELECT COUNT(*) FROM product)
AND (SELECT COUNT(*) FROM _bridge WHERE stage='Orders')     = (SELECT COUNT(*) FROM orders)
AND (SELECT COUNT(*) FROM _bridge WHERE stage='Order line') = (SELECT COUNT(*) FROM order_line)"; }

feed(){ local src="$1" file_id="$2" ts="$3" rc=0 log dir="${4:-$PROJ/source}"
  FEED_N=$((FEED_N+1)); log="$LOGDIR/$FEED_N-$file_id.log"
  BATCH_TS="$ts" "$PROJ/scripts/load_feed.sh" "$dir/$src" "$file_id" >"$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf "\n  \033[31mABORT\033[0m load_feed.sh exited %d at delivery %s (%s)\n" "$rc" "$file_id" "$src"
    sed 's/^/  | /' "$log"
    printf "\n  %d passed, %d failed before the abort.\n" "$PASS" "$FAIL"; exit 1
  fi
  if grep -q 'SKIP duplicate' "$log"; then SKIPPED=1; else SKIPPED=0; fi
  ck "[$file_id] manifest: recorded exactly once" \
     "$(aq "SELECT COUNT(*) FROM arch.loaded_files WHERE file_id='$file_id'")" "1"
  [ "$SKIPPED" -eq 0 ] && ck "[$file_id] manifest: COMPLETE after the loaders" \
     "$(aq "SELECT status FROM arch.loaded_files WHERE file_id='$file_id'")" "COMPLETE"
  [ "$SKIPPED" -eq 0 ] && ck "[$file_id] USS refreshed for this delivery" \
     "$(q "SELECT record_source FROM uss_refresh")" "$file_id"
  ck "[$file_id] stage blank after delivery" \
     "$(q "SELECT (SELECT COUNT(*) FROM stg_customer_l1)+(SELECT COUNT(*) FROM stg_product_l1)
                +(SELECT COUNT(*) FROM stg_order_l1)+(SELECT COUNT(*) FROM stg_order_line_l1)")" "0"
  ck "[$file_id] bridge: one stage row per table row" "$(stages_ok)" "1"; }

rows(){ q "SELECT COUNT(*) FROM core_customer WHERE customer_id='$1'"; }
latest_c(){ q "SELECT change_type||'/'||COALESCE(delete_basis,'') FROM v_latest__customer WHERE customer_id='$1'"; }
fan(){ q "SELECT naive_join_total||'/'||bridge_total||'/'||true_total FROM v_fan_trap"; }

echo "== Fresh db + archive =="; rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null

echo; echo "== The shape: tables without foreign keys, every key on the bridge =="
ck "each USS table has exactly one _key_ column: its own" \
   "$(q "SELECT group_concat(t||'='||n,' ') FROM (SELECT t, (SELECT COUNT(*) FROM pragma_table_info(t)
           WHERE name LIKE '\_key\_%' ESCAPE '\\') n FROM (SELECT 'customer' t UNION ALL SELECT 'product'
           UNION ALL SELECT 'orders' UNION ALL SELECT 'order_line') ORDER BY t)")" \
   "customer=1 order_line=1 orders=1 product=1"
ck "orders has no customer_ref: the relationship lives on the bridge" \
   "$(q "SELECT COUNT(*) FROM pragma_table_info('orders') WHERE name LIKE '%customer%'")" "0"
ck "the bridge carries every table's key" \
   "$(q "SELECT group_concat(name,',') FROM (SELECT name FROM pragma_table_info('_bridge')
         WHERE name LIKE '\_key\_%' ESCAPE '\\' ORDER BY name)")" \
   "_key_customer,_key_order_line,_key_orders,_key_product"

echo; echo "== D0: FULL baseline =="
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
ck "baseline: 2 customers, 3 products, 2 orders current" \
   "$(q "SELECT (SELECT COUNT(*) FROM v_customer)||'/'||(SELECT COUNT(*) FROM v_product)||'/'||(SELECT COUNT(*) FROM v_order)")" "2/3/2"
ck "baseline: C001 email v1" "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@example.com"
ck "bridge: 2+3+2+3 = 10 rows across 4 stages" \
   "$(q "SELECT COUNT(*)||'/'||COUNT(DISTINCT stage) FROM _bridge")" "10/4"
ck "core keeps raw 'P'; the USS table holds PENDING (+ raw code for lineage)" \
   "$(q "SELECT (SELECT status FROM core_order WHERE order_ref='O-100')||'/'||
                (SELECT status||'/'||status_code FROM orders WHERE order_ref='O-100')")" "P/PENDING/P"
ck "TRANSITIVE KEY: an order line carries its order's customer" \
   "$(q "SELECT _key_customer FROM _bridge WHERE _key_order_line='O-100|SKU-1'")" "C001"
ck "measures sit on their own stage only" \
   "$(q "SELECT (SELECT COUNT(*) FROM _bridge WHERE order_amount IS NOT NULL AND stage<>'Orders')
             + (SELECT COUNT(*) FROM _bridge WHERE line_count   IS NOT NULL AND stage<>'Order line')")" "0"
ck "FAN TRAP: naive join double counts O-100; the bridge does not" "$(fan)" "78.48/48.99/48.99"
ck "one query, two grains: C001 has 1 order, 29.49, 2 lines" \
   "$(q "SELECT n_orders||'/'||order_amount||'/'||n_lines FROM v_sales_by_customer WHERE customer_ref='C001'")" "1/29.49/2"
ck "SKU-3 never ordered but still on the star (Product stage)" \
   "$(q "SELECT n_orders||'/'||n_lines FROM v_sales_by_product WHERE sku='SKU-3'")" "0/0"
ck "lineage: every core row names its delivery" \
   "$(q "SELECT group_concat(DISTINCT record_source) FROM core_order_line")" "B0"

echo; echo "== D1: CRM 14-day INCREMENTAL window (C001 changed; C002 absent) =="
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
ck "core: C001 now 2 rows, the new one an UPDATE" \
   "$(q "SELECT COUNT(*)||'/'||(SELECT change_type FROM v_latest__customer WHERE customer_id='C001')
         FROM core_customer WHERE customer_id='C001'")" "2/UPDATE"
ck "insert-only: C001's first core row still holds the old email" \
   "$(q "SELECT email_addr FROM core_customer WHERE customer_id='C001' AND load_ts='2026-02-05 08:00:00'")" "alice@example.com"
ck "USS shows the new email" "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@newmail.com"
ck "INCREMENTAL: C002 NOT deleted (60-day stale)" \
   "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "1"
ck "INCREMENTAL: C002 zero churn" "$(rows C002)" "1"
ck "v_order resolves placed_by through the bridge" \
   "$(q "SELECT placed_by FROM v_order WHERE order_ref='O-100'")" "Alice Smith"

echo; echo "== D2: PIM FULL snapshot (SKU-3 discontinued) =="
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
ck "FULL: SKU-3 core row DELETE, basis FULL_ABSENCE" \
   "$(q "SELECT change_type||'/'||delete_basis FROM v_latest__product WHERE sku='SKU-3'")" "DELETE/FULL_ABSENCE"
ck "FULL: SKU-3 gone from product and from the Product stage" \
   "$(q "SELECT (SELECT COUNT(*) FROM v_product WHERE sku='SKU-3')+(SELECT COUNT(*) FROM _bridge WHERE _key_product='SKU-3')")" "0"
ck "FULL: SKU-1 price 8.99" "$(q "SELECT price FROM v_product WHERE sku='SKU-1'")" "8.99"
ck "FULL: SKU-2 unchanged -> NOCHANGE, zero churn" \
   "$(q "SELECT COUNT(*) FROM core_product WHERE sku='SKU-2'")" "1"
ck "FULL product feed leaves the other core tables untouched" \
   "$(q "SELECT COUNT(*) FROM core_order_line WHERE record_source<>'B0'")" "0"

echo; echo "== D3: INCREMENTAL tombstone deletes C002 =="
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
ck "tombstone: C002 latest core row is DELETE/TOMBSTONE" "$(latest_c C002)" "DELETE/TOMBSTONE"
ck "tombstone: C002 gone from v_customer (no ghost row)" \
   "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "0"
ck "tombstone: O-101 placed_by now NULL" \
   "$(q "SELECT COALESCE(placed_by,'<none>') FROM v_order WHERE order_ref='O-101'")" "<none>"
ck "the bridge keeps O-101's key to C002, so its amount still counts" \
   "$(q "SELECT _key_customer FROM _bridge WHERE stage='Orders' AND _key_orders='O-101'")/$(fan)" "C002/78.48/48.99/48.99"
ck "sales by customer: C002's 19.5 survives with no name" \
   "$(q "SELECT COALESCE(customer_name,'<none>')||'/'||order_amount FROM v_sales_by_customer WHERE customer_ref='C002'")" "<none>/19.5"
ck "AS-OF (from the core): as-recorded still answers Bob Jones" \
   "$(q "SELECT placed_by_as_recorded FROM v_order_as_recorded
         WHERE order_ref='O-101' AND recorded_at='2026-02-05 08:00:00'")" "Bob Jones"
ck "tombstone: C002 has exactly one DELETE row" \
   "$(q "SELECT COUNT(*) FROM core_customer WHERE customer_id='C002' AND change_type='DELETE'")" "1"

echo; echo "== D4: INCREMENTAL adds C003; recency de-dup =="
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
ck "recency: newest email wins (not MAX)" "$(q "SELECT email FROM v_customer WHERE customer_ref='C003'")" "new@x.com"
ck "recency: one delivery -> one core row" "$(rows C003)" "1"
ck "NO CHASM TRAP: order-less C003 still appears in sales by customer" \
   "$(q "SELECT customer_name||'/'||n_orders||'/'||order_amount||'/'||n_lines FROM v_sales_by_customer WHERE customer_ref='C003'")" "Carol Diaz/0/0/0"

echo; echo "== Load control: re-deliver D1 (same file_id) must be skipped =="
before="$(census)"; before_b="$(bridge)"
feed d1_cust_win_day60.sql D1 '2026-04-10 08:00:00'
ck "dup file skipped: core unchanged" "$(census)" "$before"
ck "dup file skipped: bridge unchanged" "$(bridge)" "$before_b"

echo; echo "== D5: YEARLY FULL reconciliation (C003 gone at source) =="
feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'
ck "reconcile: C003 deleted by absence (FULL)" "$(latest_c C003)" "DELETE/FULL_ABSENCE"
ck "reconcile: C001 unchanged content -> zero churn (still 2)" "$(rows C001)" "2"
ck "reconcile: C002 already deleted -> zero churn (still 2)"   "$(rows C002)" "2"
ck "reconcile: D5 wrote exactly one core row (the C003 delete)" \
   "$(q "SELECT COUNT(*) FROM core_customer WHERE record_source='D5'")" "1"
ck "reconcile: v_customer shows only C001" \
   "$(q "SELECT group_concat(customer_ref,',') FROM v_customer")" "C001"
ck "reconcile: C003 left the Customer stage" \
   "$(q "SELECT COUNT(*) FROM _bridge WHERE _key_customer='C003'")" "0"

echo; echo "== True loader idempotence: same content, NEW file_id, writes nothing =="
before_r="$(census)"; before_rb="$(bridge)"
feed d5_cust_yearly_full.sql D5R '2027-01-10 08:00:00'
ck "re-asserted current state writes zero core rows" "$(census)" "$before_r"
ck "...and the refreshed bridge is identical" "$(bridge)" "$before_rb"

echo; echo "== Core and archive: insert-only is enforced =="
ck_abort "UPDATE on a core table aborts" "$DB" "UPDATE core_customer SET full_name='x';" "insert-only"
ck_abort "DELETE on a core table aborts" "$DB" "DELETE FROM core_order;" "insert-only"
ck "archive captured every delivered row" \
   "$(aq "SELECT (SELECT COUNT(*) FROM arch.hist_customer)+(SELECT COUNT(*) FROM arch.hist_product)
              +(SELECT COUNT(*) FROM arch.hist_order)+(SELECT COUNT(*) FROM arch.hist_order_line)")" \
   "$(aq 'SELECT SUM(row_count) FROM arch.loaded_files')"
ck "core is delta-compressed: fewer rows than the archive holds" \
   "$(aq "SELECT (SELECT COUNT(*) FROM core_customer) < (SELECT COUNT(*) FROM arch.hist_customer)")" "1"
ck_abort "UPDATE on hist_customer aborts" "$ARCHIVE_DB" "UPDATE hist_customer SET full_name='x';" "append-only"
ck_abort "DELETE on hist_order aborts"    "$ARCHIVE_DB" "DELETE FROM hist_order;" "append-only"

echo; echo "== Rebuild: core and USS are disposable =="
ingested="$(snap)"
rm -f "$DB"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
ck "clean+rebuild: core AND bridge identical" "$(snap)" "$ingested"

echo; echo "== A materialised decode: rule change waits for a refresh, not a reload =="
q "UPDATE ref_order_status SET status_name='PLACED' WHERE status_code='P';" >/dev/null
ck "live ref change is NOT yet visible (the USS is materialised)" \
   "$(q "SELECT DISTINCT status FROM v_order")" "PENDING"
"$PROJ/scripts/refresh_uss.sh" >/dev/null
ck "refresh_uss.sh alone applies it -- no core reload" \
   "$(q "SELECT DISTINCT status FROM v_order")" "PLACED"
ck "...and the history view reads it on the fly" \
   "$(q "SELECT DISTINCT status FROM v_order_as_recorded")" "PLACED"
ck "...while the core still holds the raw code" \
   "$(q "SELECT DISTINCT status FROM core_order")" "P"
q "UPDATE ref_order_status SET status_name='PENDING' WHERE status_code='P';" >/dev/null
"$PROJ/scripts/refresh_uss.sh" >/dev/null

echo; echo "== Re-point: OMS moves O-101 to C001 -> the bridge is re-derived =="
feed d6_repoint.sql D6 '2027-02-01 08:00:00' "$HERE/fixtures"
ck "repoint: core O-101 has 2 rows, the new one an UPDATE" \
   "$(q "SELECT COUNT(*)||'/'||(SELECT change_type FROM v_latest__order WHERE order_ref='O-101')
         FROM core_order WHERE order_ref='O-101'")" "2/UPDATE"
ck "repoint: Orders stage now keys O-101 to C001" \
   "$(q "SELECT _key_customer FROM _bridge WHERE stage='Orders' AND _key_orders='O-101'")" "C001"
ck "repoint: the order LINE followed its order (transitive key)" \
   "$(q "SELECT _key_customer FROM _bridge WHERE _key_order_line='O-101|SKU-2'")" "C001"
ck "repoint: placed_by resolves to Alice Smith" \
   "$(q "SELECT placed_by FROM v_order WHERE order_ref='O-101'")" "Alice Smith"
ck "repoint: C001 now owns both orders, all 3 lines, 48.99" \
   "$(q "SELECT n_orders||'/'||n_lines||'/'||order_amount FROM v_sales_by_customer WHERE customer_ref='C001'")" "2/3/48.99"
ck "repoint: C002 has left the star entirely" \
   "$(q "SELECT COUNT(*) FROM _bridge WHERE _key_customer='C002'")" "0"
ck "repoint: the old pairing survives in the core" \
   "$(q "SELECT customer_ref FROM core_order WHERE order_ref='O-101' AND load_ts='2026-02-05 08:00:00'")" "C002"
ck "repoint: as-recorded reads each core row against its own moment" \
   "$(q "SELECT group_concat(COALESCE(placed_by_as_recorded,'<none>'),',') FROM
           (SELECT placed_by_as_recorded FROM v_order_as_recorded WHERE order_ref='O-101' ORDER BY recorded_at)")" "Bob Jones,Alice Smith"
ck "repoint: still no fan trap" "$(fan)" "78.48/48.99/48.99"
before_d6r="$(census)"
feed d6_repoint.sql D6R '2027-02-15 08:00:00' "$HERE/fixtures"
ck "re-asserted repoint writes nothing" "$(census)" "$before_d6r"

echo; echo "====================================================================="
printf "  RESULT: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "====================================================================="
rm -f "$DB" "$ARCHIVE_DB"
[ "$FAIL" -eq 0 ] || exit 1
