#!/usr/bin/env bash
# =====================================================================
# Anchor Modeling test suite -- the shared delivery scenarios against a
# 6NF constellation, plus the Anchor-specific behaviours: attribute-
# grain history, restatement control, presence-as-data (no row_st),
# closed knot domains, historized-tie re-pointing, and an archive-backed
# rebuild that reproduces every anchor surrogate.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
# No `set -e`: every assertion must run so one failure doesn't hide the rest.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/anchor_test).db}"
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
ck_abort(){ local label="$1" sql="$2" want="$3" out
      out="$("$SQLITE" "$ARCHIVE_DB" "$sql" 2>&1)"
      case "$out" in *"$want"*) PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$label";;
        *) FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s  (got '%s')\n" "$label" "$out";; esac; }

census(){ q "SELECT group_concat(t||'='||n,' ') FROM (
    SELECT 1 o,'cu' t,COUNT(*) n FROM CU_Customer
    UNION ALL SELECT 2,'cu_nam', COUNT(*) FROM CU_NAM_Customer_Name
    UNION ALL SELECT 3,'cu_eml', COUNT(*) FROM CU_EML_Customer_Email
    UNION ALL SELECT 4,'cu_sgn', COUNT(*) FROM CU_SGN_Customer_SignupDate
    UNION ALL SELECT 5,'cu_est', COUNT(*) FROM CU_EST_Customer_Existence
    UNION ALL SELECT 6,'pr', COUNT(*) FROM PR_Product
    UNION ALL SELECT 7,'pr_nam', COUNT(*) FROM PR_NAM_Product_Name
    UNION ALL SELECT 8,'pr_prc', COUNT(*) FROM PR_PRC_Product_Price
    UNION ALL SELECT 9,'pr_cur', COUNT(*) FROM PR_CUR_Product_Currency
    UNION ALL SELECT 10,'pr_est', COUNT(*) FROM PR_EST_Product_Existence
    UNION ALL SELECT 11,'od', COUNT(*) FROM OD_Order
    UNION ALL SELECT 12,'od_amt', COUNT(*) FROM OD_AMT_Order_Amount
    UNION ALL SELECT 13,'od_cur', COUNT(*) FROM OD_CUR_Order_Currency
    UNION ALL SELECT 14,'od_plc', COUNT(*) FROM OD_PLC_Order_PlacedAt
    UNION ALL SELECT 15,'od_ost', COUNT(*) FROM OD_OST_Order_Status
    UNION ALL SELECT 16,'od_est', COUNT(*) FROM OD_EST_Order_Existence
    UNION ALL SELECT 17,'tie_cu', COUNT(*) FROM OD_placed_CU_by
    UNION ALL SELECT 18,'tie_pr', COUNT(*) FROM OD_part_PR_of
    ORDER BY o);"; }

# Full logical snapshot: every surrogate, value and ChangedAt.
snap(){ q "
  SELECT 'a', CU_ID, '' , '' FROM CU_Customer
  UNION ALL SELECT 'r', CU_ID, Customer_Reference, '' FROM CU_REF_Customer_Reference
  UNION ALL SELECT 'n', CU_ID, COALESCE(Customer_Name,''), ChangedAt FROM CU_NAM_Customer_Name
  UNION ALL SELECT 'e', CU_ID, COALESCE(Customer_Email,''), ChangedAt FROM CU_EML_Customer_Email
  UNION ALL SELECT 'x', CU_ID, EST_ID, ChangedAt FROM CU_EST_Customer_Existence
  UNION ALL SELECT 'pa', PR_ID, '', '' FROM PR_Product
  UNION ALL SELECT 'pr', PR_ID, Product_Reference, '' FROM PR_REF_Product_Reference
  UNION ALL SELECT 'pp', PR_ID, COALESCE(Product_Price,''), ChangedAt FROM PR_PRC_Product_Price
  UNION ALL SELECT 'px', PR_ID, EST_ID, ChangedAt FROM PR_EST_Product_Existence
  UNION ALL SELECT 'oa', OD_ID, '', '' FROM OD_Order
  UNION ALL SELECT 'or_', OD_ID, Order_Reference, '' FROM OD_REF_Order_Reference
  UNION ALL SELECT 'os', OD_ID, OST_ID, ChangedAt FROM OD_OST_Order_Status
  UNION ALL SELECT 'tc', OD_ID, CU_ID, ChangedAt FROM OD_placed_CU_by
  UNION ALL SELECT 'tp', OD_ID, PR_ID, '' FROM OD_part_PR_of
  ORDER BY 1,2,3,4;"; }

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
  [ "$SKIPPED" -eq 0 ] && ck "[$file_id] manifest: COMPLETE after all loaders" \
     "$(aq "SELECT status FROM arch.loaded_files WHERE file_id='$file_id'")" "COMPLETE"
  ck "[$file_id] stage blank after delivery" \
     "$(q 'SELECT COUNT(*) FROM source_landing_stage')" "0"; }

