#!/usr/bin/env bash
# =====================================================================
# One Big Table test suite -- the shared delivery scenarios computed by
# full refresh over the log, plus the pattern's honest edges: raw codes
# translated per-consumer, history only by diffing, and an archive that
# stores everything again on every FULL delivery.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/obt_test).db}"
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

snap(){ q "
  SELECT 'c', customer_ref, COALESCE(full_name,'')||'/'||COALESCE(email,'') FROM obt_customer
  UNION ALL SELECT 'p', sku, COALESCE(product_name,'')||'/'||COALESCE(price,'') FROM obt_product
  UNION ALL SELECT 'o', order_ref, COALESCE(customer_ref,'')||'/'||COALESCE(status,'')||'/'||COALESCE(amount,'') FROM obt_orders
  UNION ALL SELECT 'w', order_ref||'/'||sku, COALESCE(customer_name,'')||'/'||COALESCE(product_name,'') FROM obt_order_wide
  ORDER BY 1,2;"; }

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
  [ "$SKIPPED" -eq 0 ] && ck "[$file_id] manifest: COMPLETE after the refresh" \
     "$(aq "SELECT status FROM arch.loaded_files WHERE file_id='$file_id'")" "COMPLETE"
  ck "[$file_id] stage blank after delivery" \
     "$(q "SELECT (SELECT COUNT(*) FROM stg_customer_l1)+(SELECT COUNT(*) FROM stg_product_l1)
                +(SELECT COUNT(*) FROM stg_order_l1)+(SELECT COUNT(*) FROM stg_order_line_l1)")" "0"; }

echo "== Fresh db + archive =="; rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null

echo; echo "== D0: FULL baseline =="
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
ck "baseline: 2 customers, 3 products, 2 orders" \
   "$(q "SELECT (SELECT COUNT(*) FROM obt_customer)||'/'||(SELECT COUNT(*) FROM obt_product)||'/'||(SELECT COUNT(*) FROM obt_orders)")" "2/3/2"
ck "baseline: the wide table is at order-line grain (3 rows)" \
   "$(q 'SELECT COUNT(*) FROM obt_order_wide')" "3"
ck "baseline: C001 email v1" "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@example.com"
ck "raw code stored, translated per-consumer in the view" \
   "$(q "SELECT (SELECT status FROM obt_orders WHERE order_ref='O-100')||'/'||
              (SELECT status FROM v_order WHERE order_ref='O-100')")" "P/PENDING"

echo; echo "== D1: CRM 14-day INCREMENTAL window (C001 changed; C002 absent) =="
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
ck "latest: C001 email updated" "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@newmail.com"
ck "INCREMENTAL: C002 NOT deleted (60-day stale)" \
   "$(q "SELECT COUNT(*) FROM obt_customer WHERE customer_ref='C002'")" "1"
ck "INCREMENTAL: C002 email unchanged" "$(q "SELECT email FROM v_customer WHERE customer_ref='C002'")" "bob@example.com"

echo; echo "== D2: PIM FULL snapshot (SKU-3 discontinued) =="
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
ck "FULL: SKU-3 deleted by absence (a later FULL outranks its last mention)" \
   "$(q "SELECT COUNT(*) FROM obt_product WHERE sku='SKU-3'")" "0"
ck "FULL: SKU-1 price 8.99" "$(q "SELECT price FROM v_product WHERE sku='SKU-1'")" "8.99"
ck "NO NOCHANGE SUPPRESSION: unchanged SKU-2 stored again anyway (2 archive rows)" \
   "$(aq "SELECT COUNT(*) FROM arch.hist_product WHERE sku='SKU-2'")" "2"

echo; echo "== D3: INCREMENTAL tombstone deletes C002 =="
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
ck "tombstone: C002 gone from the latest table" \
   "$(q "SELECT COUNT(*) FROM obt_customer WHERE customer_ref='C002'")" "0"
ck "tombstone: O-101 placed_by now NULL" \
   "$(q "SELECT COALESCE(placed_by,'<none>') FROM v_order WHERE order_ref='O-101'")" "<none>"
ck "Bob survives ONLY in the log (no model keeps him queryable)" \
   "$(aq "SELECT COUNT(*) FROM arch.hist_customer WHERE customer_id='C002' AND full_name='Bob Jones'")" "1"

