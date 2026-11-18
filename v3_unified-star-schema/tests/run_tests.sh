#!/usr/bin/env bash
# =====================================================================
# Unified Star Schema test suite.
#
# PART 1, CORE: the fourteen sections every one of the ten suites runs,
# in the same order and with the same labels (tests/core_spec.tsv at the
# repo root). Each model supplies its own SQL; the nine question
# answers live in tests/answers/Q<n>.sql.
# PART 2, MODEL: what the USS shows on its own -- tables without foreign
# keys, one bridge stage per table, transitive keys, measures on their
# own stage (no fan trap), every member present (no chasm trap), an
# insert-only core under it, a materialised decode, and the re-point
# re-derived.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/uss_test).db}"
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

# The core tables refuse UPDATE and DELETE too (the shared refused() reads
# the archive): "refused" if the statement fails with the expected message.
db_refused(){ local out; out="$("$SQLITE" "$DB" "$1" 2>&1)"
              case "$out" in *"$2"*) printf 'refused';; *) printf '%s' "$out";; esac; }

census(){ q "SELECT group_concat(t||'='||n,' ') FROM (
    SELECT 1 o,'cust' t,COUNT(*) n FROM core_customer
    UNION ALL SELECT 2,'prod',  COUNT(*) FROM core_product
    UNION ALL SELECT 3,'ord',   COUNT(*) FROM core_order
    UNION ALL SELECT 4,'line',  COUNT(*) FROM core_order_line
    ORDER BY o);"; }
archive_state(){ aq "SELECT (SELECT COUNT(*) FROM arch.loaded_files)||'/'||(SELECT COUNT(*) FROM arch.hist_customer)
                      ||'/'||(SELECT COUNT(*) FROM arch.hist_product)||'/'||(SELECT COUNT(*) FROM arch.hist_order)
                      ||'/'||(SELECT COUNT(*) FROM arch.hist_order_line)"; }

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

# Run one delivery; abort the suite if a loader crashes. Its manifest,
# refresh, stage and bridge checks are model assertions, reported in M01.
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
  [ "$SKIPPED" -eq 0 ] && later M01 "[$file_id] manifest: COMPLETE after the loaders" \
     "$(aq "SELECT status FROM arch.loaded_files WHERE file_id='$file_id'")" "COMPLETE"
  [ "$SKIPPED" -eq 0 ] && later M01 "[$file_id] USS refreshed for this delivery" \
     "$(q "SELECT record_source FROM uss_refresh")" "$file_id"
  later M01 "[$file_id] stage blank after delivery" \
     "$(q "SELECT (SELECT COUNT(*) FROM stg_customer_l1)+(SELECT COUNT(*) FROM stg_product_l1)
                +(SELECT COUNT(*) FROM stg_order_l1)+(SELECT COUNT(*) FROM stg_order_line_l1)")" "0"
  later M01 "[$file_id] bridge: one stage row per table row" "$(stages_ok)" "1"; }

rows(){ q "SELECT COUNT(*) FROM core_customer WHERE customer_id='$1'"; }
latest_c(){ q "SELECT change_type||'/'||COALESCE(delete_basis,'') FROM v_latest__customer WHERE customer_id='$1'"; }
fan(){ q "SELECT naive_join_total||'/'||bridge_total||'/'||true_total FROM v_fan_trap"; }

banner "1: CORE  (the same fourteen sections, in this order, in all ten suites)"

core_section C01
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null
core C01.1 "$(census)|$(archive_state)" "cust=0 prod=0 ord=0 line=0|0/0/0/0/0"
later M02 "each USS table has exactly one _key_ column: its own" \
   "$(q "SELECT group_concat(t||'='||n,' ') FROM (SELECT t, (SELECT COUNT(*) FROM pragma_table_info(t)
           WHERE name LIKE '\_key\_%' ESCAPE '\\') n FROM (SELECT 'customer' t UNION ALL SELECT 'product'
           UNION ALL SELECT 'orders' UNION ALL SELECT 'order_line') ORDER BY t)")" \
   "customer=1 order_line=1 orders=1 product=1"
later M02 "orders has no customer_ref: the relationship lives on the bridge" \
   "$(q "SELECT COUNT(*) FROM pragma_table_info('orders') WHERE name LIKE '%customer%'")" "0"
