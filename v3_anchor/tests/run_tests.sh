#!/usr/bin/env bash
# =====================================================================
# Anchor Modeling test suite.
#
# PART 1, CORE: the fourteen sections every one of the ten suites runs,
# in the same order and with the same labels (tests/core_spec.tsv at the
# repo root). Each model supplies its own SQL; the nine question
# answers live in tests/answers/Q<n>.sql.
# PART 2, MODEL: what Anchor shows on its own -- deterministic anchor
# surrogates, attribute-grain history in typed tables, restatement
# control, existence as a knot, the closed knot domain, the historized
# tie on re-point, and the wide -> narrow transform.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/anchor_test).db}"
export ARCHIVE_DB="${DB%.db}_archive.db"
FEED_N=0; SKIPPED=0
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
# The answer to question n, from tests/answers/Q<n>.sql (read on stdin,
# so the file's leading comment is not taken for a command-line option).
ans(){ local out rc=0; out="$("$SQLITE" "$DB" < "$HERE/answers/Q$1.sql" 2>&1)" || rc=$?
       [ "$rc" -eq 0 ] || { printf "  \033[31mSQL ERROR\033[0m Q%s: %s\n" "$1" "$out" >&2
                            printf '<SQL-ERROR>'; return 0; }
       printf '%s' "$out"; }

# ---- Core and model assertions (the same block in all ten suites) -----
# core ID GOT WANT      a core assertion; its label comes from core_spec.tsv
# own LABEL GOT WANT    a model-specific assertion
# core_abort / own_abort  the statement must be refused on the archive
# core_gap / own_gap    expected failure (a known gap): amber GAP while it
#                       fails, red XPASS (a failure) once it passes
# later SECTION LABEL GOT WANT   a model assertion evaluated now, reported
#                       later in MODEL section SECTION (replay SECTION)
CORE_SPEC="$PROJ/../tests/core_spec.tsv"
[ -r "$CORE_SPEC" ] || { echo "FATAL: core spec not found: $CORE_SPEC" >&2; exit 1; }
CORE_TOTAL="$(awk -F'\t' 'NR>1 && $1!="" {n++} END {print n+0}' "$CORE_SPEC")"
CORE_PASS=0; CORE_FAIL=0; CORE_GAP=0; CORE_N=0; OWN_PASS=0; OWN_FAIL=0; OWN_GAP=0
LATER_N=0; mkdir -p "$LOGDIR/later"
spec(){ awk -F'\t' -v id="$1" -v f="$2" 'NR>1 && $1==id {print $f; exit}' "$CORE_SPEC"; }
core_section(){ printf "\n== %s %s ==\n" "$1" \
  "$(awk -F'\t' -v s="$1" 'NR>1 && $2==s {print $3; exit}' "$CORE_SPEC")"; }
own_section(){ printf "\n== %s %s ==\n" "$1" "$2"; }
banner(){ printf "\n#####################################################################\n"
          printf "  PART %s\n" "$1"
          printf "#####################################################################\n"; }
core_label(){ local l; l="$(spec "$1" 4)"; [ -n "$l" ] || l="<unknown core id>"; printf '%s' "$l"; }
core(){ local id="$1" label; label="$(core_label "$id")"; CORE_N=$((CORE_N+1))
  if [ "$2" = "$3" ] && [ "$label" != "<unknown core id>" ]; then CORE_PASS=$((CORE_PASS+1))
    printf "  \033[32mPASS\033[0m %s %s\n" "$id" "$label"
  else CORE_FAIL=$((CORE_FAIL+1))
    printf "  \033[31mFAIL\033[0m %s %s  (got '%s', expected '%s')\n" "$id" "$label" "$2" "$3"; fi; }
own(){ if [ "$2" = "$3" ]; then OWN_PASS=$((OWN_PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"
       else OWN_FAIL=$((OWN_FAIL+1))
         printf "  \033[31mFAIL\033[0m %s  (got '%s', expected '%s')\n" "$1" "$2" "$3"; fi; }
refused(){ local out; out="$("$SQLITE" "$ARCHIVE_DB" "$1" 2>&1)"
           case "$out" in *"$2"*) printf 'refused';; *) printf '%s' "$out";; esac; }
core_abort(){ core "$1" "$(refused "$2" "$3")" "refused"; }
own_abort(){  own  "$1" "$(refused "$2" "$3")" "refused"; }
core_gap(){ local id="$1" label; label="$(core_label "$id")"; CORE_N=$((CORE_N+1))
  if [ "$2" = "$3" ]; then CORE_FAIL=$((CORE_FAIL+1))
    printf "  \033[31mXPASS\033[0m %s %s -- the gap appears FIXED; make this a core() check.\n" "$id" "$label"
  else CORE_GAP=$((CORE_GAP+1))
    printf "  \033[33mGAP \033[0m %s %s  (got '%s', wanted '%s')\n        why: %s\n" "$id" "$label" "$2" "$3" "$4"; fi; }
own_gap(){ if [ "$2" = "$3" ]; then OWN_FAIL=$((OWN_FAIL+1))
    printf "  \033[31mXPASS\033[0m %s -- the gap appears FIXED; make this an own() check.\n" "$1"
  else OWN_GAP=$((OWN_GAP+1))
    printf "  \033[33mGAP \033[0m %s  (got '%s', wanted '%s')\n        why: %s\n" "$1" "$2" "$3" "$4"; fi; }
