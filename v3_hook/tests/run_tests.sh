#!/usr/bin/env bash
# =====================================================================
# HOOK test suite -- the shared delivery scenarios against source-aligned
# frames, plus the HOOK-specific behaviours: hooks qualified by key set,
# relationships as extra hooks on the row (no link tables), insert-only
# delta frames, hubs derived on demand, soft rules on read, the re-point
# as a plain frame row, and exact rebuild from the raw layer.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/hook_test).db}"
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
    SELECT 1 o,'cust' t,COUNT(*) n FROM frame__crm__customer
    UNION ALL SELECT 2,'prod',  COUNT(*) FROM frame__pim__product
    UNION ALL SELECT 3,'ord',   COUNT(*) FROM frame__oms__order
    UNION ALL SELECT 4,'line',  COUNT(*) FROM frame__oms__order_line
    ORDER BY o);"; }

snap(){ q "
  SELECT 'c', hk_customer, load_ts, COALESCE(full_name,'')||'/'||COALESCE(email_addr,''),
         change_type||'/'||COALESCE(delete_basis,'')||'/'||record_source FROM frame__crm__customer
  UNION ALL
  SELECT 'p', hk_product, load_ts, COALESCE(prod_name,'')||'/'||COALESCE(price,''),
         change_type||'/'||COALESCE(delete_basis,'')||'/'||record_source FROM frame__pim__product
  UNION ALL
  SELECT 'o', hk_order, load_ts, COALESCE(hk_customer,'')||'/'||COALESCE(status,'')||'/'||COALESCE(amount,''),
         change_type||'/'||COALESCE(delete_basis,'')||'/'||record_source FROM frame__oms__order
  UNION ALL
  SELECT 'l', hk_order||'+'||hk_product, load_ts, '',
         change_type||'/'||COALESCE(delete_basis,'')||'/'||record_source FROM frame__oms__order_line
  ORDER BY 1,2,3;"; }

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
                +(SELECT COUNT(*) FROM stg_order_l1)+(SELECT COUNT(*) FROM stg_order_line_l1)")" "0"
  ck "[$file_id] hook integrity: every hook uses its registered key set" \
     "$(q "SELECT COUNT(*) FROM v_hook_violation")" "0"; }