later M02 "the bridge carries every table's key" \
   "$(q "SELECT group_concat(name,',') FROM (SELECT name FROM pragma_table_info('_bridge')
         WHERE name LIKE '\_key\_%' ESCAPE '\\' ORDER BY name)")" \
   "_key_customer,_key_order_line,_key_orders,_key_product"

core_section C02
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
core C02.1 "$(q "SELECT (SELECT COUNT(*) FROM v_customer)||'/'||(SELECT COUNT(*) FROM v_product)
                ||'/'||(SELECT COUNT(*) FROM v_order)||'/'||(SELECT COUNT(*) FROM order_line)")" "2/3/2/3"
core C02.2 "$(ans 5)" "PENDING"
core C02.3 "$(ans 6)" "48.99"
later M03 "baseline: C001 email v1" "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@example.com"
later M02 "bridge: 2+3+2+3 = 10 rows across 4 stages" \
   "$(q "SELECT COUNT(*)||'/'||COUNT(DISTINCT stage) FROM _bridge")" "10/4"
later M07 "core keeps raw 'P'; the USS table holds PENDING (+ raw code for lineage)" \
   "$(q "SELECT (SELECT status FROM core_order WHERE order_ref='O-100')||'/'||
                (SELECT status||'/'||status_code FROM orders WHERE order_ref='O-100')")" "P/PENDING/P"
later M02 "TRANSITIVE KEY: an order line carries its order's customer" \
   "$(q "SELECT _key_customer FROM _bridge WHERE _key_order_line='O-100|SKU-1'")" "C001"
later M04 "measures sit on their own stage only" \
   "$(q "SELECT (SELECT COUNT(*) FROM _bridge WHERE order_amount IS NOT NULL AND stage<>'Orders')
             + (SELECT COUNT(*) FROM _bridge WHERE line_count   IS NOT NULL AND stage<>'Order line')")" "0"
later M04 "FAN TRAP: naive join double counts O-100; the bridge does not" "$(fan)" "78.48/48.99/48.99"
later M04 "one query, two grains: C001 has 1 order, 29.49, 2 lines" \
   "$(q "SELECT n_orders||'/'||order_amount||'/'||n_lines FROM v_sales_by_customer WHERE customer_ref='C001'")" "1/29.49/2"
later M04 "SKU-3 never ordered but still on the star (Product stage)" \
   "$(q "SELECT n_orders||'/'||n_lines FROM v_sales_by_product WHERE sku='SKU-3'")" "0/0"
later M05 "lineage: every core row names its delivery" \
   "$(q "SELECT group_concat(DISTINCT record_source) FROM core_order_line")" "B0"

core_section C03
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
core C03.1 "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@newmail.com"
core C03.2 "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "1"
core C03.3 "$(rows C002)" "1"
core C03.4 "$(q "SELECT COUNT(DISTINCT full_name)||'/'||COUNT(DISTINCT signup_date) FROM core_customer WHERE customer_id='C001'")" "1/1"
later M05 "core: C001 now 2 rows, the new one an UPDATE" \
   "$(q "SELECT COUNT(*)||'/'||(SELECT change_type FROM v_latest__customer WHERE customer_id='C001')
         FROM core_customer WHERE customer_id='C001'")" "2/UPDATE"
later M05 "insert-only: C001's first core row still holds the old email" \
   "$(q "SELECT email_addr FROM core_customer WHERE customer_id='C001' AND load_ts='2026-02-05 08:00:00'")" "alice@example.com"
later M02 "v_order resolves placed_by through the bridge" \
   "$(q "SELECT placed_by FROM v_order WHERE order_ref='O-100'")" "Alice Smith"

core_section C04
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
core C04.1 "$(q "SELECT price FROM v_product WHERE sku='SKU-1'")" "8.99"
core C04.2 "$(q "SELECT (SELECT COUNT(*) FROM v_product WHERE sku='SKU-3')+(SELECT COUNT(*) FROM _bridge WHERE _key_product='SKU-3')")" "0"
core C04.3 "$(q "SELECT COUNT(*) FROM core_product WHERE sku='SKU-2'")" "1"
core C04.4 "$(ans 4)" "9.99>8.99"
later M05 "FULL: SKU-3 core row DELETE, basis FULL_ABSENCE" \
   "$(q "SELECT change_type||'/'||delete_basis FROM v_latest__product WHERE sku='SKU-3'")" "DELETE/FULL_ABSENCE"
