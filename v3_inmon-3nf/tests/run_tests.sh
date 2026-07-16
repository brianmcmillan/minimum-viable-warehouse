#!/usr/bin/env bash
# =====================================================================
# Inmon 3NF EDW test suite -- the shared delivery scenarios against a
# time-variant normalized core, plus the control-group behaviours:
# conformance at ingest, natural-key FKs (queries see the CURRENT
# customer), range-join point-in-time, and row versioning on repoint.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/edw_test).db}"
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
    SELECT 1 o,'cust' t,COUNT(*) n FROM customer
    UNION ALL SELECT 2,'prod',  COUNT(*) FROM product
    UNION ALL SELECT 3,'ord',   COUNT(*) FROM orders
    UNION ALL SELECT 4,'line',  COUNT(*) FROM order_line
    ORDER BY o);"; }

snap(){ q "
  SELECT 'c', customer_ref, COALESCE(full_name,'')||'/'||COALESCE(email,''),
         valid_from||'/'||valid_to||'/'||is_current||'/'||is_deleted FROM customer
  UNION ALL
  SELECT 'p', sku, COALESCE(product_name,'')||'/'||COALESCE(price,''),
         valid_from||'/'||valid_to||'/'||is_current||'/'||is_deleted FROM product
  UNION ALL
  SELECT 'o', order_ref, COALESCE(customer_ref,'')||'/'||COALESCE(status,'')||'/'||COALESCE(amount,''),
         valid_from||'/'||valid_to||'/'||is_current||'/'||is_deleted FROM orders
  UNION ALL
  SELECT 'l', order_ref, sku, valid_from FROM order_line
  ORDER BY 1,2,4;"; }

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
  [ "$SKIPPED" -eq 0 ] && ck "[$file_id] manifest: COMPLETE after the loader" \
     "$(aq "SELECT status FROM arch.loaded_files WHERE file_id='$file_id'")" "COMPLETE"
  ck "[$file_id] stage blank after delivery" \
     "$(q "SELECT (SELECT COUNT(*) FROM stg_customer_l1)+(SELECT COUNT(*) FROM stg_product_l1)
                +(SELECT COUNT(*) FROM stg_order_l1)+(SELECT COUNT(*) FROM stg_order_line_l1)")" "0"; }

vers(){ q "SELECT COUNT(*) FROM customer WHERE customer_ref='$1'"; }

echo "== Fresh db + archive =="; rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null

echo; echo "== D0: FULL baseline =="
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
ck "baseline: 2 customers, 3 products, 2 orders current" \
   "$(q "SELECT (SELECT COUNT(*) FROM v_customer)||'/'||(SELECT COUNT(*) FROM v_product)||'/'||(SELECT COUNT(*) FROM v_order)")" "2/3/2"
ck "baseline: C001 email v1" "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@example.com"
ck "CONFORMED AT INGEST: EDW stores PENDING, archive keeps raw 'P'" \
   "$(aq "SELECT (SELECT status FROM orders WHERE order_ref='O-100' AND is_current=1)||'/'||
                (SELECT DISTINCT status FROM arch.hist_order WHERE order_ref='O-100')")" "PENDING/P"
ck "3NF: the relationship is a plain natural-key FK column" \
   "$(q "SELECT customer_ref FROM orders WHERE order_ref='O-100' AND is_current=1")" "C001"

echo; echo "== D1: CRM 14-day INCREMENTAL window (C001 changed; C002 absent) =="
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
ck "time-variant: C001 now 2 rows, old one CLOSED (an UPDATE happened)" \
   "$(q "SELECT COUNT(*)||'/'||(SELECT valid_to FROM customer WHERE customer_ref='C001' AND is_current=0)
         FROM customer WHERE customer_ref='C001'")" "2/2026-03-02 08:00:00"
ck "INCREMENTAL: C002 NOT deleted (60-day stale)" \
   "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "1"
ck "INCREMENTAL: C002 zero churn" "$(vers C002)" "1"
ck "NATURAL-KEY JOIN: v_order sees the CURRENT customer, always" \
   "$(q "SELECT placed_by FROM v_order WHERE order_ref='O-100'")" "Alice Smith"

echo; echo "== D2: PIM FULL snapshot (SKU-3 discontinued) =="
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
ck "FULL: SKU-3 closed + deleted-marker row (2 versions)" \
   "$(q "SELECT COUNT(*)||'/'||(SELECT is_deleted FROM product WHERE sku='SKU-3' AND is_current=1)
         FROM product WHERE sku='SKU-3'")" "2/1"
ck "FULL: SKU-3 gone from v_product"  "$(q "SELECT COUNT(*) FROM v_product WHERE sku='SKU-3'")" "0"
ck "FULL: SKU-1 price 8.99 via new version" "$(q "SELECT price FROM v_product WHERE sku='SKU-1'")" "8.99"
ck "FULL: SKU-2 zero churn" "$(q "SELECT COUNT(*) FROM product WHERE sku='SKU-2'")" "1"

echo; echo "== D3: INCREMENTAL tombstone deletes C002 =="
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
ck "tombstone: C002 deleted-marker current" \
   "$(q "SELECT is_deleted FROM customer WHERE customer_ref='C002' AND is_current=1")" "1"
ck "tombstone: C002 gone from v_customer" "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "0"
ck "tombstone: O-101 placed_by now NULL (current join finds nobody)" \
   "$(q "SELECT COALESCE(placed_by,'<none>') FROM v_order WHERE order_ref='O-101'")" "<none>"
