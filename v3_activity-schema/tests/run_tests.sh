#!/usr/bin/env bash
# =====================================================================
# Activity Schema test suite -- the shared delivery scenarios against two
# activity streams, plus the Activity-Schema-specific behaviours: state
# snapshots turned into activities, immutability, NOCHANGE = no activity,
# the shared delete rule filling the spec's gap, event time vs observed
# time, temporal joins (LAST EVER / LAST BEFORE / FIRST EVER / FIRST
# AFTER), the re-point as a new activity, and exact rebuild from the raw
# layer.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/activity_test).db}"
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

census(){ q "SELECT (SELECT COUNT(*) FROM customer_stream)||'/'||(SELECT COUNT(*) FROM product_stream)"; }

snap(){ q "
  SELECT 'c', activity_id, ts, COALESCE(customer,''), activity, feature_json, COALESCE(revenue_impact,''),
         COALESCE(link,''), _seq, _load_ts, _record_source FROM customer_stream
  UNION ALL
  SELECT 'p', activity_id, ts, COALESCE(customer,''), activity, feature_json, COALESCE(revenue_impact,''),
         COALESCE(link,''), _seq, _load_ts, _record_source FROM product_stream
  ORDER BY 1, 2;"; }

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
  ck "[$file_id] every activity is in the catalog" \
     "$(q "SELECT COUNT(*) FROM (SELECT 'customer_stream' st, activity FROM customer_stream
                                 UNION ALL SELECT 'product_stream', activity FROM product_stream) s
           WHERE NOT EXISTS (SELECT 1 FROM activity_catalog c WHERE c.stream=s.st AND c.activity=s.activity)")" "0"; }

acts(){ q "SELECT group_concat(activity,',') FROM (SELECT activity FROM customer_stream
           WHERE customer='$1' ORDER BY ts, _seq)"; }