later M05 "FULL product feed leaves the other core tables untouched" \
   "$(q "SELECT COUNT(*) FROM core_order_line WHERE record_source<>'B0'")" "0"

core_section C05
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
core C05.1 "$(latest_c C002)" "DELETE/TOMBSTONE"
core C05.2 "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "0"
core C05.3 "$(q "SELECT COALESCE(placed_by,'<none>') FROM v_order WHERE order_ref='O-101'")" "<none>"
core C05.4 "$(q "SELECT full_name||'/'||email_addr FROM core_customer
                 WHERE customer_id='C002' AND change_type<>'DELETE' ORDER BY load_ts DESC LIMIT 1")" \
           "Bob Jones/bob@example.com"
core C05.5 "$(ans 7)" "Bob Jones"
later M04 "the bridge keeps O-101's key to C002, so its amount still counts" \
   "$(q "SELECT _key_customer FROM _bridge WHERE stage='Orders' AND _key_orders='O-101'")/$(fan)" "C002/78.48/48.99/48.99"
later M04 "sales by customer: C002's 19.5 survives with no name" \
   "$(q "SELECT COALESCE(customer_name,'<none>')||'/'||order_amount FROM v_sales_by_customer WHERE customer_ref='C002'")" "<none>/19.5"
later M05 "tombstone: C002 has exactly one DELETE row" \
   "$(q "SELECT COUNT(*) FROM core_customer WHERE customer_id='C002' AND change_type='DELETE'")" "1"

core_section C06
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
core C06.1 "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C003'")" "1"
core C06.2 "$(q "SELECT email FROM v_customer WHERE customer_ref='C003'")" "new@x.com"
later M05 "recency: one delivery -> one core row" "$(rows C003)" "1"
later M04 "NO CHASM TRAP: order-less C003 still appears in sales by customer" \
   "$(q "SELECT customer_name||'/'||n_orders||'/'||order_amount||'/'||n_lines FROM v_sales_by_customer WHERE customer_ref='C003'")" "Carol Diaz/0/0/0"

core_section C07
before="$(census)"; before_b="$(bridge)"; before_arch="$(archive_state)"
feed d1_cust_win_day60.sql D1 '2026-04-10 08:00:00'
core C07.1 "$SKIPPED" "1"
core C07.2 "$(census)|$(bridge)" "$before|$before_b"
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

core_section C08
feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'
core C08.1 "$(latest_c C003)" "DELETE/FULL_ABSENCE"
core C08.2 "$(ans 1)" "C001"
core C08.3 "$(ans 2)" "C002,C003"
core C08.4 "$(ans 3)" "alice@example.com>alice@newmail.com"
later M05 "reconcile: C001 unchanged content -> zero churn (still 2)" "$(rows C001)" "2"
later M05 "reconcile: C002 already deleted -> zero churn (still 2)"   "$(rows C002)" "2"
later M05 "reconcile: D5 wrote exactly one core row (the C003 delete)" \
   "$(q "SELECT COUNT(*) FROM core_customer WHERE record_source='D5'")" "1"
later M02 "reconcile: C003 left the Customer stage" \
   "$(q "SELECT COUNT(*) FROM _bridge WHERE _key_customer='C003'")" "0"

core_section C09
before_r="$(census)"; before_rb="$(bridge)"
feed d5_cust_yearly_full.sql D5R '2027-01-10 08:00:00'
core C09.1 "$(census)|$(bridge)" "$before_r|$before_rb"

core_section C10
later M06 "UPDATE on a core table aborts" "$(db_refused "UPDATE core_customer SET full_name='x';" "insert-only")" "refused"
later M06 "DELETE on a core table aborts" "$(db_refused "DELETE FROM core_order;" "insert-only")" "refused"
core C10.1 "$(aq "SELECT (SELECT COUNT(*) FROM arch.hist_customer)+(SELECT COUNT(*) FROM arch.hist_product)
              +(SELECT COUNT(*) FROM arch.hist_order)+(SELECT COUNT(*) FROM arch.hist_order_line)")" \
           "$(aq 'SELECT SUM(row_count) FROM arch.loaded_files')"
later M06 "core is delta-compressed: fewer rows than the archive holds" \
   "$(aq "SELECT (SELECT COUNT(*) FROM core_customer) < (SELECT COUNT(*) FROM arch.hist_customer)")" "1"