echo; echo "== D4: INCREMENTAL adds C003; recency de-dup inside one delivery =="
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
ck "recency: newest email wins (not MAX)" "$(q "SELECT email FROM v_customer WHERE customer_ref='C003'")" "new@x.com"

echo; echo "== Load control: re-deliver D1 (same file_id) must be skipped =="
before="$(snap)"; abefore="$(aq 'SELECT COUNT(*) FROM arch.hist_customer')"
feed d1_cust_win_day60.sql D1 '2026-04-10 08:00:00'
ck "dup file skipped: latest tables unchanged" "$(snap)" "$before"
ck "dup file skipped: archive unchanged"       "$(aq 'SELECT COUNT(*) FROM arch.hist_customer')" "$abefore"

echo; echo "== D5: YEARLY FULL reconciliation (C003 gone at source) =="
feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'
ck "reconcile: C003 deleted by absence (FULL)" \
   "$(q "SELECT COUNT(*) FROM obt_customer WHERE customer_ref='C003'")" "0"
ck "reconcile: only C001 remains" "$(q "SELECT group_concat(customer_ref,',') FROM obt_customer")" "C001"
ck "reconcile: C002 stays deleted (tombstone still outranked by nothing)" \
   "$(q "SELECT COUNT(*) FROM obt_customer WHERE customer_ref='C002'")" "0"

echo; echo "== Honest idempotence: same content, NEW file_id =="
# The derived tables must not change -- but the ARCHIVE GROWS: OBT has
# no NOCHANGE concept, a re-delivery is stored again. Both facts assert.
before_r="$(snap)"; abefore_r="$(aq 'SELECT COUNT(*) FROM arch.hist_customer')"
feed d5_cust_yearly_full.sql D5R '2027-01-10 08:00:00'
ck "re-asserted state: latest tables unchanged" "$(snap)" "$before_r"
ck "  ...but the archive grew by the full re-delivery (+1 wide row)" \
   "$(aq 'SELECT COUNT(*) FROM arch.hist_customer')" "$((abefore_r + 1))"

echo; echo "== Archive: append-only is absolute =="
ck "archive captured every delivered row" \
   "$(aq "SELECT (SELECT COUNT(*) FROM arch.hist_customer)+(SELECT COUNT(*) FROM arch.hist_product)
              +(SELECT COUNT(*) FROM arch.hist_order)+(SELECT COUNT(*) FROM arch.hist_order_line)")" \
   "$(aq 'SELECT SUM(row_count) FROM arch.loaded_files')"
ck_abort "UPDATE on hist_customer aborts" "UPDATE hist_customer SET full_name='x';" "append-only"
ck_abort "DELETE on hist_order aborts"    "DELETE FROM hist_order;" "append-only"

echo; echo "== Rebuild: init + ONE refresh (nothing incremental to replay) =="
ingested="$(snap)"
rm -f "$DB"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
ck "clean+rebuild: identical latest tables from the log alone" "$(snap)" "$ingested"

echo; echo "== History = diffing the log (works, but is a query, not a table) =="
ck "C001's email history recovered via LAG over the archive" \
   "$(aq "SELECT group_concat(email_addr,'>') FROM (
            SELECT email_addr, LAG(email_addr) OVER (
              ORDER BY load_seq, extract_dt, seq_nbr) AS prev
            FROM arch.hist_customer WHERE customer_id='C001' AND op='UPSERT')
          WHERE prev IS NULL OR email_addr IS NOT prev")" \
   "alice@example.com>alice@newmail.com"

echo; echo "== Restatement: OMS re-points O-101 -> latest simply wins =="
feed d6_repoint.sql D6 '2027-02-01 08:00:00' "$HERE/fixtures"
ck "repoint: O-101 now belongs to C001, effortlessly" \
   "$(q "SELECT customer_ref FROM obt_orders WHERE order_ref='O-101'")" "C001"
ck "repoint: placed_by resolves to Alice Smith" \
   "$(q "SELECT placed_by FROM v_order WHERE order_ref='O-101'")" "Alice Smith"
ck "repoint: the prior pairing survives only in the log" \
   "$(aq "SELECT COUNT(*) FROM arch.hist_order WHERE order_ref='O-101' AND customer_ref='C002'")" "1"

echo; echo "====================================================================="
printf "  RESULT: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "====================================================================="
rm -f "$DB" "$ARCHIVE_DB"
[ "$FAIL" -eq 0 ] || exit 1