rows(){ q "SELECT COUNT(*) FROM frame__crm__customer WHERE hk_customer='CRM.CUST|$1'"; }
latest_c(){ q "SELECT change_type||'/'||COALESCE(delete_basis,'') FROM v_latest__crm__customer
               WHERE hk_customer='CRM.CUST|$1'"; }

echo "== Fresh db + archive =="; rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null

echo; echo "== The model: a registry, four frames, no hubs or links =="
ck "registry: every frame column named in hook_column exists on its frame" \
   "$(q "SELECT COUNT(*) FROM hook_column c
         WHERE NOT EXISTS (SELECT 1 FROM pragma_table_info(c.frame) p WHERE p.name=c.hook_column)")" "0"
ck "registry: every hk_* column on every frame is registered" \
   "$(q "SELECT COUNT(*) FROM hook_frame f, pragma_table_info(f.frame) p
         WHERE p.name LIKE 'hk\_%' ESCAPE '\\'
           AND NOT EXISTS (SELECT 1 FROM hook_column c WHERE c.frame=f.frame AND c.hook_column=p.name)")" "0"
ck "registry: v_hook_occurrence covers every registered hook column" \
   "$(q "SELECT COUNT(*) FROM hook_column")" "6"
ck "no hub, link or satellite tables -- data lives only in frames" \
   "$(q "SELECT group_concat(name,',') FROM (SELECT name FROM sqlite_master
         WHERE type='table' AND name NOT LIKE 'stg\_%' ESCAPE '\\'
           AND name NOT LIKE 'hook\_%' ESCAPE '\\' AND name NOT LIKE 'ref\_%' ESCAPE '\\'
         ORDER BY name)")" "frame__crm__customer,frame__oms__order,frame__oms__order_line,frame__pim__product"

echo; echo "== D0: FULL baseline =="
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
ck "baseline: 2 customers, 3 products, 2 orders current" \
   "$(q "SELECT (SELECT COUNT(*) FROM v_customer)||'/'||(SELECT COUNT(*) FROM v_product)||'/'||(SELECT COUNT(*) FROM v_order)")" "2/3/2"
ck "baseline: C001 email v1" "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@example.com"
ck "HOOK = key set + business key" \
   "$(q "SELECT hk_customer FROM frame__crm__customer WHERE customer_id='C001'")" "CRM.CUST|C001"
ck "frame keeps the source columns verbatim (raw customer_id beside the hook)" \
   "$(q "SELECT customer_id||'/'||full_name FROM frame__crm__customer WHERE hk_customer='CRM.CUST|C001'")" "C001/Alice Smith"
ck "relationship = a second hook on the order row (no link table)" \
   "$(q "SELECT hk_order||' -> '||hk_customer FROM frame__oms__order WHERE order_ref='O-100'")" "OMS.ORD|O-100 -> CRM.CUST|C001"
ck "order line frame grain is the hook pair (3 pairs)" \
   "$(q "SELECT COUNT(DISTINCT hk_order||hk_product) FROM frame__oms__order_line")" "3"
ck "SOFT RULE ON READ: frame stores raw 'P', v_order decodes PENDING" \
   "$(q "SELECT (SELECT status FROM frame__oms__order WHERE order_ref='O-100')||'/'||
                (SELECT status FROM v_order WHERE order_ref='O-100')")" "P/PENDING"
ck "lineage: every frame row names its delivery" \
   "$(q "SELECT group_concat(DISTINCT record_source) FROM frame__oms__order_line")" "B0"

echo; echo "== D1: CRM 14-day INCREMENTAL window (C001 changed; C002 absent) =="
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
ck "delta: C001 now 2 frame rows, the new one an UPDATE" \
   "$(q "SELECT COUNT(*)||'/'||(SELECT change_type FROM v_latest__crm__customer WHERE hk_customer='CRM.CUST|C001')
         FROM frame__crm__customer WHERE hk_customer='CRM.CUST|C001'")" "2/UPDATE"
ck "insert-only: C001's first row still holds the old email" \
   "$(q "SELECT email_addr FROM frame__crm__customer WHERE hk_customer='CRM.CUST|C001' AND load_ts='2026-02-05 08:00:00'")" "alice@example.com"
ck "INCREMENTAL: C002 NOT deleted (60-day stale)" \
   "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "1"
ck "INCREMENTAL: C002 zero churn" "$(rows C002)" "1"
ck "HOOK JOIN: v_order resolves placed_by through the shared CRM.CUST key set" \
   "$(q "SELECT placed_by FROM v_order WHERE order_ref='O-100'")" "Alice Smith"

echo; echo "== D2: PIM FULL snapshot (SKU-3 discontinued) =="
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
ck "FULL: SKU-3 gets a DELETE row, basis FULL_ABSENCE" \
   "$(q "SELECT change_type||'/'||delete_basis FROM v_latest__pim__product WHERE hk_product='PIM.SKU|SKU-3'")" "DELETE/FULL_ABSENCE"
ck "FULL: SKU-3 gone from v_product"  "$(q "SELECT COUNT(*) FROM v_product WHERE sku='SKU-3'")" "0"
ck "FULL: the DELETE row carries the business key, no attributes" \
   "$(q "SELECT sku||'/'||COALESCE(prod_name,'<null>') FROM v_latest__pim__product WHERE hk_product='PIM.SKU|SKU-3'")" "SKU-3/<null>"
ck "FULL: SKU-1 price 8.99 via a new frame row" "$(q "SELECT price FROM v_product WHERE sku='SKU-1'")" "8.99"
ck "FULL: SKU-2 unchanged -> NOCHANGE, zero churn" \
   "$(q "SELECT COUNT(*) FROM frame__pim__product WHERE hk_product='PIM.SKU|SKU-2'")" "1"
ck "FULL product feed leaves the other frames untouched" \
   "$(q "SELECT COUNT(*) FROM frame__oms__order_line WHERE record_source<>'B0'")" "0"

echo; echo "== D3: INCREMENTAL tombstone deletes C002 =="
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
ck "tombstone: C002 latest row is DELETE/TOMBSTONE" "$(latest_c C002)" "DELETE/TOMBSTONE"
ck "tombstone: C002 gone from v_customer (no ghost row)" \
   "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "0"
ck "tombstone: O-101 placed_by now NULL (current join finds nobody)" \
   "$(q "SELECT COALESCE(placed_by,'<none>') FROM v_order WHERE order_ref='O-101'")" "<none>"
ck "AS-OF: v_order_as_recorded still answers Bob Jones" \
   "$(q "SELECT placed_by_as_recorded FROM v_order_as_recorded
         WHERE order_ref='O-101' AND recorded_at='2026-02-05 08:00:00'")" "Bob Jones"
ck "tombstone: C002 has exactly one DELETE row" \
   "$(q "SELECT COUNT(*) FROM frame__crm__customer WHERE hk_customer='CRM.CUST|C002' AND change_type='DELETE'")" "1"

echo; echo "== D4: INCREMENTAL adds C003; recency de-dup =="
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
ck "recency: newest email wins (not MAX)" "$(q "SELECT email FROM v_customer WHERE customer_ref='C003'")" "new@x.com"
ck "recency: one delivery -> one frame row" "$(rows C003)" "1"

echo; echo "== Load control: re-deliver D1 (same file_id) must be skipped =="
before="$(census)"
feed d1_cust_win_day60.sql D1 '2026-04-10 08:00:00'
ck "dup file skipped: frames unchanged" "$(census)" "$before"

echo; echo "== D5: YEARLY FULL reconciliation (C003 gone at source) =="
feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'
ck "reconcile: C003 deleted by absence (FULL)" "$(latest_c C003)" "DELETE/FULL_ABSENCE"
ck "reconcile: C001 unchanged content -> zero churn (still 2)" "$(rows C001)" "2"
ck "reconcile: C002 already deleted -> zero churn (still 2)"   "$(rows C002)" "2"
ck "reconcile: D5 wrote exactly one frame row (the C003 delete)" \
   "$(q "SELECT COUNT(*) FROM frame__crm__customer WHERE record_source='D5'")" "1"
ck "reconcile: v_customer shows only C001" \
   "$(q "SELECT group_concat(customer_ref,',') FROM v_customer")" "C001"

echo; echo "== True loader idempotence: same content, NEW file_id, writes nothing =="
before_r="$(census)"
feed d5_cust_yearly_full.sql D5R '2027-01-10 08:00:00'
ck "re-asserted current state writes zero frame rows" "$(census)" "$before_r"

echo; echo "== Hubs on demand: concepts are derived, not stored =="
ck "CUSTOMER concept: 3 members ever seen (deleted ones included)" \
   "$(q "SELECT COUNT(*) FROM v_concept_member WHERE concept='CUSTOMER'")" "3"
ck "C001 is hooked from two frames (CRM customer + OMS order)" \
   "$(q "SELECT frames FROM v_concept_member WHERE hook='CRM.CUST|C001'")" "frame__crm__customer,frame__oms__order"
ck "SKU-3 never ordered: hooked from the product frame only" \
   "$(q "SELECT n_frames FROM v_concept_member WHERE hook='PIM.SKU|SKU-3'")" "1"
ck "integration: every order's customer hook lands on a customer frame row" \
   "$(q "SELECT COUNT(*) FROM frame__oms__order o WHERE o.hk_customer IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM frame__crm__customer c WHERE c.hk_customer=o.hk_customer)")" "0"