core_abort C10.2 "UPDATE hist_customer SET full_name='x';" "append-only"
core_abort C10.3 "DELETE FROM hist_order;" "append-only"

core_section C11
ingested="$(snap)"
rm -f "$DB"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
core C11.1 "$(snap)" "$ingested"

core_section C12
# The USS tables are materialised: a reference change reaches them on the
# next refresh_uss.sh, with no reload of the core (M07). The history view
# decodes on the fly.
q "UPDATE ref_order_status SET status_name='PLACED' WHERE status_code='P';" >/dev/null
later M07 "live ref change is NOT yet visible (the USS is materialised)" \
   "$(q "SELECT DISTINCT status FROM v_order")" "PENDING"
"$PROJ/scripts/refresh_uss.sh" >/dev/null
later M07 "refresh_uss.sh alone applies it -- no core reload" \
   "$(q "SELECT DISTINCT status FROM v_order")" "PLACED"
core C12.1 "$(ans 9)" "O-100=PLACED,O-101=PLACED"
later M07 "...while the core still holds the raw code" \
   "$(q "SELECT DISTINCT status FROM core_order")" "P"
q "UPDATE ref_order_status SET status_name='PENDING' WHERE status_code='P';" >/dev/null
"$PROJ/scripts/refresh_uss.sh" >/dev/null

core_section C13
feed d6_repoint.sql D6 '2027-02-01 08:00:00' "$HERE/fixtures"
core C13.1 "$(ans 8)" "Alice Smith"
core C13.2 "$(q "SELECT customer_ref FROM core_order WHERE order_ref='O-101' AND load_ts='2026-02-05 08:00:00'")" "C002"
later M08 "repoint: core O-101 has 2 rows, the new one an UPDATE" \
   "$(q "SELECT COUNT(*)||'/'||(SELECT change_type FROM v_latest__order WHERE order_ref='O-101')
         FROM core_order WHERE order_ref='O-101'")" "2/UPDATE"
later M08 "repoint: Orders stage now keys O-101 to C001" \
   "$(q "SELECT _key_customer FROM _bridge WHERE stage='Orders' AND _key_orders='O-101'")" "C001"
later M08 "repoint: the order LINE followed its order (transitive key)" \
   "$(q "SELECT _key_customer FROM _bridge WHERE _key_order_line='O-101|SKU-2'")" "C001"
later M08 "repoint: C001 now owns both orders, all 3 lines, 48.99" \
   "$(q "SELECT n_orders||'/'||n_lines||'/'||order_amount FROM v_sales_by_customer WHERE customer_ref='C001'")" "2/3/48.99"
later M08 "repoint: C002 has left the star entirely" \
   "$(q "SELECT COUNT(*) FROM _bridge WHERE _key_customer='C002'")" "0"
later M08 "repoint: as-recorded reads each core row against its own moment" \
   "$(q "SELECT group_concat(COALESCE(placed_by_as_recorded,'<none>'),',') FROM
           (SELECT placed_by_as_recorded FROM v_order_as_recorded WHERE order_ref='O-101' ORDER BY recorded_at)")" "Bob Jones,Alice Smith"
later M08 "repoint: still no fan trap" "$(fan)" "78.48/48.99/48.99"
before_d6r="$(census)"
feed d6_repoint.sql D6R '2027-02-15 08:00:00' "$HERE/fixtures"
later M08 "re-asserted repoint writes nothing" "$(census)" "$before_d6r"

core_section C14
core C14.1 "$(q "SELECT group_concat(customer_ref||'('||COALESCE(email,'null')||')',' ')
                 FROM (SELECT * FROM v_customer ORDER BY customer_ref)")" "C001(alice@newmail.com)"

banner "2: MODEL  (what the Unified Star Schema shows on its own)"

own_section M01 "Manifest, refresh, stage and bridge after every delivery"
replay M01
own_section M02 "The shape: tables without foreign keys, every key on the bridge"
replay M02
own_section M03 "Baseline values on D0"
replay M03
own_section M04 "Measures on their own stage: no fan trap, no chasm trap"
replay M04
own_section M05 "The insert-only core under the star"
replay M05
own_section M06 "Core is insert-only, and smaller than the archive"
replay M06
own_section M07 "A materialised decode: a rule change waits for a refresh, not a reload"
replay M07
own_section M08 "Re-point: the bridge is re-derived"
replay M08

own_section M09 "Load control: a file_id names CONTENT (same block in all ten suites)"
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