cuid(){ q "SELECT CU_ID FROM CU_REF_Customer_Reference WHERE Customer_Reference='$1'"; }
est(){  q "SELECT k.ExistenceStatus FROM lCU_EST x JOIN EST_ExistenceStatus k USING(EST_ID)
           WHERE x.CU_ID=$(cuid "$1")"; }

echo "== Fresh db + archive =="; rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null

echo; echo "== D0: FULL baseline =="
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
ck "baseline: 2 customers, 3 products, 2 orders in the perspectives" \
   "$(q "SELECT (SELECT COUNT(*) FROM v_customer)||'/'||(SELECT COUNT(*) FROM v_product)||'/'||(SELECT COUNT(*) FROM v_order)")" "2/3/2"
ck "baseline: deterministic anchor IDs (C001=1001, C002=1002)" \
   "$(q "SELECT group_concat(Customer_Reference||'='||CU_ID,',') FROM (SELECT * FROM CU_REF_Customer_Reference ORDER BY Customer_Reference)")" \
   "C001=1001,C002=1002"
ck "baseline: C001 email v1" "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@example.com"
ck "baseline: typed column (Product_Price is REAL, not a slot)" \
   "$(q "SELECT typeof(Product_Price) FROM PR_PRC_Product_Price LIMIT 1")" "real"
ck "KNOT: raw 'P' in the archive, knot label PENDING on read" \
   "$(aq "SELECT (SELECT DISTINCT value_str FROM arch.source_landing_history
                  WHERE attribute_name='status' AND business_key='O-100')||'/'||
                (SELECT status FROM v_order WHERE order_ref='O-100')")" "P/PENDING"

echo; echo "== D1: CRM 14-day INCREMENTAL window (C001 changed; C002 absent) =="
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
ck "ATTRIBUTE GRAIN: C001 email has 2 rows..." \
   "$(q "SELECT COUNT(*) FROM CU_EML_Customer_Email WHERE CU_ID=$(cuid C001)")" "2"
ck "  ...but C001 name still has 1 (only what changed is versioned)" \
   "$(q "SELECT COUNT(*) FROM CU_NAM_Customer_Name WHERE CU_ID=$(cuid C001)")" "1"
ck "INCREMENTAL: C002 NOT deleted (60-day stale)" "$(est C002)" "EXISTS"
ck "INCREMENTAL: C002 zero churn anywhere" \
   "$(q "SELECT (SELECT COUNT(*) FROM CU_EML_Customer_Email WHERE CU_ID=$(cuid C002)) +
              (SELECT COUNT(*) FROM CU_EST_Customer_Existence WHERE CU_ID=$(cuid C002))")" "2"
ck "restatement control: C001 EXISTS not re-asserted" \
   "$(q "SELECT COUNT(*) FROM CU_EST_Customer_Existence WHERE CU_ID=$(cuid C001)")" "1"

echo; echo "== D2: PIM FULL snapshot (SKU-3 discontinued) =="
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
ck "FULL: SKU-3 DELETED by absence (existence is data, not row_st)" \
   "$(q "SELECT k.ExistenceStatus FROM lPR_EST x JOIN EST_ExistenceStatus k USING(EST_ID)
         JOIN PR_REF_Product_Reference r ON r.PR_ID=x.PR_ID WHERE r.Product_Reference='SKU-3'")" "DELETED"
ck "FULL: SKU-3 attributes untouched by its deletion" \
   "$(q "SELECT Product_Name FROM PR_NAM_Product_Name p JOIN PR_REF_Product_Reference r
         ON r.PR_ID=p.PR_ID WHERE r.Product_Reference='SKU-3'")" "Gizmo"
ck "FULL: SKU-3 excluded from v_product" "$(q "SELECT COUNT(*) FROM v_product WHERE sku='SKU-3'")" "0"
ck "FULL: SKU-1 price 8.99 as a second PRC row" \
   "$(q "SELECT COUNT(*) FROM PR_PRC_Product_Price p JOIN PR_REF_Product_Reference r
         ON r.PR_ID=p.PR_ID WHERE r.Product_Reference='SKU-1'")" "2"
ck "FULL: SKU-2 zero churn" \
   "$(q "SELECT COUNT(*) FROM PR_PRC_Product_Price p JOIN PR_REF_Product_Reference r
         ON r.PR_ID=p.PR_ID WHERE r.Product_Reference='SKU-2'")" "1"

echo; echo "== D3: INCREMENTAL tombstone deletes C002 =="
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
ck "tombstone: C002 DELETED"                 "$(est C002)" "DELETED"
ck "tombstone: C002 gone from v_customer"    "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "0"
ck "tombstone: O-101 placed_by now NULL"     "$(q "SELECT COALESCE(placed_by,'<none>') FROM v_order WHERE order_ref='O-101'")" "<none>"
ck "tombstone: Bob's history intact"         "$(q "SELECT Customer_Name FROM CU_NAM_Customer_Name WHERE CU_ID=$(cuid C002)")" "Bob Jones"

echo; echo "== D4: INCREMENTAL adds C003; recency de-dup =="
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
ck "recency: newest email wins (not MAX)" "$(q "SELECT email FROM v_customer WHERE customer_ref='C003'")" "new@x.com"
ck "recency: one delivery -> one EML row" "$(q "SELECT COUNT(*) FROM CU_EML_Customer_Email WHERE CU_ID=$(cuid C003)")" "1"

echo; echo "== Load control: re-deliver D1 (same file_id) must be skipped =="
before="$(census)"
feed d1_cust_win_day60.sql D1 '2026-04-10 08:00:00'
ck "dup file skipped: constellation unchanged" "$(census)" "$before"
cat > "$LOGDIR/tamper.sql" <<'SQL'
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('CRM','CUSTOMER','C009','customer_ref','C009',NULL,NULL,'2026-05-01','UPSERT','INCREMENTAL');
SQL
out="$(BATCH_TS='2026-05-01 08:00:00' "$PROJ/scripts/load_feed.sh" "$LOGDIR/tamper.sql" D1 2>&1)"; rc=$?
ck "reused file_id with different content is REJECTED" \
   "$([ "$rc" -ne 0 ] && echo rejected || echo accepted)" "rejected"

echo; echo "== D5: YEARLY FULL reconciliation (C003 gone at source) =="
feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'
ck "reconcile: C003 DELETED by absence (FULL)" "$(est C003)" "DELETED"
ck "reconcile: C002 stays DELETED, no re-assertion (still 2 rows)" \
   "$(q "SELECT COUNT(*) FROM CU_EST_Customer_Existence WHERE CU_ID=$(cuid C002)")" "2"
ck "reconcile: C001 full snapshot, zero attribute churn" \
   "$(q "SELECT COUNT(*) FROM CU_EML_Customer_Email WHERE CU_ID=$(cuid C001) AND ChangedAt='2026-12-31 08:00:00'")" "0"
ck "reconcile: v_customer shows only C001" \
   "$(q "SELECT group_concat(customer_ref,',') FROM v_customer")" "C001"

echo; echo "== True loader idempotence: same content, NEW file_id, writes nothing =="
before_r="$(census)"
feed d5_cust_yearly_full.sql D5R '2027-01-10 08:00:00'
ck "re-asserted current state writes zero rows" "$(census)" "$before_r"

echo; echo "== Archive: append-only is absolute =="
ck "archive captured every delivered row" \
   "$(aq 'SELECT COUNT(*) FROM arch.source_landing_history')" \
   "$(aq 'SELECT SUM(row_count) FROM arch.loaded_files')"
ck_abort "UPDATE on source_landing_history aborts" \
  "UPDATE source_landing_history SET value_str='x';" "append-only"
ck_abort "DELETE on source_landing_history aborts" \
  "DELETE FROM source_landing_history;" "append-only"

echo; echo "== Rebuild: the constellation is disposable =="
ingested="$(snap)"
rm -f "$DB"                              # exactly what `make clean` does
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
ck "clean+rebuild: identical, anchor surrogates included" "$(snap)" "$ingested"

echo; echo "== Knot relabel: label lives in one place, history included =="
q "UPDATE OST_OrderStatus SET Order_Status='PLACED' WHERE Status_Code='P';" >/dev/null
ck "relabel: every order reads PLACED instantly, no reload" \
   "$(q "SELECT DISTINCT status FROM v_order")" "PLACED"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1
ck "  ...and rebuild resets it: schema seed is the source of truth" \
   "$(q "SELECT DISTINCT status FROM v_order")" "PENDING"

echo; echo "== Closed knot domain: an unknown code fails the load =="
cat > "$LOGDIR/badknot.sql" <<'SQL'
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('OMS','ORDER','O-999','order_ref','O-999',NULL,NULL,'2027-01-20','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-999','status','X',NULL,NULL,'2027-01-20','UPSERT','INCREMENTAL');
SQL
out="$(BATCH_TS='2027-01-20 08:00:00' "$PROJ/scripts/load_feed.sh" "$LOGDIR/badknot.sql" DX 2>&1)"; rc=$?
ck "unknown status code 'X' is REJECTED, not invented" \
   "$([ "$rc" -ne 0 ] && echo rejected || echo accepted)" "rejected"
ck "  ...and the failed delivery stays retryable (STARTED)" \
   "$(aq "SELECT status FROM arch.loaded_files WHERE file_id='DX'")" "STARTED"
ck "  ...with its staged rows preserved as forensics" \
   "$(q 'SELECT COUNT(*) FROM source_landing_stage')" "2"
q "DELETE FROM source_landing_stage;" >/dev/null   # clean up for the next block

echo; echo "== Historized tie: OMS re-points O-101 from C002 to C001 =="
feed d7_repoint.sql D7 '2027-02-01 08:00:00' "$HERE/fixtures"
ck "repoint: O-101 pairing history has 2 rows" \
   "$(q "SELECT COUNT(*) FROM v_order_customer_history WHERE order_ref='O-101'")" "2"
ck "repoint: exactly one current, and it is C001" \
   "$(q "SELECT customer_ref FROM v_order_customer_history WHERE order_ref='O-101' AND iscurrent=1")" "C001"
ck "repoint: old pairing end-dated by LEAD, never updated" \
   "$(q "SELECT end_ts FROM v_order_customer_history WHERE order_ref='O-101' AND customer_ref='C002'")" "2027-02-01 08:00:00"
ck "repoint: placed_by resolves to Alice Smith" \
   "$(q "SELECT placed_by FROM v_order WHERE order_ref='O-101'")" "Alice Smith"
ck "repoint: restatement control kept every attribute silent" \
   "$(q "SELECT COUNT(*) FROM OD_AMT_Order_Amount WHERE ChangedAt='2027-02-01 08:00:00'")" "0"
before_d7r="$(census)"
feed d7_repoint.sql D7R '2027-02-15 08:00:00' "$HERE/fixtures"
ck "re-asserted repoint writes nothing" "$(census)" "$before_d7r"

echo; echo "====================================================================="
printf "  RESULT: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "====================================================================="
rm -f "$DB" "$ARCHIVE_DB"
[ "$FAIL" -eq 0 ] || exit 1