echo; echo "== Frames and archive: insert-only is enforced =="
ck_abort "UPDATE on a frame aborts" "$DB" "UPDATE frame__crm__customer SET full_name='x';" "insert-only"
ck_abort "DELETE on a frame aborts" "$DB" "DELETE FROM frame__oms__order;" "insert-only"
ck "archive captured every delivered row" \
   "$(aq "SELECT (SELECT COUNT(*) FROM arch.hist_customer)+(SELECT COUNT(*) FROM arch.hist_product)
              +(SELECT COUNT(*) FROM arch.hist_order)+(SELECT COUNT(*) FROM arch.hist_order_line)")" \
   "$(aq 'SELECT SUM(row_count) FROM arch.loaded_files')"
ck "frames are delta-compressed: fewer rows than the archive holds" \
   "$(aq "SELECT (SELECT COUNT(*) FROM frame__crm__customer) < (SELECT COUNT(*) FROM arch.hist_customer)")" "1"
ck_abort "UPDATE on hist_customer aborts" "$ARCHIVE_DB" "UPDATE hist_customer SET full_name='x';" "append-only"
ck_abort "DELETE on hist_order aborts"    "$ARCHIVE_DB" "DELETE FROM hist_order;" "append-only"

echo; echo "== Rebuild: the frames are disposable =="
ingested="$(snap)"
rm -f "$DB"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
ck "clean+rebuild: frames identical (load_ts and record_source included)" "$(snap)" "$ingested"

