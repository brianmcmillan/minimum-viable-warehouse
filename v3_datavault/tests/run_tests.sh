#!/usr/bin/env bash
# =====================================================================
# Data Vault 2.0 test suite -- the Focal demo's scenarios, replayed
# against a vault. Same deliveries, same safety rule (absence deletes
# only under FULL), plus the DV-specific behaviours: whole-row satellite
# grain, raw values preserved under soft rules, and driving-key
# effectivity on links. Pure shell + sqlite3, no other deps.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
# No `set -e`: every assertion must run so one failure doesn't hide the rest.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/dv_test).db}"
PASS=0; FAIL=0; FEED_N=0; SKIPPED=0
LOGDIR="$(mktemp -d)"; trap 'rm -rf "$LOGDIR"' EXIT

q(){ local out rc=0
     out="$("$SQLITE" "$DB" "$1" 2>&1)" || rc=$?
     if [ "$rc" -ne 0 ]; then
       printf "  \033[31mSQL ERROR\033[0m (exit %d): %s\n    query: %s\n" "$rc" "$out" "$1" >&2
       printf '<SQL-ERROR>'; return 0
     fi
     printf '%s' "$out"; }
ck(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1";
      else FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s  (got '%s', expected '%s')\n" "$1" "$2" "$3"; fi; }

# Row census across every vault table, compared as one string so a
# failure names the table that grew.
census(){ q "SELECT group_concat(t||'='||n,' ') FROM (
    SELECT 1 o,'cust_h'   t,COUNT(*) n FROM rv_customer_h
    UNION ALL SELECT 2,'cust_hsat', COUNT(*) FROM rv_customer_hsat
    UNION ALL SELECT 3,'cust_sts',  COUNT(*) FROM rv_customer_sts
    UNION ALL SELECT 4,'prod_h',    COUNT(*) FROM rv_product_h
    UNION ALL SELECT 5,'prod_hsat', COUNT(*) FROM rv_product_hsat
    UNION ALL SELECT 6,'prod_sts',  COUNT(*) FROM rv_product_sts
    UNION ALL SELECT 7,'ord_h',     COUNT(*) FROM rv_order_h
    UNION ALL SELECT 8,'ord_hsat',  COUNT(*) FROM rv_order_hsat
    UNION ALL SELECT 9,'ord_sts',   COUNT(*) FROM rv_order_sts
    UNION ALL SELECT 10,'oc_l',     COUNT(*) FROM rv_order_customer_l
    UNION ALL SELECT 11,'op_l',     COUNT(*) FROM rv_order_product_l
    UNION ALL SELECT 12,'oc_eff',   COUNT(*) FROM bv_order_customer_l_effsat
    ORDER BY o);"; }

# Run one delivery; abort the suite if a loader crashes (past that point
# every assertion measures a half-loaded database, not the code).
feed(){ local src="$1" file_id="$2" ts="$3" rc=0 log dir="${4:-$PROJ/source}"
  FEED_N=$((FEED_N+1)); log="$LOGDIR/$FEED_N-$file_id.log"
  BATCH_TS="$ts" "$PROJ/scripts/load_feed.sh" "$dir/$src" "$file_id" >"$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf "\n  \033[31mABORT\033[0m load_feed.sh exited %d at delivery %s (%s)\n" "$rc" "$file_id" "$src"
    sed 's/^/  | /' "$log"
    printf "\n  %d passed, %d failed before the abort.\n" "$PASS" "$FAIL"; exit 1
  fi
  if grep -q 'SKIP duplicate' "$log"; then SKIPPED=1; else SKIPPED=0; fi
  ck "[$file_id] audit: recorded exactly once" \
     "$(q "SELECT COUNT(*) FROM dv_load_audit WHERE file_id='$file_id'")" "1"
  [ "$SKIPPED" -eq 0 ] && ck "[$file_id] audit: COMPLETE after all loaders" \
     "$(q "SELECT status FROM dv_load_audit WHERE file_id='$file_id'")" "COMPLETE"
  # Standing invariant: a delivery that returned success left the stage
  # blank. Residue after exit 0 would mean either the success-clear was
  # lost, or a failure was misreported as success.
  ck "[$file_id] stage blank after delivery" \
     "$(q "SELECT (SELECT COUNT(*) FROM stg_customer_l1)+(SELECT COUNT(*) FROM stg_product_l1)
                +(SELECT COUNT(*) FROM stg_order_l1)+(SELECT COUNT(*) FROM stg_order_line_l1)")" "0"; }

sts(){ q "SELECT sts FROM v_customer_sts_current WHERE customer_bk='$1'"; }

echo "== Fresh db =="; rm -f "$DB"; "$PROJ/scripts/init_db.sh" >/dev/null

echo; echo "== D0: FULL baseline =="
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
ck "baseline: 2 customer keys"   "$(q 'SELECT COUNT(*) FROM rv_customer_h')" "2"
ck "baseline: 3 product keys"    "$(q 'SELECT COUNT(*) FROM rv_product_h')" "3"
ck "baseline: 2 order keys"      "$(q 'SELECT COUNT(*) FROM rv_order_h')" "2"
ck "baseline: C001 email v1"     "$(q "SELECT email FROM dim_customer WHERE customer_ref='C001'")" "alice@example.com"
ck "baseline: 2 current order->customer pairings" \
   "$(q 'SELECT COUNT(*) FROM v_order_customer_current')" "2"
ck "RAW: vault stores source code 'P', mart translates" \
   "$(q "SELECT (SELECT status FROM rv_order_hsat WHERE order_bk='O-100')||'/'||
              (SELECT status FROM fact_order WHERE order_ref='O-100')")" "P/PENDING"

echo; echo "== D1: CRM 14-day INCREMENTAL window (C001 changed; C002 absent) =="
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
ck "INCREMENTAL: C001 email updated"              "$(q "SELECT email FROM dim_customer WHERE customer_ref='C001'")" "alice@newmail.com"
ck "INCREMENTAL: C002 NOT deleted (60-day stale)" "$(sts C002)" "I"
ck "INCREMENTAL: C002 email unchanged"            "$(q "SELECT email FROM dim_customer WHERE customer_ref='C002'")" "bob@example.com"
ck "INCREMENTAL: C002 no sat churn (1 row)"       "$(q "SELECT COUNT(*) FROM rv_customer_hsat WHERE customer_bk='C002'")" "1"
ck "grain: C001 change = ONE whole-row sat version (2 total)" \
   "$(q "SELECT COUNT(*) FROM rv_customer_hsat WHERE customer_bk='C001'")" "2"

echo; echo "== D2: PIM FULL snapshot (SKU-3 discontinued) =="
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
ck "FULL: SKU-3 deleted on absence (sts='D')" \
   "$(q "SELECT sts FROM v_product_sts_current WHERE product_bk='SKU-3'")" "D"
ck "FULL: SKU-3 hub key remains (insert-only)" \
   "$(q "SELECT COUNT(*) FROM rv_product_h WHERE product_bk='SKU-3'")" "1"
ck "FULL: SKU-3 history remains in its satellite" \
   "$(q "SELECT COUNT(*) FROM rv_product_hsat WHERE product_bk='SKU-3'")" "1"
ck "FULL: SKU-3 gone from dim_product" \
   "$(q "SELECT COUNT(*) FROM dim_product WHERE sku='SKU-3'")" "0"
ck "FULL: SKU-1 price changed 8.99"  "$(q "SELECT price FROM dim_product WHERE sku='SKU-1'")" "8.99"
ck "FULL: SKU-2 unchanged -> hashdiff wrote nothing (1 row)" \
   "$(q "SELECT COUNT(*) FROM rv_product_hsat WHERE product_bk='SKU-2'")" "1"

echo; echo "== D3: INCREMENTAL tombstone deletes C002 =="
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
ck "tombstone: C002 sts='D'"                "$(sts C002)" "D"
ck "tombstone: C002 gone from dim_customer" "$(q "SELECT COALESCE((SELECT email FROM dim_customer WHERE customer_ref='C002'),'<none>')")" "<none>"
ck "tombstone: O-101 placed_by now NULL"    "$(q "SELECT COALESCE((SELECT placed_by FROM fact_order WHERE order_ref='O-101'),'<none>')")" "<none>"
ck "tombstone: C002 attribute history intact" \
   "$(q "SELECT full_name FROM rv_customer_hsat WHERE customer_bk='C002'")" "Bob Jones"

echo; echo "== D4: INCREMENTAL adds C003; recency de-dup at stage 2 =="
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
ck "recency: newest email wins (not MAX)" "$(q "SELECT email FROM dim_customer WHERE customer_ref='C003'")" "new@x.com"
ck "recency: one delivery -> one sat row" "$(q "SELECT COUNT(*) FROM rv_customer_hsat WHERE customer_bk='C003'")" "1"

echo; echo "== Load control: re-deliver D1 (same file_id) must be skipped =="
before="$(census)"
feed d1_cust_win_day60.sql D1 '2026-04-10 08:00:00'
ck "dup file skipped: vault unchanged" "$(census)" "$before"

echo; echo "== D5: YEARLY FULL reconciliation (C003 gone at source) =="
feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'
ck "reconcile: C003 deleted by absence (FULL)" "$(sts C003)" "D"
ck "reconcile: C001 survives"                  "$(q "SELECT email FROM dim_customer WHERE customer_ref='C001'")" "alice@newmail.com"
ck "reconcile: C002 stays deleted"             "$(sts C002)" "D"
ck "reconcile: C001 unchanged content -> NO new sat row (still 2)" \
   "$(q "SELECT COUNT(*) FROM rv_customer_hsat WHERE customer_bk='C001'")" "2"

echo; echo "== Contrast: absence deletes under FULL, never under INCREMENTAL =="
ck "C002 presence timeline is exactly I -> D (2 assertions)" \
   "$(q "SELECT group_concat(sts,'') FROM (SELECT sts FROM rv_customer_sts WHERE customer_bk='C002' ORDER BY ldts)")" "ID"

echo; echo "== Idempotence: replaying the whole sequence must change nothing =="
census_0="$(census)"
feed d0_baseline.sql         B0 '2027-01-05 08:00:00'
feed d1_cust_win_day60.sql   D1 '2027-01-05 08:01:00'
feed d2_prod_full_v2.sql     D2 '2027-01-05 08:02:00'
feed d3_cust_tombstone.sql   D3 '2027-01-05 08:03:00'
feed d4_cust_recency.sql     D4 '2027-01-05 08:04:00'
feed d5_cust_yearly_full.sql D5 '2027-01-05 08:05:00'
ck "replay: zero new vault rows" "$(census)" "$census_0"

echo; echo "== Driving key: OMS re-points O-101 from C002 to C001 =="
feed d6_repoint.sql D6 '2027-02-01 08:00:00' "$HERE/fixtures"
ck "repoint: O-101 current customer is C001" \
   "$(q "SELECT customer_bk FROM v_order_customer_current WHERE order_bk='O-101'")" "C001"
ck "repoint: exactly ONE current pairing for O-101" \
   "$(q "SELECT COUNT(*) FROM v_order_customer_eff_history WHERE order_bk='O-101' AND iscurrent=1")" "1"
ck "repoint: old pairing end-dated by LEAD, not updated" \
   "$(q "SELECT end_date FROM v_order_customer_eff_history WHERE order_bk='O-101' AND customer_bk='C002'")" "2027-02-01 08:00:00"
ck "repoint: link table keeps BOTH pairs (insert-only history)" \
   "$(q "SELECT COUNT(*) FROM rv_order_customer_l WHERE order_bk='O-101'")" "2"
ck "repoint: placed_by resolves to Alice Smith" \
   "$(q "SELECT placed_by FROM fact_order WHERE order_ref='O-101'")" "Alice Smith"
ck "repoint: unchanged order attrs -> no new sat row" \
   "$(q "SELECT COUNT(*) FROM rv_order_hsat WHERE order_bk='O-101'")" "1"

echo; echo "== True loader idempotence: same content, NEW file_id, loaders RUN, write nothing =="
# The earlier replay block proves the skip guard (same file_id -> loaders
# never run). This proves the loaders themselves: D6's content re-asserts
# the current state, so every delta -- hub, sat, sts, link, effsat -- must
# come up empty. This is the test that catches an effsat that re-opens an
# already-current pairing.
before_d6r="$(census)"
feed d6_repoint.sql D6R '2027-02-15 08:00:00' "$HERE/fixtures"
ck "re-asserted current state writes zero vault rows" "$(census)" "$before_d6r"

echo; echo "== Soft rule change: retroactive without any reload =="
q "UPDATE dv_load_params SET batch_ts=batch_ts" >/dev/null   # no-op; vault untouched below
ck "raw 'P' still in the vault"          "$(q "SELECT status FROM rv_order_hsat WHERE order_bk='O-100'")" "P"
ck "mart derives PENDING from it today"  "$(q "SELECT status FROM fact_order WHERE order_ref='O-100'")" "PENDING"

echo; echo "====================================================================="
printf "  RESULT: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "====================================================================="
rm -f "$DB"
[ "$FAIL" -eq 0 ] || exit 1