ck "RANGE JOIN: as-recorded still answers Bob Jones (the BETWEEN gymnastics)" \
   "$(q "SELECT placed_by_as_recorded FROM v_order_as_recorded
         WHERE order_ref='O-101' AND recorded_at='2026-02-05 08:00:00'")" "Bob Jones"

echo; echo "== D4: INCREMENTAL adds C003; recency de-dup =="
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
ck "recency: newest email wins (not MAX)" "$(q "SELECT email FROM v_customer WHERE customer_ref='C003'")" "new@x.com"
ck "recency: one delivery -> one version" "$(vers C003)" "1"

echo; echo "== Load control: re-deliver D1 (same file_id) must be skipped =="
before="$(census)"
feed d1_cust_win_day60.sql D1 '2026-04-10 08:00:00'
ck "dup file skipped: EDW unchanged" "$(census)" "$before"

echo; echo "== D5: YEARLY FULL reconciliation (C003 gone at source) =="
feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'
ck "reconcile: C003 deleted by absence (FULL)" \
   "$(q "SELECT is_deleted FROM customer WHERE customer_ref='C003' AND is_current=1")" "1"
ck "reconcile: C001 unchanged content -> zero churn (still 2)" "$(vers C001)" "2"
ck "reconcile: C002 already deleted -> zero churn (still 2)"   "$(vers C002)" "2"
ck "reconcile: v_customer shows only C001" \
   "$(q "SELECT group_concat(customer_ref,',') FROM v_customer")" "C001"

echo; echo "== True loader idempotence: same content, NEW file_id, writes nothing =="
before_r="$(census)"
feed d5_cust_yearly_full.sql D5R '2027-01-10 08:00:00'
ck "re-asserted current state writes zero EDW rows" "$(census)" "$before_r"

echo; echo "== Archive: append-only is absolute =="
ck "archive captured every delivered row" \
   "$(aq "SELECT (SELECT COUNT(*) FROM arch.hist_customer)+(SELECT COUNT(*) FROM arch.hist_product)
              +(SELECT COUNT(*) FROM arch.hist_order)+(SELECT COUNT(*) FROM arch.hist_order_line)")" \
   "$(aq 'SELECT SUM(row_count) FROM arch.loaded_files')"
ck_abort "UPDATE on hist_customer aborts" "UPDATE hist_customer SET full_name='x';" "append-only"
ck_abort "DELETE on hist_order aborts"    "DELETE FROM hist_order;" "append-only"

echo; echo "== Rebuild: the EDW is disposable =="
ingested="$(snap)"
rm -f "$DB"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
ck "clean+rebuild: EDW identical" "$(snap)" "$ingested"

echo; echo "== Conformance is retroactively fixable ONLY via the archive =="
# Change the reference data live: already-stored rows keep the OLD label,
# because conformance happened at ingest -- the classic CIF trap.
q "UPDATE order_status_ref SET status_name='PLACED' WHERE status_code='P';" >/dev/null
ck "live rule change does NOT touch stored rows (conformed at ingest)" \
   "$(q "SELECT DISTINCT status FROM v_order")" "PENDING"
# The escape hatch the archive provides: edit the seed, rebuild.
WORK="$(mktemp -d)"; cp -R "$PROJ" "$WORK/proj"; rm -rf "$WORK/proj/build" "$WORK/proj/archive"
sed -i.bak "s/('P','PENDING')/('P','PLACED')/" "$WORK/proj/schema/03_edw.sql"
(
  export DB="$WORK/proj/build/edw.db" ARCHIVE_DB="$WORK/proj/archive/a.db"
  "$WORK/proj/scripts/init_db.sh" >/dev/null 2>&1
  BATCH_TS='2026-02-05 08:00:00' "$WORK/proj/scripts/load_feed.sh" "$WORK/proj/source/d0_baseline.sql" B0 >/dev/null 2>&1
  "$WORK/proj/scripts/rebuild.sh" >/dev/null 2>&1
  "$SQLITE" "$DB" "SELECT DISTINCT status FROM v_order;" > "$WORK/rule.txt"
)
ck "seed edit + rebuild re-derives history under the new rule" "$(cat "$WORK/rule.txt")" "PLACED"
rm -rf "$WORK"

echo; echo "== Restatement: OMS re-points O-101 -> a new ORDER VERSION =="
feed d6_repoint.sql D6 '2027-02-01 08:00:00' "$HERE/fixtures"
ck "repoint: O-101 versioned, not updated in place (2 rows)" \
   "$(q "SELECT COUNT(*) FROM orders WHERE order_ref='O-101'")" "2"
ck "repoint: current version points at C001" \
   "$(q "SELECT customer_ref FROM orders WHERE order_ref='O-101' AND is_current=1")" "C001"
ck "repoint: placed_by resolves to Alice Smith" \
   "$(q "SELECT placed_by FROM v_order WHERE order_ref='O-101'")" "Alice Smith"
ck "repoint: the old pairing survives as order history" \
   "$(q "SELECT customer_ref FROM orders WHERE order_ref='O-101' AND is_current=0")" "C002"
before_d6r="$(census)"
feed d6_repoint.sql D6R '2027-02-15 08:00:00' "$HERE/fixtures"
ck "re-asserted repoint writes nothing" "$(census)" "$before_d6r"

echo; echo "====================================================================="
printf "  RESULT: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "====================================================================="
rm -f "$DB" "$ARCHIVE_DB"
[ "$FAIL" -eq 0 ] || exit 1