echo; echo "== Soft rule on read: a live decode change needs no reload =="
q "UPDATE ref_oms_order_status SET status_name='PLACED' WHERE status_code='P';" >/dev/null
ck "live ref change is visible immediately in v_order" \
   "$(q "SELECT DISTINCT status FROM v_order")" "PLACED"
ck "...and in history: as-recorded rows re-read under the new rule" \
   "$(q "SELECT DISTINCT status FROM v_order_as_recorded")" "PLACED"
ck "...while the frames still hold the raw code" \
   "$(q "SELECT DISTINCT status FROM frame__oms__order")" "P"
q "UPDATE ref_oms_order_status SET status_name='PENDING' WHERE status_code='P';" >/dev/null

echo; echo "== Re-point: OMS moves O-101 to C001 -> one new frame row =="
feed d6_repoint.sql D6 '2027-02-01 08:00:00' "$HERE/fixtures"
ck "repoint: O-101 has 2 frame rows, the new one an UPDATE" \
   "$(q "SELECT COUNT(*)||'/'||(SELECT change_type FROM v_latest__oms__order WHERE order_ref='O-101')
         FROM frame__oms__order WHERE order_ref='O-101'")" "2/UPDATE"
ck "repoint: latest hook points at CRM.CUST|C001" \
   "$(q "SELECT hk_customer FROM v_latest__oms__order WHERE order_ref='O-101'")" "CRM.CUST|C001"
ck "repoint: placed_by resolves to Alice Smith" \
   "$(q "SELECT placed_by FROM v_order WHERE order_ref='O-101'")" "Alice Smith"
ck "repoint: the old hook survives as history" \
   "$(q "SELECT hk_customer FROM frame__oms__order WHERE order_ref='O-101' AND load_ts='2026-02-05 08:00:00'")" "CRM.CUST|C002"
ck "repoint: exactly one current customer per order" \
   "$(q "SELECT COUNT(*) FROM v_latest__oms__order WHERE order_ref='O-101'")" "1"
ck "repoint: as-recorded reads each row against its own moment" \
   "$(q "SELECT group_concat(COALESCE(placed_by_as_recorded,'<none>'),',') FROM
           (SELECT placed_by_as_recorded FROM v_order_as_recorded WHERE order_ref='O-101' ORDER BY recorded_at)")" "Bob Jones,Alice Smith"
before_d6r="$(census)"
feed d6_repoint.sql D6R '2027-02-15 08:00:00' "$HERE/fixtures"
ck "re-asserted repoint writes nothing" "$(census)" "$before_d6r"

echo; echo "== Hook integrity: a bad key set is caught =="
q "INSERT INTO frame__oms__order(hk_order, hk_customer, order_ref, change_type, diff_str, load_ts, record_source)
   VALUES('OMS.ORD|O-999','ERP.CUST|C001','O-999','INSERT','x','2027-03-01 00:00:00','TEST');" >/dev/null
ck "a customer hook from an unregistered/wrong key set is flagged" \
   "$(q "SELECT hook_column||'='||hook||' expected '||expected_keyset FROM v_hook_violation")" \
   "hk_customer=ERP.CUST|C001 expected CRM.CUST"
ck "...and does NOT integrate: ERP.CUST|C001 is not CRM.CUST|C001" \
   "$(q "SELECT COALESCE(placed_by,'<none>') FROM v_order WHERE order_ref='O-999'")" "<none>"

echo; echo "====================================================================="
printf "  RESULT: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "====================================================================="
rm -f "$DB" "$ARCHIVE_DB"
[ "$FAIL" -eq 0 ] || exit 1
