#!/usr/bin/env bash
# =====================================================================
# Activity Schema test suite.
#
# PART 1, CORE: the fourteen sections every one of the ten suites runs,
# in the same order and with the same labels (tests/core_spec.tsv at the
# repo root). Each model supplies its own SQL; the nine question
# answers live in tests/answers/Q<n>.sql.
# PART 2, MODEL: what the Activity Schema shows on its own -- state
# snapshots turned into activities, immutability, NOCHANGE = no activity,
# the shared delete rule filling the spec's gap, event time vs observed
# time, temporal joins (LAST EVER / LAST BEFORE / FIRST EVER / FIRST
# AFTER), the re-point as a new activity, lifecycle paths, and the
# same-extract tiebreak.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/activity_test).db}"
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

# The streams refuse UPDATE and DELETE too (the shared refused() reads the
# archive): "refused" if the statement fails with the expected message.
db_refused(){ local out; out="$("$SQLITE" "$DB" "$1" 2>&1)"
              case "$out" in *"$2"*) printf 'refused';; *) printf '%s' "$out";; esac; }

census(){ q "SELECT (SELECT COUNT(*) FROM customer_stream)||'/'||(SELECT COUNT(*) FROM product_stream)"; }
archive_state(){ aq "SELECT (SELECT COUNT(*) FROM arch.loaded_files)||'/'||(SELECT COUNT(*) FROM arch.hist_customer)
                      ||'/'||(SELECT COUNT(*) FROM arch.hist_product)||'/'||(SELECT COUNT(*) FROM arch.hist_order)
                      ||'/'||(SELECT COUNT(*) FROM arch.hist_order_line)"; }

snap(){ q "
  SELECT 'c', activity_id, ts, COALESCE(customer,''), activity, feature_json, COALESCE(revenue_impact,''),
         COALESCE(link,''), _seq, _load_ts, _record_source FROM customer_stream
  UNION ALL
  SELECT 'p', activity_id, ts, COALESCE(customer,''), activity, feature_json, COALESCE(revenue_impact,''),
         COALESCE(link,''), _seq, _load_ts, _record_source FROM product_stream
  ORDER BY 1, 2;"; }

# Run one delivery; abort the suite if the loader crashes. Its manifest,
# stage and catalog checks are model assertions: reported in M01 for the
# PART 1 deliveries, at once for the PART 2 ones (FEED_SEC empty).
FEED_SEC=M01
fchk(){ if [ -n "$FEED_SEC" ]; then later "$FEED_SEC" "$@"; else own "$@"; fi; }
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
  fchk "[$file_id] manifest: recorded exactly once" \
     "$(aq "SELECT COUNT(*) FROM arch.loaded_files WHERE file_id='$file_id'")" "1"
  [ "$SKIPPED" -eq 0 ] && fchk "[$file_id] manifest: COMPLETE after the loader" \
     "$(aq "SELECT status FROM arch.loaded_files WHERE file_id='$file_id'")" "COMPLETE"
  fchk "[$file_id] stage blank after delivery" \
     "$(q "SELECT (SELECT COUNT(*) FROM stg_customer_l1)+(SELECT COUNT(*) FROM stg_product_l1)
                +(SELECT COUNT(*) FROM stg_order_l1)+(SELECT COUNT(*) FROM stg_order_line_l1)")" "0"
  fchk "[$file_id] every activity is in the catalog" \
     "$(q "SELECT COUNT(*) FROM (SELECT 'customer_stream' st, activity FROM customer_stream
                                 UNION ALL SELECT 'product_stream', activity FROM product_stream) s
           WHERE NOT EXISTS (SELECT 1 FROM activity_catalog c WHERE c.stream=s.st AND c.activity=s.activity)")" "0"
  return 0; }

acts(){ q "SELECT group_concat(activity,',') FROM (SELECT activity FROM customer_stream
           WHERE customer='$1' ORDER BY ts, _seq)"; }
by_src(){ q "SELECT (SELECT COUNT(*) FROM customer_stream WHERE _record_source='$1')
                  + (SELECT COUNT(*) FROM product_stream  WHERE _record_source='$1')"; }

banner "1: CORE  (the same fourteen sections, in this order, in all ten suites)"

core_section C01
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null
core C01.1 "$(census)|$(archive_state)" "0/0|0/0/0/0/0"
later M02 "only the two streams hold warehouse data" \
   "$(q "SELECT group_concat(name,',') FROM (SELECT name FROM sqlite_master
         WHERE type='table' AND name NOT LIKE 'stg\_%' ESCAPE '\\'
           AND name NOT LIKE 'act\_%' ESCAPE '\\' AND name NOT LIKE 'ref\_%' ESCAPE '\\'
           AND name <> 'activity_catalog' ORDER BY name)")" "customer_stream,product_stream"
later M02 "streams carry every Activity Schema 2.0 column" \
   "$(q "SELECT COUNT(*) FROM pragma_table_info('customer_stream') WHERE name IN
         ('activity_id','ts','customer','activity','feature_json','anonymous_customer_id','revenue_impact','link')")" "8"
later M02 "every other column is implementation-specific (spec: '_' prefix)" \
   "$(q "SELECT COUNT(*) FROM pragma_table_info('product_stream') WHERE name NOT IN
         ('activity_id','ts','customer','activity','feature_json','anonymous_customer_id','revenue_impact','link')
         AND name NOT LIKE '\_%' ESCAPE '\\'")" "0"

core_section C02
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
core C02.1 "$(q "SELECT (SELECT COUNT(*) FROM v_customer)||'/'||(SELECT COUNT(*) FROM v_product)
                ||'/'||(SELECT COUNT(*) FROM v_order)||'/'||(SELECT COUNT(*) FROM v_order_line)")" "2/3/2/3"
core C02.2 "$(ans 5)" "PENDING"
core C02.3 "$(ans 6)" "48.99"
later M03 "baseline: C001 email v1" "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@example.com"
later M04 "snapshot -> activities: C001 signed_up, then placed_order" "$(acts C001)" "signed_up,placed_order"
later M05 "EVENT TIME: signed_up is stamped with signup_date, not the load" \
   "$(q "SELECT ts FROM customer_stream WHERE customer='C001' AND activity='signed_up'")" "2026-01-05 00:00:00"
later M05 "EVENT TIME: placed_order is stamped with placed_at" \
   "$(q "SELECT ts FROM customer_stream WHERE link='O-100' AND activity='placed_order'")" "2026-02-01 10:00:00"
later M04 "placed_order carries revenue_impact and link" \
   "$(q "SELECT revenue_impact||'/'||link FROM customer_stream WHERE activity='placed_order' AND customer='C001'")" "29.49/O-100"
later M04 "order lines are product activities: 3 was_ordered, linked to their order" \
   "$(q "SELECT COUNT(*)||'/'||group_concat(DISTINCT link) FROM product_stream WHERE activity='was_ordered'")" "3/O-100,O-101"
later M05 "was_ordered borrows the order's placed_at (event time)" \
   "$(q "SELECT ts FROM product_stream WHERE activity='was_ordered' AND customer='SKU-2' AND link='O-101'")" "2026-02-02 11:30:00"
later M07 "SOFT RULE ON READ: stream stores raw 'P', v_order decodes PENDING" \
   "$(q "SELECT json_extract(feature_json,'\$.status') FROM customer_stream WHERE link='O-100' AND activity='placed_order'")/$(q "SELECT status FROM v_order WHERE order_ref='O-100'")" "P/PENDING"
later M04 "lineage: every activity names its delivery" \
   "$(q "SELECT group_concat(DISTINCT _record_source) FROM product_stream")" "B0"

core_section C03
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
core C03.1 "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@newmail.com"
core C03.2 "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "1"
core C03.3 "$(acts C002)" "signed_up,placed_order"
core C03.4 "$(by_src D1)" "1"
later M04 "a changed attribute is ONE new activity: updated_email" "$(acts C001)" "signed_up,placed_order,updated_email"
later M04 "updated_email carries only the attribute it owns" \
   "$(q "SELECT feature_json FROM customer_stream WHERE activity='updated_email'")" '{"email_addr":"alice@newmail.com"}'
later M05 "OBSERVED TIME: the change is stamped with the extract it was seen in" \
   "$(q "SELECT ts FROM customer_stream WHERE activity='updated_email'")" "2026-03-02 00:00:00"
later M06 "LAST BEFORE: O-100 still reads the email as it was when placed" \
   "$(q "SELECT email_at_purchase FROM v_order_at_purchase WHERE order_ref='O-100'")" "alice@example.com"

core_section C04
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
core C04.1 "$(q "SELECT price FROM v_product WHERE sku='SKU-1'")/$(q "SELECT COUNT(*) FROM product_stream WHERE activity='updated_price'")" "8.99/1"
core C04.2 "$(q "SELECT COUNT(*) FROM v_product WHERE sku='SKU-3'")" "0"
core C04.3 "$(q "SELECT COUNT(*) FROM product_stream WHERE customer='SKU-2' AND activity<>'was_ordered'")" "1"
core C04.4 "$(ans 4)" "9.99>8.99"
later M04 "FULL: SKU-3 discontinued, basis FULL_ABSENCE" \
   "$(q "SELECT json_extract(feature_json,'\$.basis') FROM product_stream WHERE customer='SKU-3' AND activity='discontinued'")" "FULL_ABSENCE"
later M05 "FULL: absence is stamped with the snapshot's extract date" \
   "$(q "SELECT ts FROM product_stream WHERE customer='SKU-3' AND activity='discontinued'")" "2026-03-02 00:00:00"
later M04 "D2 wrote exactly two activities (repriced SKU-1, discontinued SKU-3)" "$(by_src D2)" "2"
later M04 "the discontinued product's order history is untouched" \
   "$(q "SELECT COUNT(*) FROM product_stream WHERE activity='was_ordered'")" "3"

core_section C05
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
core C05.1 "$(q "SELECT json_extract(feature_json,'\$.basis') FROM customer_stream WHERE customer='C002' AND activity='was_deleted'")" "TOMBSTONE"
core C05.2 "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "0"
core C05.3 "$(q "SELECT COALESCE(placed_by,'<none>') FROM v_order WHERE order_ref='O-101'")" "<none>"
core C05.4 "$(q "SELECT json_extract(feature_json,'\$.full_name')||'/'||json_extract(feature_json,'\$.email_addr')
                 FROM customer_stream WHERE customer='C002' AND activity='signed_up'")" "Bob Jones/bob@example.com"
core C05.5 "$(ans 7)" "Bob Jones"
later M04 "history survives the delete: C002's activities are all still there" "$(acts C002)" "signed_up,placed_order,was_deleted"

core_section C06
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
core C06.1 "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C003'")" "1"
core C06.2 "$(q "SELECT email FROM v_customer WHERE customer_ref='C003'")" "new@x.com"
later M04 "recency: two staged rows -> one signed_up, no spurious update" "$(acts C003)" "signed_up"

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

core_section C08
feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'
core C08.1 "$(q "SELECT json_extract(feature_json,'\$.basis') FROM customer_stream WHERE customer='C003' AND activity='was_deleted'")" "FULL_ABSENCE"
core C08.2 "$(ans 1)" "C001"
core C08.3 "$(ans 2)" "C002,C003"
core C08.4 "$(ans 3)" "alice@example.com>alice@newmail.com"
later M04 "reconcile: C002 already deleted -> not deleted twice" \
   "$(q "SELECT COUNT(*) FROM customer_stream WHERE customer='C002' AND activity='was_deleted'")" "1"
later M04 "reconcile: D5 wrote exactly one activity (the C003 delete)" "$(by_src D5)" "1"

core_section C09
before_r="$(census)"
feed d5_cust_yearly_full.sql D5R '2027-01-10 08:00:00'
core C09.1 "$(census)" "$before_r"
later M06 "FIRST EVER: days from signup to first order (C001)" \
   "$(q "SELECT days_to_first_order FROM v_customer_journey WHERE customer_ref='C001'")" "27"
later M06 "FIRST AFTER: C001 changed email after the first order, on 2026-03-02" \
   "$(q "SELECT email_changed_after_first_order FROM v_customer_journey WHERE customer_ref='C001'")" "2026-03-02 00:00:00"
later M06 "FIRST AFTER: C002 never did" \
   "$(q "SELECT COALESCE(email_changed_after_first_order,'<none>') FROM v_customer_journey WHERE customer_ref='C002'")" "<none>"
later M06 "journeys survive deletes: all three customers, C003 with no orders" \
   "$(q "SELECT group_concat(customer_ref||':'||orders_placed,',') FROM v_customer_journey")" "C001:1,C002:1,C003:0"
later M06 "no foreign keys anywhere: relationships are who + what + when" \
   "$(q "SELECT COUNT(*) FROM pragma_foreign_key_list('customer_stream')")$(q "SELECT COUNT(*) FROM pragma_foreign_key_list('product_stream')")" "00"

core_section C10
later M08 "UPDATE on customer_stream aborts" "$(db_refused "UPDATE customer_stream SET ts='x';" "immutable")" "refused"
later M08 "DELETE on product_stream aborts"  "$(db_refused "DELETE FROM product_stream;" "immutable")" "refused"
later M08 "activity_id and _seq are dense and unique per stream" \
   "$(q "SELECT (SELECT COUNT(DISTINCT activity_id)=MAX(_seq) AND MIN(_seq)=1 FROM customer_stream)
              ||(SELECT COUNT(DISTINCT activity_id)=MAX(_seq) AND MIN(_seq)=1 FROM product_stream)")" "11"
core C10.1 "$(aq "SELECT (SELECT COUNT(*) FROM arch.hist_customer)+(SELECT COUNT(*) FROM arch.hist_product)
              +(SELECT COUNT(*) FROM arch.hist_order)+(SELECT COUNT(*) FROM arch.hist_order_line)")" \
           "$(aq 'SELECT SUM(row_count) FROM arch.loaded_files')"
later M08 "only differences become activities: fewer customer activities than staged customer rows + orders" \
   "$(aq "SELECT (SELECT COUNT(*) FROM customer_stream WHERE activity NOT LIKE '%order%')
                 < (SELECT COUNT(*) FROM arch.hist_customer)")" "1"
core_abort C10.2 "UPDATE hist_customer SET full_name='x';" "append-only"
core_abort C10.3 "DELETE FROM hist_order;" "append-only"

core_section C11
ingested="$(snap)"
rm -f "$DB"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
core C11.1 "$(snap)" "$ingested"

core_section C12
# The streams keep raw codes; the label is joined on read, so one UPDATE of
# the reference table relabels every order activity, past and present.
q "UPDATE ref_oms_order_status SET status_name='PLACED' WHERE status_code='P';" >/dev/null
core C12.1 "$(ans 9)" "O-100=PLACED,O-101=PLACED"
later M07 "live ref change is visible immediately in v_order" "$(q "SELECT DISTINCT status FROM v_order")" "PLACED"
later M07 "...while the stream still holds the raw code" \
   "$(q "SELECT DISTINCT json_extract(feature_json,'\$.status') FROM customer_stream WHERE activity='placed_order'")" "P"
q "UPDATE ref_oms_order_status SET status_name='PENDING' WHERE status_code='P';" >/dev/null

core_section C13
feed d6_repoint.sql D6 '2027-02-01 08:00:00' "$HERE/fixtures"
core C13.1 "$(ans 8)" "Alice Smith"
core C13.2 "$(q "SELECT customer FROM customer_stream WHERE link='O-101' AND activity='placed_order'")" "C002"
later M09 "repoint: order_reassigned lands in C001's stream" "$(acts C001)" "signed_up,placed_order,updated_email,order_reassigned"
later M09 "repoint: it records where the order came from" \
   "$(q "SELECT link||' from '||json_extract(feature_json,'\$.from_customer') FROM customer_stream WHERE activity='order_reassigned'")" "O-101 from C002"
later M09 "repoint: C002's placed_order is untouched (immutable)" "$(acts C002)" "signed_up,placed_order,was_deleted"
later M09 "repoint: unchanged order attributes -> no order_updated" \
   "$(q "SELECT COUNT(*) FROM customer_stream WHERE activity='order_updated'")" "0"
later M09 "repoint: LAST BEFORE at purchase still Bob Jones" \
   "$(q "SELECT placed_by_at_purchase FROM v_order_at_purchase WHERE order_ref='O-101'")" "Bob Jones"
later M09 "repoint: ownership read against each activity's own moment" \
   "$(q "SELECT group_concat(COALESCE(owner_name_then,'<none>'),',') FROM
           (SELECT owner_name_then FROM v_order_ownership WHERE order_ref='O-101' ORDER BY recorded_at)")" "Bob Jones,Alice Smith"
before_d6r="$(census)"
feed d6_repoint.sql D6R '2027-02-15 08:00:00' "$HERE/fixtures"
later M09 "re-asserted repoint writes nothing" "$(census)" "$before_d6r"

core_section C14
core C14.1 "$(q "SELECT group_concat(customer_ref||'('||COALESCE(email,'null')||')',' ')
                 FROM (SELECT * FROM v_customer ORDER BY customer_ref)")" "C001(alice@newmail.com)"

banner "2: MODEL  (what the Activity Schema shows on its own)"
FEED_SEC=""

own_section M01 "Manifest, stage and catalog after every delivery"
replay M01
own_section M02 "The model: two activity streams, nothing else holds data"
replay M02
own_section M03 "Baseline values on D0"
replay M03
own_section M04 "Snapshots become activities; NOCHANGE writes none"
replay M04
own_section M05 "Event time and observed time"
replay M05
own_section M06 "Temporal joins: questions the model was built for"
replay M06
own_section M07 "Soft rule on read"
replay M07
own_section M08 "Streams are immutable; only differences become activities"
replay M08
own_section M09 "Re-point: a NEW activity, nothing changes"
replay M09

own_section M10 "Lifecycle paths: restore, order update, line removal"
feed d7_lifecycle.sql D7 '2027-03-01 08:00:00' "$HERE/fixtures"
own "a deleted customer delivered again is restored (not signed up twice)" \
   "$(acts C002)" "signed_up,placed_order,was_deleted,restored"
own "restored C002 is back in v_customer" \
   "$(q "SELECT customer_name FROM v_customer WHERE customer_ref='C002'")" "Bob Jones"
own "status P -> S is one order_updated; v_order shows SHIPPED" \
   "$(q "SELECT COUNT(*) FROM customer_stream WHERE activity='order_updated'")/$(q "SELECT status FROM v_order WHERE order_ref='O-100'")" "1/SHIPPED"
own "the update does not rewrite history: placed_order still holds 'P'" \
   "$(q "SELECT json_extract(feature_json,'\$.status') FROM customer_stream WHERE link='O-100' AND activity='placed_order'")" "P"
own "a tombstoned line is removed_from_order, gone from v_order_line" \
   "$(q "SELECT COUNT(*) FROM product_stream WHERE activity='removed_from_order'")/$(q "SELECT group_concat(sku) FROM v_order_line WHERE order_ref='O-100'")" "1/SKU-2"
own "restoring C002 does not move O-101 back (ownership is its own activity)" \
   "$(q "SELECT placed_by FROM v_order WHERE order_ref='O-101'")" "Alice Smith"
own "D7 wrote exactly three activities" "$(by_src D7)" "3"

own_section M11 "Ordering guarantees: same-extract tiebreak, key-ordered activity ids"
feed d8_tiebreak.sql D8 '2027-04-01 08:00:00' "$HERE/fixtures"
own "tiebreak: same extract_dt -> the later staged row wins" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "tie-second@x.com"
own "tiebreak: one updated_email for C001, not two" \
   "$(q "SELECT COUNT(*) FROM customer_stream WHERE _record_source='D8' AND customer='C001'")" "1"
own "activity ids follow the loader's fixed order (step, then business key), not staged order" \
   "$(q "SELECT group_concat(customer||':'||activity,',') FROM
           (SELECT customer, activity FROM customer_stream WHERE _record_source='D8' ORDER BY _seq)")" \
   "C004:signed_up,C005:signed_up,C001:updated_email"
own "...and for order lines: numbered by (sku, order), not the stage's (order, sku)" \
   "$(q "SELECT group_concat(customer||':'||link,',') FROM
           (SELECT customer, link FROM product_stream WHERE _record_source='D8' ORDER BY _seq)")" \
   "SKU-1:O-101,SKU-3:O-100"

own_section M12 "Rebuild again: fixtures included, replay is still exact"
ingested2="$(snap)"
rm -f "$DB"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
own "clean+rebuild after re-point, lifecycle and tiebreak: streams identical" "$(snap)" "$ingested2"

own_section M13 "Load control: a file_id names CONTENT (same block in all ten suites)"
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