by_src(){ q "SELECT (SELECT COUNT(*) FROM customer_stream WHERE _record_source='$1')
                  + (SELECT COUNT(*) FROM product_stream  WHERE _record_source='$1')"; }

echo "== Fresh db + archive =="; rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null

echo; echo "== The model: two activity streams, nothing else holds data =="
ck "only the two streams hold warehouse data" \
   "$(q "SELECT group_concat(name,',') FROM (SELECT name FROM sqlite_master
         WHERE type='table' AND name NOT LIKE 'stg\_%' ESCAPE '\\'
           AND name NOT LIKE 'act\_%' ESCAPE '\\' AND name NOT LIKE 'ref\_%' ESCAPE '\\'
           AND name <> 'activity_catalog' ORDER BY name)")" "customer_stream,product_stream"
ck "streams carry every Activity Schema 2.0 column" \
   "$(q "SELECT COUNT(*) FROM pragma_table_info('customer_stream') WHERE name IN
         ('activity_id','ts','customer','activity','feature_json','anonymous_customer_id','revenue_impact','link')")" "8"
ck "every other column is implementation-specific (spec: '_' prefix)" \
   "$(q "SELECT COUNT(*) FROM pragma_table_info('product_stream') WHERE name NOT IN
         ('activity_id','ts','customer','activity','feature_json','anonymous_customer_id','revenue_impact','link')
         AND name NOT LIKE '\_%' ESCAPE '\\'")" "0"

echo; echo "== D0: FULL baseline =="
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
ck "baseline: 2 customers, 3 products, 2 orders current" \
   "$(q "SELECT (SELECT COUNT(*) FROM v_customer)||'/'||(SELECT COUNT(*) FROM v_product)||'/'||(SELECT COUNT(*) FROM v_order)")" "2/3/2"
ck "baseline: C001 email v1" "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@example.com"
ck "snapshot -> activities: C001 signed_up, then placed_order" "$(acts C001)" "signed_up,placed_order"
ck "EVENT TIME: signed_up is stamped with signup_date, not the load" \
   "$(q "SELECT ts FROM customer_stream WHERE customer='C001' AND activity='signed_up'")" "2026-01-05 00:00:00"
ck "EVENT TIME: placed_order is stamped with placed_at" \
   "$(q "SELECT ts FROM customer_stream WHERE link='O-100' AND activity='placed_order'")" "2026-02-01 10:00:00"
ck "placed_order carries revenue_impact and link" \
   "$(q "SELECT revenue_impact||'/'||link FROM customer_stream WHERE activity='placed_order' AND customer='C001'")" "29.49/O-100"
ck "order lines are product activities: 3 was_ordered, linked to their order" \
   "$(q "SELECT COUNT(*)||'/'||group_concat(DISTINCT link) FROM product_stream WHERE activity='was_ordered'")" "3/O-100,O-101"
ck "was_ordered borrows the order's placed_at (event time)" \
   "$(q "SELECT ts FROM product_stream WHERE activity='was_ordered' AND customer='SKU-2' AND link='O-101'")" "2026-02-02 11:30:00"
ck "SOFT RULE ON READ: stream stores raw 'P', v_order decodes PENDING" \
   "$(q "SELECT json_extract(feature_json,'\$.status') FROM customer_stream WHERE link='O-100' AND activity='placed_order'")/$(q "SELECT status FROM v_order WHERE order_ref='O-100'")" "P/PENDING"
ck "lineage: every activity names its delivery" \
   "$(q "SELECT group_concat(DISTINCT _record_source) FROM product_stream")" "B0"

echo; echo "== D1: CRM 14-day INCREMENTAL window (C001 changed; C002 absent) =="
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
ck "a changed attribute is ONE new activity: updated_email" "$(acts C001)" "signed_up,placed_order,updated_email"
ck "updated_email carries only the attribute it owns" \
   "$(q "SELECT feature_json FROM customer_stream WHERE activity='updated_email'")" '{"email_addr":"alice@newmail.com"}'
ck "OBSERVED TIME: the change is stamped with the extract it was seen in" \
   "$(q "SELECT ts FROM customer_stream WHERE activity='updated_email'")" "2026-03-02 00:00:00"
ck "unchanged name and signup_date -> NO activity (NOCHANGE)" "$(by_src D1)" "1"
ck "INCREMENTAL: C002 NOT deleted (60-day stale)" \
   "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "1"
ck "INCREMENTAL: C002 zero activity" "$(acts C002)" "signed_up,placed_order"
ck "LAST EVER: current email is the new one" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@newmail.com"
ck "LAST BEFORE: O-100 still reads the email as it was when placed" \
   "$(q "SELECT email_at_purchase FROM v_order_at_purchase WHERE order_ref='O-100'")" "alice@example.com"

echo; echo "== D2: PIM FULL snapshot (SKU-3 discontinued) =="
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
ck "FULL: SKU-3 discontinued, basis FULL_ABSENCE" \
   "$(q "SELECT json_extract(feature_json,'\$.basis') FROM product_stream WHERE customer='SKU-3' AND activity='discontinued'")" "FULL_ABSENCE"
ck "FULL: absence is stamped with the snapshot's extract date" \
   "$(q "SELECT ts FROM product_stream WHERE customer='SKU-3' AND activity='discontinued'")" "2026-03-02 00:00:00"
ck "FULL: SKU-3 gone from v_product" "$(q "SELECT COUNT(*) FROM v_product WHERE sku='SKU-3'")" "0"
ck "FULL: SKU-1 price 8.99 via one updated_price activity" \
   "$(q "SELECT price FROM v_product WHERE sku='SKU-1'")/$(q "SELECT COUNT(*) FROM product_stream WHERE activity='updated_price'")" "8.99/1"
ck "FULL: SKU-2 unchanged -> NOCHANGE, no catalogue activity" \
   "$(q "SELECT COUNT(*) FROM product_stream WHERE customer='SKU-2' AND activity<>'was_ordered'")" "1"
ck "D2 wrote exactly two activities (repriced SKU-1, discontinued SKU-3)" "$(by_src D2)" "2"
ck "the discontinued product's order history is untouched" \
   "$(q "SELECT COUNT(*) FROM product_stream WHERE activity='was_ordered'")" "3"

echo; echo "== D3: INCREMENTAL tombstone deletes C002 =="
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
ck "tombstone: C002 was_deleted, basis TOMBSTONE" \
   "$(q "SELECT json_extract(feature_json,'\$.basis') FROM customer_stream WHERE customer='C002' AND activity='was_deleted'")" "TOMBSTONE"
ck "tombstone: C002 gone from v_customer (no ghost row)" \
   "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "0"
ck "tombstone: O-101 placed_by now NULL (current owner is deleted)" \
   "$(q "SELECT COALESCE(placed_by,'<none>') FROM v_order WHERE order_ref='O-101'")" "<none>"
ck "LAST BEFORE: O-101 at purchase still answers Bob Jones" \
   "$(q "SELECT placed_by_at_purchase FROM v_order_at_purchase WHERE order_ref='O-101'")" "Bob Jones"
ck "history survives the delete: C002's activities are all still there" "$(acts C002)" "signed_up,placed_order,was_deleted"

echo; echo "== D4: INCREMENTAL adds C003; recency de-dup =="
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
ck "recency: newest email wins (not MAX)" "$(q "SELECT email FROM v_customer WHERE customer_ref='C003'")" "new@x.com"
ck "recency: two staged rows -> one signed_up, no spurious update" "$(acts C003)" "signed_up"

echo; echo "== Load control: re-deliver D1 (same file_id) must be skipped =="
before="$(census)"
feed d1_cust_win_day60.sql D1 '2026-04-10 08:00:00'
ck "dup file skipped: streams unchanged" "$(census)" "$before"

echo; echo "== D5: YEARLY FULL reconciliation (C003 gone at source) =="
feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'
ck "reconcile: C003 deleted by absence (FULL)" \
   "$(q "SELECT json_extract(feature_json,'\$.basis') FROM customer_stream WHERE customer='C003' AND activity='was_deleted'")" "FULL_ABSENCE"
ck "reconcile: C002 already deleted -> not deleted twice" \
   "$(q "SELECT COUNT(*) FROM customer_stream WHERE customer='C002' AND activity='was_deleted'")" "1"
ck "reconcile: D5 wrote exactly one activity (the C003 delete)" "$(by_src D5)" "1"
ck "reconcile: v_customer shows only C001" \
   "$(q "SELECT group_concat(customer_ref,',') FROM v_customer")" "C001"

echo; echo "== True loader idempotence: same content, NEW file_id, writes nothing =="
before_r="$(census)"
feed d5_cust_yearly_full.sql D5R '2027-01-10 08:00:00'
ck "re-asserted current state writes zero activities" "$(census)" "$before_r"

echo; echo "== Temporal joins: questions the model was built for =="
ck "FIRST EVER: days from signup to first order (C001)" \
   "$(q "SELECT days_to_first_order FROM v_customer_journey WHERE customer_ref='C001'")" "27"
ck "FIRST AFTER: C001 changed email after the first order, on 2026-03-02" \
   "$(q "SELECT email_changed_after_first_order FROM v_customer_journey WHERE customer_ref='C001'")" "2026-03-02 00:00:00"
ck "FIRST AFTER: C002 never did" \
   "$(q "SELECT COALESCE(email_changed_after_first_order,'<none>') FROM v_customer_journey WHERE customer_ref='C002'")" "<none>"
ck "journeys survive deletes: all three customers, C003 with no orders" \
   "$(q "SELECT group_concat(customer_ref||':'||orders_placed,',') FROM v_customer_journey")" "C001:1,C002:1,C003:0"
ck "no foreign keys anywhere: relationships are who + what + when" \
   "$(q "SELECT COUNT(*) FROM pragma_foreign_key_list('customer_stream')")$(q "SELECT COUNT(*) FROM pragma_foreign_key_list('product_stream')")" "00"

echo; echo "== Streams and archive: immutability is enforced =="
ck_abort "UPDATE on customer_stream aborts" "$DB" "UPDATE customer_stream SET ts='x';" "immutable"
ck_abort "DELETE on product_stream aborts"  "$DB" "DELETE FROM product_stream;" "immutable"
ck "activity_id and _seq are dense and unique per stream" \
   "$(q "SELECT (SELECT COUNT(DISTINCT activity_id)=MAX(_seq) AND MIN(_seq)=1 FROM customer_stream)
              ||(SELECT COUNT(DISTINCT activity_id)=MAX(_seq) AND MIN(_seq)=1 FROM product_stream)")" "11"
ck "archive captured every delivered row" \
   "$(aq "SELECT (SELECT COUNT(*) FROM arch.hist_customer)+(SELECT COUNT(*) FROM arch.hist_product)
              +(SELECT COUNT(*) FROM arch.hist_order)+(SELECT COUNT(*) FROM arch.hist_order_line)")" \
   "$(aq 'SELECT SUM(row_count) FROM arch.loaded_files')"
ck "only differences become activities: fewer customer activities than staged customer rows + orders" \
   "$(aq "SELECT (SELECT COUNT(*) FROM customer_stream WHERE activity NOT LIKE '%order%')
                 < (SELECT COUNT(*) FROM arch.hist_customer)")" "1"
ck_abort "UPDATE on hist_customer aborts" "$ARCHIVE_DB" "UPDATE hist_customer SET full_name='x';" "append-only"
ck_abort "DELETE on hist_order aborts"    "$ARCHIVE_DB" "DELETE FROM hist_order;" "append-only"

echo; echo "== Rebuild: the streams are disposable =="
ingested="$(snap)"
rm -f "$DB"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
ck "clean+rebuild: streams identical (activity_id, ts, _seq, lineage included)" "$(snap)" "$ingested"

echo; echo "== Soft rule on read: a live decode change needs no reload =="
q "UPDATE ref_oms_order_status SET status_name='PLACED' WHERE status_code='P';" >/dev/null
ck "live ref change is visible immediately in v_order" "$(q "SELECT DISTINCT status FROM v_order")" "PLACED"
ck "...while the stream still holds the raw code" \
   "$(q "SELECT DISTINCT json_extract(feature_json,'\$.status') FROM customer_stream WHERE activity='placed_order'")" "P"
q "UPDATE ref_oms_order_status SET status_name='PENDING' WHERE status_code='P';" >/dev/null

echo; echo "== Re-point: OMS moves O-101 to C001 -> a NEW activity, nothing changes =="
feed d6_repoint.sql D6 '2027-02-01 08:00:00' "$HERE/fixtures"
ck "repoint: order_reassigned lands in C001's stream" "$(acts C001)" "signed_up,placed_order,updated_email,order_reassigned"
ck "repoint: it records where the order came from" \
   "$(q "SELECT link||' from '||json_extract(feature_json,'\$.from_customer') FROM customer_stream WHERE activity='order_reassigned'")" "O-101 from C002"
ck "repoint: C002's placed_order is untouched (immutable)" "$(acts C002)" "signed_up,placed_order,was_deleted"
ck "repoint: unchanged order attributes -> no order_updated" \
   "$(q "SELECT COUNT(*) FROM customer_stream WHERE activity='order_updated'")" "0"
ck "repoint: placed_by resolves to Alice Smith" \
   "$(q "SELECT placed_by FROM v_order WHERE order_ref='O-101'")" "Alice Smith"
ck "repoint: LAST BEFORE at purchase still Bob Jones" \
   "$(q "SELECT placed_by_at_purchase FROM v_order_at_purchase WHERE order_ref='O-101'")" "Bob Jones"
ck "repoint: ownership read against each activity's own moment" \
   "$(q "SELECT group_concat(COALESCE(owner_name_then,'<none>'),',') FROM
           (SELECT owner_name_then FROM v_order_ownership WHERE order_ref='O-101' ORDER BY recorded_at)")" "Bob Jones,Alice Smith"
before_d6r="$(census)"
feed d6_repoint.sql D6R '2027-02-15 08:00:00' "$HERE/fixtures"
ck "re-asserted repoint writes nothing" "$(census)" "$before_d6r"

echo; echo "== Lifecycle paths: restore, order update, line removal =="
feed d7_lifecycle.sql D7 '2027-03-01 08:00:00' "$HERE/fixtures"
ck "a deleted customer delivered again is restored (not signed up twice)" \
   "$(acts C002)" "signed_up,placed_order,was_deleted,restored"
ck "restored C002 is back in v_customer" \
   "$(q "SELECT customer_name FROM v_customer WHERE customer_ref='C002'")" "Bob Jones"
ck "status P -> S is one order_updated; v_order shows SHIPPED" \
   "$(q "SELECT COUNT(*) FROM customer_stream WHERE activity='order_updated'")/$(q "SELECT status FROM v_order WHERE order_ref='O-100'")" "1/SHIPPED"
ck "the update does not rewrite history: placed_order still holds 'P'" \
   "$(q "SELECT json_extract(feature_json,'\$.status') FROM customer_stream WHERE link='O-100' AND activity='placed_order'")" "P"
ck "a tombstoned line is removed_from_order, gone from v_order_line" \
   "$(q "SELECT COUNT(*) FROM product_stream WHERE activity='removed_from_order'")/$(q "SELECT group_concat(sku) FROM v_order_line WHERE order_ref='O-100'")" "1/SKU-2"
ck "restoring C002 does not move O-101 back (ownership is its own activity)" \
   "$(q "SELECT placed_by FROM v_order WHERE order_ref='O-101'")" "Alice Smith"
ck "D7 wrote exactly three activities" "$(by_src D7)" "3"

echo; echo "== Ordering guarantees: same-extract tiebreak, key-ordered activity ids =="
feed d8_tiebreak.sql D8 '2027-04-01 08:00:00' "$HERE/fixtures"
ck "tiebreak: same extract_dt -> the later staged row wins" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "tie-second@x.com"
ck "tiebreak: one updated_email for C001, not two" \
   "$(q "SELECT COUNT(*) FROM customer_stream WHERE _record_source='D8' AND customer='C001'")" "1"
ck "activity ids follow the loader's fixed order (step, then business key), not staged order" \
   "$(q "SELECT group_concat(customer||':'||activity,',') FROM
           (SELECT customer, activity FROM customer_stream WHERE _record_source='D8' ORDER BY _seq)")" \
   "C004:signed_up,C005:signed_up,C001:updated_email"
ck "...and for order lines: numbered by (sku, order), not the stage's (order, sku)" \
   "$(q "SELECT group_concat(customer||':'||link,',') FROM
           (SELECT customer, link FROM product_stream WHERE _record_source='D8' ORDER BY _seq)")" \
   "SKU-1:O-101,SKU-3:O-100"

echo; echo "== Rebuild again: fixtures included, replay is still exact =="
ingested2="$(snap)"
rm -f "$DB"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
ck "clean+rebuild after re-point, lifecycle and tiebreak: streams identical" "$(snap)" "$ingested2"

echo; echo "====================================================================="
printf "  RESULT: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "====================================================================="
rm -f "$DB" "$ARCHIVE_DB"
[ "$FAIL" -eq 0 ] || exit 1