later(){ LATER_N=$((LATER_N+1)); local f; f="$LOGDIR/later/$(printf '%05d' "$LATER_N")"
  printf '%s' "$1" > "$f.sec"; printf '%s' "$2" > "$f.label"
  printf '%s' "$3" > "$f.got"; printf '%s' "$4" > "$f.want"; }
replay(){ local f; for f in "$LOGDIR"/later/*.sec; do [ -e "$f" ] || continue
  [ "$(cat "$f")" = "$1" ] || continue; f="${f%.sec}"
  own "$(cat "$f.label")" "$(cat "$f.got")" "$(cat "$f.want")"; done; }
summary(){ local rc=0
  echo; echo "====================================================================="
  printf "  RESULT: %d passed, %d failed, %d known gap(s)\n" \
    $((CORE_PASS+OWN_PASS)) $((CORE_FAIL+OWN_FAIL)) $((CORE_GAP+OWN_GAP))
  echo "====================================================================="
  if [ "$CORE_N" -ne "$CORE_TOTAL" ]; then
    printf "  \033[31mFAIL\033[0m %d core assertions ran; core_spec.tsv lists %d\n" "$CORE_N" "$CORE_TOTAL"; rc=1; fi
  [ $((CORE_FAIL+OWN_FAIL)) -eq 0 ] || rc=1
  printf "  CORE : %d/%d passed\n" "$CORE_PASS" "$CORE_TOTAL"
  printf "  MODEL: %d passed\n" "$OWN_PASS"
  printf "  GAP  : %d\n" $((CORE_GAP+OWN_GAP))
  return "$rc"; }
# ---- end of the shared block ------------------------------------------

archive_state(){ aq "SELECT (SELECT COUNT(*) FROM arch.loaded_files)||'/'||(SELECT COUNT(*) FROM arch.hist_customer)
                      ||'/'||(SELECT COUNT(*) FROM arch.hist_product)||'/'||(SELECT COUNT(*) FROM arch.hist_order)
                      ||'/'||(SELECT COUNT(*) FROM arch.hist_order_line)"; }
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

cuid(){ q "SELECT CU_ID FROM CU_REF_Customer_Reference WHERE Customer_Reference='$1'"; }
# Rows the archive holds: the shared wide layout (hist_* per source
# extract); optional $1 = file_id.
hist_rows(){ local w=""; [ -n "${1:-}" ] && w=" WHERE file_id='$1'"
  aq "SELECT (SELECT COUNT(*) FROM arch.hist_customer$w)+(SELECT COUNT(*) FROM arch.hist_product$w)
            +(SELECT COUNT(*) FROM arch.hist_order$w)+(SELECT COUNT(*) FROM arch.hist_order_line$w)"; }
# Every anchor surrogate, as business key=ID per anchor.
all_keys(){ q "SELECT group_concat(k,',') FROM (
    SELECT 'c:'||Customer_Reference||'='||CU_ID k FROM CU_REF_Customer_Reference
    UNION ALL SELECT 'p:'||Product_Reference||'='||PR_ID FROM PR_REF_Product_Reference
    UNION ALL SELECT 'o:'||Order_Reference||'='||OD_ID FROM OD_REF_Order_Reference ORDER BY 1)"; }
est(){  q "SELECT k.ExistenceStatus FROM lCU_EST x JOIN EST_ExistenceStatus k USING(EST_ID)
           WHERE x.CU_ID=$(cuid "$1")"; }


# Run one delivery; abort the suite if a loader crashes. Its manifest and
# stage checks are model assertions, reported in M01.
feed(){ local src="$1" file_id="$2" ts="$3" rc=0 log dir="${4:-$PROJ/source}"
  FEED_N=$((FEED_N+1)); log="$LOGDIR/$FEED_N-$file_id.log"
  BATCH_TS="$ts" "$PROJ/scripts/load_feed.sh" "$dir/$src" "$file_id" >"$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf "\n  \033[31mABORT\033[0m load_feed.sh exited %d at delivery %s (%s)\n" "$rc" "$file_id" "$src"
    sed 's/^/  | /' "$log"
    printf "\n  %d passed, %d failed before the abort.\n" \
      $((CORE_PASS+OWN_PASS)) $((CORE_FAIL+OWN_FAIL)); exit 1
  fi
  if grep -q 'SKIP duplicate' "$log"; then SKIPPED=1; else SKIPPED=0; fi
  later M01 "[$file_id] manifest: recorded exactly once" \
     "$(aq "SELECT COUNT(*) FROM arch.loaded_files WHERE file_id='$file_id'")" "1"
  [ "$SKIPPED" -eq 0 ] && later M01 "[$file_id] manifest: COMPLETE after all loaders" \
     "$(aq "SELECT status FROM arch.loaded_files WHERE file_id='$file_id'")" "COMPLETE"
  later M01 "[$file_id] stage blank after delivery" \
     "$(q 'SELECT COUNT(*) FROM source_landing_stage')" "0"; }

banner "1: CORE  (the same fourteen sections, in this order, in all ten suites)"

core_section C01
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null
core C01.1 "$(census)|$(archive_state)" \
  "cu=0 cu_nam=0 cu_eml=0 cu_sgn=0 cu_est=0 pr=0 pr_nam=0 pr_prc=0 pr_cur=0 pr_est=0 od=0 od_amt=0 od_cur=0 od_plc=0 od_ost=0 od_est=0 tie_cu=0 tie_pr=0|0/0/0/0/0"

core_section C02
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
core C02.1 "$(q "SELECT (SELECT COUNT(*) FROM v_customer)||'/'||(SELECT COUNT(*) FROM v_product)
                ||'/'||(SELECT COUNT(*) FROM v_order)||'/'||(SELECT COUNT(*) FROM OD_part_PR_of)")" "2/3/2/3"
core C02.2 "$(ans 5)" "PENDING"
core C02.3 "$(ans 6)" "48.99"
later M02 "baseline: deterministic anchor IDs (C001=1001, C002=1002)" \
   "$(q "SELECT group_concat(Customer_Reference||'='||CU_ID,',') FROM (SELECT * FROM CU_REF_Customer_Reference ORDER BY Customer_Reference)")" \
   "C001=1001,C002=1002"
later M02 "baseline: C001 email v1" "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@example.com"
later M03 "baseline: typed column (Product_Price is REAL, not a slot)" \
   "$(q "SELECT typeof(Product_Price) FROM PR_PRC_Product_Price LIMIT 1")" "real"
later M04 "KNOT: raw 'P' in the archive, knot label PENDING on read" \
   "$(aq "SELECT (SELECT DISTINCT status FROM arch.hist_order WHERE order_ref='O-100')||'/'||
                (SELECT status FROM v_order WHERE order_ref='O-100')")" "P/PENDING"

core_section C03
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
core C03.1 "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@newmail.com"
core C03.2 "$(est C002)" "EXISTS"
core C03.3 "$(q "SELECT (SELECT COUNT(*) FROM CU_EML_Customer_Email WHERE CU_ID=$(cuid C002)) +
                     (SELECT COUNT(*) FROM CU_EST_Customer_Existence WHERE CU_ID=$(cuid C002))")" "2"
core C03.4 "$(q "SELECT COUNT(*) FROM CU_NAM_Customer_Name WHERE CU_ID=$(cuid C001)")" "1"
later M03 "ATTRIBUTE GRAIN: C001 email has 2 rows..." \
   "$(q "SELECT COUNT(*) FROM CU_EML_Customer_Email WHERE CU_ID=$(cuid C001)")" "2"
later M03 "restatement control: C001 EXISTS not re-asserted" \
   "$(q "SELECT COUNT(*) FROM CU_EST_Customer_Existence WHERE CU_ID=$(cuid C001)")" "1"

core_section C04
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
core C04.1 "$(q "SELECT price FROM v_product WHERE sku='SKU-1'")" "8.99"
core C04.2 "$(q "SELECT COUNT(*) FROM v_product WHERE sku='SKU-3'")" "0"
core C04.3 "$(q "SELECT COUNT(*) FROM PR_PRC_Product_Price p JOIN PR_REF_Product_Reference r
                 ON r.PR_ID=p.PR_ID WHERE r.Product_Reference='SKU-2'")" "1"
core C04.4 "$(ans 4)" "9.99>8.99"
later M05 "FULL: SKU-3 DELETED by absence (existence is data, not row_st)" \
   "$(q "SELECT k.ExistenceStatus FROM lPR_EST x JOIN EST_ExistenceStatus k USING(EST_ID)
         JOIN PR_REF_Product_Reference r ON r.PR_ID=x.PR_ID WHERE r.Product_Reference='SKU-3'")" "DELETED"
later M03 "FULL: SKU-3 attributes untouched by its deletion" \
   "$(q "SELECT Product_Name FROM PR_NAM_Product_Name p JOIN PR_REF_Product_Reference r
         ON r.PR_ID=p.PR_ID WHERE r.Product_Reference='SKU-3'")" "Gizmo"
later M03 "FULL: SKU-1 price 8.99 as a second PRC row" \
   "$(q "SELECT COUNT(*) FROM PR_PRC_Product_Price p JOIN PR_REF_Product_Reference r
         ON r.PR_ID=p.PR_ID WHERE r.Product_Reference='SKU-1'")" "2"

core_section C05
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
core C05.1 "$(est C002)" "DELETED"
core C05.2 "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "0"
core C05.3 "$(q "SELECT COALESCE(placed_by,'<none>') FROM v_order WHERE order_ref='O-101'")" "<none>"
core C05.4 "$(q "SELECT (SELECT Customer_Name FROM CU_NAM_Customer_Name WHERE CU_ID=$(cuid C002))||'/'||
                       (SELECT Customer_Email FROM CU_EML_Customer_Email WHERE CU_ID=$(cuid C002))")" "Bob Jones/bob@example.com"
core C05.5 "$(ans 7)" "Bob Jones"

core_section C06
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
core C06.1 "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C003'")" "1"
core C06.2 "$(q "SELECT email FROM v_customer WHERE customer_ref='C003'")" "new@x.com"
later M03 "recency: one delivery -> one EML row" "$(q "SELECT COUNT(*) FROM CU_EML_Customer_Email WHERE CU_ID=$(cuid C003)")" "1"

core_section C07
before="$(census)"; before_arch="$(archive_state)"
feed d1_cust_win_day60.sql D1 '2026-04-10 08:00:00'
core C07.1 "$SKIPPED" "1"
core C07.2 "$(census)" "$before"
core C07.3 "$(archive_state)" "$before_arch"
# D1's id, different content (two other customers): refused before any write.
cat > "$LOGDIR/reused_id.sql" <<'SQL'
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C009','Tam Per','t@x.com','2027-01-01','2027-01-01','UPSERT','INCREMENTAL'),
('C010','Tam Per','u@x.com','2027-01-01','2027-01-01','UPSERT','INCREMENTAL');
SQL
rc=0; BATCH_TS='2026-04-11 08:00:00' "$PROJ/scripts/load_feed.sh" "$LOGDIR/reused_id.sql" D1 \
  >"$LOGDIR/reused_id.log" 2>&1 || rc=$?
core C07.4 "$([ "$rc" -ne 0 ] && grep -q '^FATAL' "$LOGDIR/reused_id.log" && echo rejected || echo "accepted (exit $rc)")|$(census)|$(archive_state)" \
           "rejected|$before|$before_arch"
# Anchor's own check: same row count as D1, different content.
cat > "$LOGDIR/tamper.sql" <<'SQL'
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C009','Tam Per','t@x.com','2026-05-01','2026-05-01','UPSERT','INCREMENTAL');
SQL
out="$(BATCH_TS='2026-05-01 08:00:00' "$PROJ/scripts/load_feed.sh" "$LOGDIR/tamper.sql" D1 2>&1)"; rc=$?
later M06 "reused file_id with different content is REJECTED" \
   "$([ "$rc" -ne 0 ] && echo rejected || echo accepted)" "rejected"

core_section C08
feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'
core C08.1 "$(est C003)" "DELETED"
core C08.2 "$(ans 1)" "C001"
core C08.3 "$(ans 2)" "C002,C003"
core C08.4 "$(ans 3)" "alice@example.com>alice@newmail.com"
later M05 "reconcile: C002 stays DELETED, no re-assertion (still 2 rows)" \
   "$(q "SELECT COUNT(*) FROM CU_EST_Customer_Existence WHERE CU_ID=$(cuid C002)")" "2"
later M03 "reconcile: C001 full snapshot, zero attribute churn" \
   "$(q "SELECT COUNT(*) FROM CU_EML_Customer_Email WHERE CU_ID=$(cuid C001) AND ChangedAt='2026-12-31 08:00:00'")" "0"

core_section C09
before_r="$(census)"
feed d5_cust_yearly_full.sql D5R '2027-01-10 08:00:00'
core C09.1 "$(census)" "$before_r"

core_section C10
core C10.1 "$(hist_rows)" "$(aq 'SELECT SUM(row_count) FROM arch.loaded_files')"
core C10.2 "$(for t in hist_customer hist_product hist_order hist_order_line; do
                printf '%s ' "$(refused "UPDATE $t SET op=op;" "append-only")"; done)" \
           "refused refused refused refused "
core C10.3 "$(for t in hist_customer hist_product hist_order hist_order_line; do
                printf '%s ' "$(refused "DELETE FROM $t;" "append-only")"; done)" \
           "refused refused refused refused "

core_section C11
ingested="$(snap)"
rm -f "$DB"                              # exactly what `make clean` does
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
core C11.1 "$(snap)" "$ingested"
ingested_keys="$(all_keys)"
rm -f "$DB"
make -s -C "$PROJ" rebuild >/dev/null 2>&1; rc=$?
later M07 "make rebuild exits 0" "$rc" "0"
later M07 "make rebuild: every anchor surrogate (customer, product, order) as ingested" "$(all_keys)" "$ingested_keys"
later M07 "make rebuild: constellation identical to INGEST" "$(snap)" "$ingested"
later M07 "archive tables are exactly the shared wide layout" \
   "$(aq "SELECT group_concat(name,',') FROM (SELECT name FROM arch.sqlite_master WHERE type='table' ORDER BY name)")" \
   "hist_customer,hist_order,hist_order_line,hist_product,loaded_files"
later M07 "no archived table has a key/value (attribute_name) column" \
   "$(aq "SELECT COUNT(*) FROM arch.sqlite_master m, pragma_table_info(m.name, 'arch') c
          WHERE m.type='table' AND c.name='attribute_name'")" "0"

core_section C12
# The label lives in one place, the OST knot: one UPDATE relabels every
# order, history included, with no reload.
q "UPDATE OST_OrderStatus SET Order_Status='PLACED' WHERE Status_Code='P';" >/dev/null
core C12.1 "$(ans 9)" "O-100=PLACED,O-101=PLACED"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1
later M04 "  ...and rebuild resets it: schema seed is the source of truth" \
   "$(q "SELECT DISTINCT status FROM v_order")" "PENDING"
# Closed knot domain (M08): a complete order row whose ONLY defect is the
# status code 'X' must fail the load, not invent a knot value.
cat > "$LOGDIR/badknot.sql" <<'SQL'
INSERT INTO stg_order_l1(order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode) VALUES
('O-999','C001','X',1.0,'USD','2027-01-20 10:00','2027-01-20','UPSERT','INCREMENTAL');
SQL
out="$(BATCH_TS='2027-01-20 08:00:00' "$PROJ/scripts/load_feed.sh" "$LOGDIR/badknot.sql" DX 2>&1)"; rc=$?
later M08 "unknown status code 'X' is REJECTED, not invented" \
   "$([ "$rc" -ne 0 ] && echo rejected || echo accepted)" "rejected"
later M08 "  ...and the failed delivery stays retryable (STARTED)" \
   "$(aq "SELECT status FROM arch.loaded_files WHERE file_id='DX'")" "STARTED"
later M08 "  ...with its staged rows preserved as forensics" \
   "$(q 'SELECT COUNT(*) FROM stg_order_l1')" "1"
q "DELETE FROM stg_order_l1; DELETE FROM source_landing_stage;" >/dev/null   # clean up for the next block

core_section C13
feed d7_repoint.sql D7 '2027-02-01 08:00:00' "$HERE/fixtures"
core C13.1 "$(ans 8)" "Alice Smith"
core C13.2 "$(q "SELECT customer_ref FROM v_order_customer_history WHERE order_ref='O-101' AND iscurrent=0")" "C002"
later M09 "repoint: O-101 pairing history has 2 rows" \
   "$(q "SELECT COUNT(*) FROM v_order_customer_history WHERE order_ref='O-101'")" "2"
later M09 "repoint: exactly one current, and it is C001" \
   "$(q "SELECT customer_ref FROM v_order_customer_history WHERE order_ref='O-101' AND iscurrent=1")" "C001"
later M09 "repoint: old pairing end-dated by LEAD, never updated" \
   "$(q "SELECT end_ts FROM v_order_customer_history WHERE order_ref='O-101' AND customer_ref='C002'")" "2027-02-01 08:00:00"
later M09 "repoint: restatement control kept every attribute silent" \
   "$(q "SELECT COUNT(*) FROM OD_AMT_Order_Amount WHERE ChangedAt='2027-02-01 08:00:00'")" "0"
before_d7r="$(census)"
feed d7_repoint.sql D7R '2027-02-15 08:00:00' "$HERE/fixtures"
later M09 "re-asserted repoint writes nothing" "$(census)" "$before_d7r"

core_section C14
core C14.1 "$(q "SELECT group_concat(customer_ref||'('||COALESCE(email,'null')||')',' ')
                 FROM (SELECT * FROM v_customer ORDER BY customer_ref)")" "C001(alice@newmail.com)"

banner "2: MODEL  (what Anchor Modeling shows on its own)"

own_section M01 "Manifest and stage after every delivery"
replay M01
own_section M02 "Deterministic anchor surrogates and baseline values"
replay M02
own_section M03 "Attribute grain in typed tables, and restatement control"
replay M03
own_section M04 "Knots: raw code in the archive, label on read"
replay M04
own_section M05 "Existence is data: the EST knot"
replay M05
own_section M06 "Load control: a same-size re-use is rejected too"
replay M06
own_section M07 "make rebuild and the wide archive"
replay M07
own_section M08 "Closed knot domain: an unknown code fails the load"
replay M08
own_section M09 "Historized tie: the re-point appends a pairing"
replay M09

own_section M10 "Unpivoted D0..D5 build the same constellation as the old narrow files"
# Two scratch database pairs, created after every rebuild assertion above
# and never read by one. The wide files go through load_feed.sh; the old
# narrow deliveries (tests/fixtures/narrow) go straight into the narrow
# stage and through apply_delivery.sh (level 2). Stage row counts differ
# (D4: 8 unpivoted vs 5 narrow); the loaded result may not.
SAVE_DB="$DB"; SAVE_ARCHIVE_DB="$ARCHIVE_DB"
SEQ="d0_baseline B0 2026-02-05 08:00:00
d1_cust_win_day60 D1 2026-03-02 08:00:00
d2_prod_full_v2 D2 2026-03-02 09:00:00
d3_cust_tombstone D3 2026-03-16 08:00:00
d4_cust_recency D4 2026-04-02 08:00:00
d5_cust_yearly_full D5 2026-12-31 08:00:00"
export DB="$LOGDIR/wide.db" ARCHIVE_DB="$LOGDIR/wide_archive.db"
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null 2>&1
while read -r n id d t; do
  BATCH_TS="$d $t" "$PROJ/scripts/load_feed.sh" "$PROJ/source/$n.sql" "$id" >/dev/null 2>&1
done <<< "$SEQ"
wide_snap="$(snap)"; wide_keys="$(all_keys)"
export DB="$LOGDIR/narrow_ref.db" ARCHIVE_DB="$LOGDIR/narrow_ref_archive.db"
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null 2>&1
while read -r n id d t; do
  "$SQLITE" "$DB" "DELETE FROM source_landing_stage;"; "$SQLITE" "$DB" < "$HERE/fixtures/narrow/$n.sql"
  BATCH_TS="$d $t" "$PROJ/scripts/apply_delivery.sh" >/dev/null 2>&1
done <<< "$SEQ"
own "same anchor surrogates from the old narrow files" "$(all_keys)" "$wide_keys"
own "same constellation (anchors, attributes, ties, ChangedAt) from the old narrow files" "$(snap)" "$wide_snap"

own_section M11 "Recency tiebreak survives replay (wide fixture d6_tiebreak_wide.sql)"
# C004 arrives twice in one delivery with an identical extract_dt: only
# the LAST row in the file may win, on ingest and again after rebuild.
export DB="$LOGDIR/tie.db" ARCHIVE_DB="$LOGDIR/tie_archive.db"
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null 2>&1
BATCH_TS='2027-02-01 08:00:00' "$PROJ/scripts/load_feed.sh" "$HERE/fixtures/d6_tiebreak_wide.sql" D6 >/dev/null 2>&1
own "ingest: equal extract_ts -> last row in the file wins" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C004'")" "last@x.com"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1
own "after rebuild: rowid tiebreak preserved" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C004'")" "last@x.com"
export DB="$SAVE_DB" ARCHIVE_DB="$SAVE_ARCHIVE_DB"

own_section M12 "Level 1: the wide -> narrow transform (stage_narrow.sh)"
# Own scratch database: wide rows go straight into the wide stage and only
# stage_narrow.sh runs -- no loader, no archive, nothing a rebuild reads.
SAVE_DB="$DB"; SAVE_ARCHIVE_DB="$ARCHIVE_DB"
export DB="$LOGDIR/level1.db" ARCHIVE_DB="$LOGDIR/level1_archive.db"
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null 2>&1
q "INSERT INTO stg_customer_l1(customer_id,full_name,email_addr,signup_date,extract_dt,op,load_mode) VALUES
     ('C1','Ann',NULL,'2026-01-01','2026-05-01','UPSERT','INCREMENTAL'),
     ('C1','Ann','b@x','2026-01-01','2026-05-01','UPSERT','INCREMENTAL'),
     ('C2',NULL,NULL,NULL,'2026-05-01','DELETE','INCREMENTAL');
   INSERT INTO stg_product_l1(sku,prod_name,price,currency,extract_dt,op,load_mode) VALUES
     ('S1','Thing',2.5,'EUR','2026-05-01','UPSERT','FULL');
   INSERT INTO stg_order_l1(order_ref,customer_ref,status,amount,currency,placed_at,extract_dt,op,load_mode) VALUES
     ('O1','C1','P',7.25,'USD','2026-04-30 09:00','2026-05-01','UPSERT','INCREMENTAL');
   INSERT INTO stg_order_line_l1(order_ref,sku,extract_dt,op,load_mode) VALUES
     ('O1','S1','2026-05-01','UPSERT','INCREMENTAL');" >/dev/null
"$PROJ/scripts/stage_narrow.sh" >/dev/null 2>&1
# typeof() of value_str/value_num/value_ts, per attribute, in emitted order.
types(){ q "SELECT group_concat(attribute_name||':'||typeof(value_str)||'/'||typeof(value_num)||'/'||typeof(value_ts),' ')
            FROM (SELECT * FROM source_landing_stage WHERE business_key='$1' ORDER BY rowid)"; }
own "level 1: 6 wide rows -> 21 narrow rows (customer 4+4+1, product 4, order 6, line 2)" \
   "$(q 'SELECT COUNT(*) FROM source_landing_stage')" "21"
own "level 1: type routing, customer (signup_date -> value_ts; empty email -> all NULL)" "$(types C1)" \
   "customer_ref:text/null/null full_name:text/null/null email_addr:null/null/null signup_date:null/null/text customer_ref:text/null/null full_name:text/null/null email_addr:text/null/null signup_date:null/null/text"
own "level 1: type routing, product (price -> value_num, currency -> value_str)" "$(types S1)" \
   "sku:text/null/null prod_name:text/null/null price:null/real/null currency:text/null/null"
own "level 1: type routing, order (amount -> value_num, placed_at -> value_ts)" "$(types O1)" \
   "order_ref:text/null/null customer_ref:text/null/null status:text/null/null amount:null/real/null currency:text/null/null placed_at:null/null/text"
own "level 1: signup_date lands in value_ts" \
   "$(q "SELECT DISTINCT value_ts FROM source_landing_stage WHERE business_key='C1' AND attribute_name='signup_date'")" "2026-01-01"
own "level 1: derived key rows (customer_ref=C1, sku=S1, order_ref=O1)" \
   "$(q "SELECT group_concat(a||'='||v,' ') FROM (SELECT attribute_name a, value_str v, MIN(rowid) r
         FROM source_landing_stage
         WHERE (business_key,attribute_name) IN (VALUES ('C1','customer_ref'),('S1','sku'),('O1','order_ref'))
         GROUP BY 1,2 ORDER BY r)")" "customer_ref=C1 sku=S1 order_ref=O1"
own "level 1: order line keyed order_ref~sku, carrying both ends" \
   "$(types 'O1~S1')|$(q "SELECT group_concat(value_str,',') FROM (SELECT value_str FROM source_landing_stage WHERE business_key='O1~S1' ORDER BY rowid)")" \
   "order_ref:text/null/null sku:text/null/null|O1,S1"
own "level 1: empty column -> a row holding SQL NULL (not skipped, not the string)" \
   "$(q "SELECT COUNT(*)||'/'||typeof(MAX(value_str)) FROM source_landing_stage
         WHERE business_key='C1' AND attribute_name='email_addr' AND value_str IS NULL")" "1/null"
own "level 1: no value is ever the string 'NULL'" \
   "$(q "SELECT COUNT(*) FROM source_landing_stage WHERE 'NULL' IN (value_str, value_ts)")" "0"
own "level 1: a DELETE emits exactly one _tombstone row, op DELETE" \
   "$(q "SELECT COUNT(*)||'|'||MAX(attribute_name)||'|'||MAX(op) FROM source_landing_stage WHERE business_key='C2'")" "1|_tombstone|DELETE"
own "level 1: order is feed, then wide row, then attribute position" \
   "$(q "SELECT group_concat(e,',') FROM (SELECT source_entity e, MIN(rowid) r FROM source_landing_stage GROUP BY 1 ORDER BY r)")|$(q "SELECT group_concat(attribute_name,',') FROM (SELECT attribute_name FROM source_landing_stage WHERE business_key='C1' ORDER BY rowid)")" \
   "CUSTOMER,PRODUCT,ORDER,ORDER_LINE|customer_ref,full_name,email_addr,signup_date,customer_ref,full_name,email_addr,signup_date"
own "level 1: within one (key, attribute) the later wide row gets the later rowid" \
   "$(q "SELECT COALESCE(value_str,'<null>') FROM source_landing_stage WHERE business_key='C1' AND attribute_name='email_addr' ORDER BY rowid DESC LIMIT 1")" "b@x"
first_pass="$(q 'SELECT * FROM source_landing_stage ORDER BY rowid')"
"$PROJ/scripts/stage_narrow.sh" >/dev/null 2>&1
own "level 1: re-running stage_narrow emits identical rows (it clears first, order is fixed)" \
   "$(q 'SELECT * FROM source_landing_stage ORDER BY rowid')" "$first_pass"
# The shared corpus: every row of every old narrow delivery is reproduced.
# Only D4 emits more (8 vs 5): wide sends C003's whole record twice.
for n in d0_baseline d1_cust_win_day60 d2_prod_full_v2 d3_cust_tombstone d4_cust_recency d5_cust_yearly_full; do
  q "DELETE FROM stg_customer_l1; DELETE FROM stg_product_l1; DELETE FROM stg_order_l1; DELETE FROM stg_order_line_l1;
     DROP TABLE IF EXISTS narrow_ref; CREATE TABLE narrow_ref AS SELECT * FROM source_landing_stage WHERE 0;" >/dev/null
  "$SQLITE" "$DB" < "$PROJ/source/$n.sql"
  sed 's/INSERT INTO source_landing_stage/INSERT INTO narrow_ref/' "$HERE/fixtures/narrow/$n.sql" | "$SQLITE" "$DB"
  "$PROJ/scripts/stage_narrow.sh" >/dev/null 2>&1
  own "level 1: unpivoted $n reproduces every row of the old narrow file" \
     "$(q "SELECT COUNT(*) FROM (SELECT * FROM narrow_ref EXCEPT SELECT * FROM source_landing_stage)")/$(q 'SELECT COUNT(*) FROM narrow_ref')" \
     "0/$(q 'SELECT COUNT(*) FROM narrow_ref')"
done

own_section M13 "Level 2: the narrow loaders, fed narrow rows directly"
# Narrow-by-nature fixtures go straight into source_landing_stage and
# through apply_delivery.sh. They bypass load_feed.sh and the wide archive,
# so they run in their own scratch database that no rebuild ever reads.
export DB="$LOGDIR/level2.db" ARCHIVE_DB="$LOGDIR/level2_archive.db"
l2(){ "$SQLITE" "$DB" "DELETE FROM source_landing_stage;"; "$SQLITE" "$DB" < "$1"
      BATCH_TS="$2" "$PROJ/scripts/apply_delivery.sh" >/dev/null 2>&1; }
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null 2>&1
l2 "$HERE/fixtures/d6_tiebreak.sql" '2027-02-01 08:00:00'
own "level 2: equal extract_ts -> the last narrow row wins (attribute-level tiebreak)" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C004'")" "last@x.com"
l2 "$HERE/fixtures/narrow/d4_cust_recency.sql" '2027-02-02 08:00:00'
own "level 2: per-attribute recency -- newest extract_ts wins, not MAX" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C003'")" "new@x.com"
export DB="$SAVE_DB" ARCHIVE_DB="$SAVE_ARCHIVE_DB"


own_section M14 "Load control: a file_id names CONTENT (same block in all ten suites)"
# Own database pair, so these deliveries never reach the main archive or
# any rebuild assertion. The crash is simulated at the last step of
# load_feed.sh -- marking the delivery COMPLETE -- which is the same
# statement in every model: the loaders have run, the id stays STARTED.
SAVE_DB="$DB"; SAVE_ARCHIVE_DB="$ARCHIVE_DB"
export DB="$LOGDIR/reuse.db" ARCHIVE_DB="$LOGDIR/reuse_archive.db"
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null 2>&1
R_ORIG="$PROJ/source/d1_cust_win_day60.sql"     # the content X1 names
R_MORE="$PROJ/source/d4_cust_recency.sql"       # a different row count
R_EDIT="$LOGDIR/reuse_edited.sql"               # same rows, one value changed
sed 's/alice@newmail\.com/alice@changed.com/' "$R_ORIG" > "$R_EDIT"
cat > "$LOGDIR/crash_sqlite" <<SH
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in *"SET status='COMPLETE'"*)
  echo "simulated crash before COMPLETE" >&2; exit 1;; esac; done
exec "$SQLITE" "\$@"
SH
chmod +x "$LOGDIR/crash_sqlite"
reuse(){ local rc=0; BATCH_TS='2026-03-02 08:00:00' "$PROJ/scripts/load_feed.sh" "$1" X1 \
           >"$LOGDIR/reuse.log" 2>&1 || rc=$?; printf '%s' "$rc"; }
x1_status(){ "$SQLITE" "$ARCHIVE_DB" "SELECT COALESCE((SELECT status FROM loaded_files WHERE file_id='X1'),'<none>')" 2>&1; }
rejected(){ [ "$1" -ne 0 ] && grep -q '^FATAL' "$LOGDIR/reuse.log" && echo rejected || echo "accepted (exit $1)"; }
# Archive + warehouse, minus the transient stage (a rejected file stays
# staged as forensics, exactly like a crashed one).
frozen(){ "$SQLITE" "$ARCHIVE_DB" .dump; echo "-- warehouse --"
          "$SQLITE" "$DB" .dump | grep -vE '^INSERT INTO "?(stg_[a-z0-9_]+|source_landing_stage)"? '; }

rc="$(SQLITE="$LOGDIR/crash_sqlite" reuse "$R_ORIG")"
own "reuse: crashed delivery X1 is left STARTED" \
   "$([ "$rc" -ne 0 ] && echo crashed)/$(x1_status)" "crashed/STARTED"
before="$(frozen)"
own "reuse: STARTED X1 re-sent with a different row count is REJECTED" "$(rejected "$(reuse "$R_MORE")")" "rejected"
own "reuse:   ... archive and warehouse untouched" "$(frozen)" "$before"
own "reuse: STARTED X1 re-sent with the same row count, one value changed, is REJECTED" \
   "$(rejected "$(reuse "$R_EDIT")")" "rejected"
own "reuse:   ... archive and warehouse untouched" "$(frozen)" "$before"
own "reuse: STARTED X1 re-sent with its original content retries to COMPLETE" \
   "$(reuse "$R_ORIG")/$(x1_status)" "0/COMPLETE"
before="$(frozen)"
own "reuse: COMPLETE X1 re-sent with the same row count, one value changed, is REJECTED" \
   "$(rejected "$(reuse "$R_EDIT")")" "rejected"
own "reuse:   ... archive and warehouse untouched" "$(frozen)" "$before"
own "reuse: COMPLETE X1 re-sent with a different row count is REJECTED" "$(rejected "$(reuse "$R_MORE")")" "rejected"
own "reuse:   ... archive and warehouse untouched" "$(frozen)" "$before"
own "reuse: COMPLETE X1 re-sent with its original content is skipped" \
   "$(reuse "$R_ORIG")/$(grep -c 'SKIP duplicate' "$LOGDIR/reuse.log")" "0/1"
own "reuse:   ... archive and warehouse untouched" "$(frozen)" "$before"
# A crash BEFORE the archive write leaves an id STARTED with nothing
# archived, so there is no content to compare; the manifest's row count
# is the only record, and it must still hold.
cat > "$LOGDIR/crash_sqlite_early" <<SH
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in *"INSERT OR IGNORE INTO arch."*)
  echo "simulated crash before the archive write" >&2; exit 1;; esac; done
exec "$SQLITE" "\$@"
SH
chmod +x "$LOGDIR/crash_sqlite_early"
x2(){ local rc=0; BATCH_TS='2026-03-02 08:00:00' "$PROJ/scripts/load_feed.sh" "$1" X2 \
        >"$LOGDIR/reuse.log" 2>&1 || rc=$?; printf '%s' "$rc"; }
x2_state(){ "$SQLITE" "$ARCHIVE_DB" "SELECT COALESCE((SELECT status FROM loaded_files WHERE file_id='X2'),'<none>')" 2>&1; }
rc="$(SQLITE="$LOGDIR/crash_sqlite_early" x2 "$R_ORIG")"
own "reuse: delivery X2 crashed before the archive write is left STARTED" \
   "$([ "$rc" -ne 0 ] && echo crashed)/$(x2_state)" "crashed/STARTED"
before="$(frozen)"
own "reuse: STARTED X2 (nothing archived) re-sent with a different row count is REJECTED" \
   "$(rejected "$(x2 "$R_MORE")")" "rejected"
own "reuse:   ... archive and warehouse untouched" "$(frozen)" "$before"
own "reuse: STARTED X2 re-sent with its original content retries to COMPLETE" \
   "$(x2 "$R_ORIG")/$(x2_state)" "0/COMPLETE"
export DB="$SAVE_DB" ARCHIVE_DB="$SAVE_ARCHIVE_DB"

rm -f "$DB" "$ARCHIVE_DB"
summary
