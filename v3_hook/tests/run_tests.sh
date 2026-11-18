#!/usr/bin/env bash
# =====================================================================
# HOOK test suite.
#
# PART 1, CORE: the fourteen sections every one of the ten suites runs,
# in the same order and with the same labels (tests/core_spec.tsv at the
# repo root). Each model supplies its own SQL; the nine question
# answers live in tests/answers/Q<n>.sql.
# PART 2, MODEL: what HOOK shows on its own -- hooks qualified by key
# set, relationships as extra hooks on the row (no link tables),
# insert-only delta frames, hubs derived on demand, soft rules on read,
# the re-point as a plain frame row, and hook-integrity checking.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/hook_test).db}"
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

# The frames refuse UPDATE and DELETE too (the shared refused() reads the
# archive): "refused" if the statement fails with the expected message.
frame_refused(){ local out; out="$("$SQLITE" "$DB" "$1" 2>&1)"
                 case "$out" in *"$2"*) printf 'refused';; *) printf '%s' "$out";; esac; }

census(){ q "SELECT group_concat(t||'='||n,' ') FROM (
    SELECT 1 o,'cust' t,COUNT(*) n FROM frame__crm__customer
    UNION ALL SELECT 2,'prod',  COUNT(*) FROM frame__pim__product
    UNION ALL SELECT 3,'ord',   COUNT(*) FROM frame__oms__order
    UNION ALL SELECT 4,'line',  COUNT(*) FROM frame__oms__order_line
    ORDER BY o);"; }
archive_state(){ aq "SELECT (SELECT COUNT(*) FROM arch.loaded_files)||'/'||(SELECT COUNT(*) FROM arch.hist_customer)
                      ||'/'||(SELECT COUNT(*) FROM arch.hist_product)||'/'||(SELECT COUNT(*) FROM arch.hist_order)
                      ||'/'||(SELECT COUNT(*) FROM arch.hist_order_line)"; }

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

# Run one delivery; abort the suite if the loader crashes. Its manifest,
# stage and hook-integrity checks are model assertions, reported in M01.
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
  [ "$SKIPPED" -eq 0 ] && later M01 "[$file_id] manifest: COMPLETE after the loader" \
     "$(aq "SELECT status FROM arch.loaded_files WHERE file_id='$file_id'")" "COMPLETE"
  later M01 "[$file_id] stage blank after delivery" \
     "$(q "SELECT (SELECT COUNT(*) FROM stg_customer_l1)+(SELECT COUNT(*) FROM stg_product_l1)
                +(SELECT COUNT(*) FROM stg_order_l1)+(SELECT COUNT(*) FROM stg_order_line_l1)")" "0"
  later M01 "[$file_id] hook integrity: every hook uses its registered key set" \
     "$(q "SELECT COUNT(*) FROM v_hook_violation")" "0"; }

rows(){ q "SELECT COUNT(*) FROM frame__crm__customer WHERE hk_customer='CRM.CUST|$1'"; }
latest_c(){ q "SELECT change_type||'/'||COALESCE(delete_basis,'') FROM v_latest__crm__customer
               WHERE hk_customer='CRM.CUST|$1'"; }

banner "1: CORE  (the same fourteen sections, in this order, in all ten suites)"

core_section C01
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null
core C01.1 "$(census)|$(archive_state)" "cust=0 prod=0 ord=0 line=0|0/0/0/0/0"
later M02 "registry: every frame column named in hook_column exists on its frame" \
   "$(q "SELECT COUNT(*) FROM hook_column c
         WHERE NOT EXISTS (SELECT 1 FROM pragma_table_info(c.frame) p WHERE p.name=c.hook_column)")" "0"
later M02 "registry: every hk_* column on every frame is registered" \
   "$(q "SELECT COUNT(*) FROM hook_frame f, pragma_table_info(f.frame) p
         WHERE p.name LIKE 'hk\_%' ESCAPE '\\'
           AND NOT EXISTS (SELECT 1 FROM hook_column c WHERE c.frame=f.frame AND c.hook_column=p.name)")" "0"
later M02 "registry: v_hook_occurrence covers every registered hook column" \
   "$(q "SELECT COUNT(*) FROM hook_column")" "6"
later M02 "no hub, link or satellite tables -- data lives only in frames" \
   "$(q "SELECT group_concat(name,',') FROM (SELECT name FROM sqlite_master
         WHERE type='table' AND name NOT LIKE 'stg\_%' ESCAPE '\\'
           AND name NOT LIKE 'hook\_%' ESCAPE '\\' AND name NOT LIKE 'ref\_%' ESCAPE '\\'
         ORDER BY name)")" "frame__crm__customer,frame__oms__order,frame__oms__order_line,frame__pim__product"

core_section C02
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
core C02.1 "$(q "SELECT (SELECT COUNT(*) FROM v_customer)||'/'||(SELECT COUNT(*) FROM v_product)
                ||'/'||(SELECT COUNT(*) FROM v_order)||'/'||(SELECT COUNT(DISTINCT hk_order||hk_product) FROM frame__oms__order_line)")" "2/3/2/3"
core C02.2 "$(ans 5)" "PENDING"
core C02.3 "$(ans 6)" "48.99"
later M03 "baseline: C001 email v1" "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@example.com"
later M02 "HOOK = key set + business key" \
   "$(q "SELECT hk_customer FROM frame__crm__customer WHERE customer_id='C001'")" "CRM.CUST|C001"
later M02 "frame keeps the source columns verbatim (raw customer_id beside the hook)" \
   "$(q "SELECT customer_id||'/'||full_name FROM frame__crm__customer WHERE hk_customer='CRM.CUST|C001'")" "C001/Alice Smith"
later M02 "relationship = a second hook on the order row (no link table)" \
   "$(q "SELECT hk_order||' -> '||hk_customer FROM frame__oms__order WHERE order_ref='O-100'")" "OMS.ORD|O-100 -> CRM.CUST|C001"
later M02 "order line frame grain is the hook pair (3 pairs)" \
   "$(q "SELECT COUNT(DISTINCT hk_order||hk_product) FROM frame__oms__order_line")" "3"
later M07 "SOFT RULE ON READ: frame stores raw 'P', v_order decodes PENDING" \
   "$(q "SELECT (SELECT status FROM frame__oms__order WHERE order_ref='O-100')||'/'||
                (SELECT status FROM v_order WHERE order_ref='O-100')")" "P/PENDING"
later M04 "lineage: every frame row names its delivery" \
   "$(q "SELECT group_concat(DISTINCT record_source) FROM frame__oms__order_line")" "B0"

core_section C03
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
core C03.1 "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@newmail.com"
core C03.2 "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "1"
core C03.3 "$(rows C002)" "1"
core C03.4 "$(q "SELECT COUNT(DISTINCT full_name)||'/'||COUNT(DISTINCT signup_date) FROM frame__crm__customer
                 WHERE hk_customer='CRM.CUST|C001'")" "1/1"
later M04 "delta: C001 now 2 frame rows, the new one an UPDATE" \
   "$(q "SELECT COUNT(*)||'/'||(SELECT change_type FROM v_latest__crm__customer WHERE hk_customer='CRM.CUST|C001')
         FROM frame__crm__customer WHERE hk_customer='CRM.CUST|C001'")" "2/UPDATE"
later M04 "insert-only: C001's first row still holds the old email" \
   "$(q "SELECT email_addr FROM frame__crm__customer WHERE hk_customer='CRM.CUST|C001' AND load_ts='2026-02-05 08:00:00'")" "alice@example.com"
later M02 "HOOK JOIN: v_order resolves placed_by through the shared CRM.CUST key set" \
   "$(q "SELECT placed_by FROM v_order WHERE order_ref='O-100'")" "Alice Smith"

core_section C04
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
core C04.1 "$(q "SELECT price FROM v_product WHERE sku='SKU-1'")" "8.99"
core C04.2 "$(q "SELECT COUNT(*) FROM v_product WHERE sku='SKU-3'")" "0"
core C04.3 "$(q "SELECT COUNT(*) FROM frame__pim__product WHERE hk_product='PIM.SKU|SKU-2'")" "1"
core C04.4 "$(ans 4)" "9.99>8.99"
later M04 "FULL: SKU-3 gets a DELETE row, basis FULL_ABSENCE" \
   "$(q "SELECT change_type||'/'||delete_basis FROM v_latest__pim__product WHERE hk_product='PIM.SKU|SKU-3'")" "DELETE/FULL_ABSENCE"
later M04 "FULL: the DELETE row carries the business key, no attributes" \
   "$(q "SELECT sku||'/'||COALESCE(prod_name,'<null>') FROM v_latest__pim__product WHERE hk_product='PIM.SKU|SKU-3'")" "SKU-3/<null>"
later M04 "FULL product feed leaves the other frames untouched" \
   "$(q "SELECT COUNT(*) FROM frame__oms__order_line WHERE record_source<>'B0'")" "0"

core_section C05
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
core C05.1 "$(latest_c C002)" "DELETE/TOMBSTONE"
core C05.2 "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "0"
core C05.3 "$(q "SELECT COALESCE(placed_by,'<none>') FROM v_order WHERE order_ref='O-101'")" "<none>"
core C05.4 "$(q "SELECT full_name||'/'||email_addr FROM frame__crm__customer
                 WHERE hk_customer='CRM.CUST|C002' AND change_type<>'DELETE' ORDER BY load_ts DESC LIMIT 1")" \
           "Bob Jones/bob@example.com"
core C05.5 "$(ans 7)" "Bob Jones"
later M04 "tombstone: C002 has exactly one DELETE row" \
   "$(q "SELECT COUNT(*) FROM frame__crm__customer WHERE hk_customer='CRM.CUST|C002' AND change_type='DELETE'")" "1"

core_section C06
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
core C06.1 "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C003'")" "1"
core C06.2 "$(q "SELECT email FROM v_customer WHERE customer_ref='C003'")" "new@x.com"
later M04 "recency: one delivery -> one frame row" "$(rows C003)" "1"

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
core C08.1 "$(latest_c C003)" "DELETE/FULL_ABSENCE"
core C08.2 "$(ans 1)" "C001"
core C08.3 "$(ans 2)" "C002,C003"
core C08.4 "$(ans 3)" "alice@example.com>alice@newmail.com"
later M04 "reconcile: C001 unchanged content -> zero churn (still 2)" "$(rows C001)" "2"
later M04 "reconcile: C002 already deleted -> zero churn (still 2)"   "$(rows C002)" "2"
later M04 "reconcile: D5 wrote exactly one frame row (the C003 delete)" \
   "$(q "SELECT COUNT(*) FROM frame__crm__customer WHERE record_source='D5'")" "1"

core_section C09
before_r="$(census)"
feed d5_cust_yearly_full.sql D5R '2027-01-10 08:00:00'
core C09.1 "$(census)" "$before_r"
later M05 "CUSTOMER concept: 3 members ever seen (deleted ones included)" \
   "$(q "SELECT COUNT(*) FROM v_concept_member WHERE concept='CUSTOMER'")" "3"
later M05 "C001 is hooked from two frames (CRM customer + OMS order)" \
   "$(q "SELECT frames FROM v_concept_member WHERE hook='CRM.CUST|C001'")" "frame__crm__customer,frame__oms__order"
later M05 "SKU-3 never ordered: hooked from the product frame only" \
   "$(q "SELECT n_frames FROM v_concept_member WHERE hook='PIM.SKU|SKU-3'")" "1"
later M05 "integration: every order's customer hook lands on a customer frame row" \
   "$(q "SELECT COUNT(*) FROM frame__oms__order o WHERE o.hk_customer IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM frame__crm__customer c WHERE c.hk_customer=o.hk_customer)")" "0"

core_section C10
later M06 "UPDATE on a frame aborts" "$(frame_refused "UPDATE frame__crm__customer SET full_name='x';" "insert-only")" "refused"
later M06 "DELETE on a frame aborts" "$(frame_refused "DELETE FROM frame__oms__order;" "insert-only")" "refused"
core C10.1 "$(aq "SELECT (SELECT COUNT(*) FROM arch.hist_customer)+(SELECT COUNT(*) FROM arch.hist_product)
              +(SELECT COUNT(*) FROM arch.hist_order)+(SELECT COUNT(*) FROM arch.hist_order_line)")" \
           "$(aq 'SELECT SUM(row_count) FROM arch.loaded_files')"
later M06 "frames are delta-compressed: fewer rows than the archive holds" \
   "$(aq "SELECT (SELECT COUNT(*) FROM frame__crm__customer) < (SELECT COUNT(*) FROM arch.hist_customer)")" "1"
core_abort C10.2 "UPDATE hist_customer SET full_name='x';" "append-only"
core_abort C10.3 "DELETE FROM hist_order;" "append-only"

core_section C11
ingested="$(snap)"
rm -f "$DB"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
core C11.1 "$(snap)" "$ingested"

core_section C12
# The decode is a reference table read at query time: one UPDATE relabels
# every frame row, current and historical, with no reload.
q "UPDATE ref_oms_order_status SET status_name='PLACED' WHERE status_code='P';" >/dev/null
core C12.1 "$(ans 9)" "O-100=PLACED,O-101=PLACED"
later M07 "live ref change is visible immediately in v_order" \
   "$(q "SELECT DISTINCT status FROM v_order")" "PLACED"
later M07 "...while the frames still hold the raw code" \
   "$(q "SELECT DISTINCT status FROM frame__oms__order")" "P"
q "UPDATE ref_oms_order_status SET status_name='PENDING' WHERE status_code='P';" >/dev/null

core_section C13
feed d6_repoint.sql D6 '2027-02-01 08:00:00' "$HERE/fixtures"
core C13.1 "$(ans 8)" "Alice Smith"
core C13.2 "$(q "SELECT hk_customer FROM frame__oms__order WHERE order_ref='O-101' AND load_ts='2026-02-05 08:00:00'")" "CRM.CUST|C002"
later M08 "repoint: O-101 has 2 frame rows, the new one an UPDATE" \
   "$(q "SELECT COUNT(*)||'/'||(SELECT change_type FROM v_latest__oms__order WHERE order_ref='O-101')
         FROM frame__oms__order WHERE order_ref='O-101'")" "2/UPDATE"
later M08 "repoint: latest hook points at CRM.CUST|C001" \
   "$(q "SELECT hk_customer FROM v_latest__oms__order WHERE order_ref='O-101'")" "CRM.CUST|C001"
later M08 "repoint: exactly one current customer per order" \
   "$(q "SELECT COUNT(*) FROM v_latest__oms__order WHERE order_ref='O-101'")" "1"
later M08 "repoint: as-recorded reads each row against its own moment" \
   "$(q "SELECT group_concat(COALESCE(placed_by_as_recorded,'<none>'),',') FROM
           (SELECT placed_by_as_recorded FROM v_order_as_recorded WHERE order_ref='O-101' ORDER BY recorded_at)")" "Bob Jones,Alice Smith"
before_d6r="$(census)"
feed d6_repoint.sql D6R '2027-02-15 08:00:00' "$HERE/fixtures"
later M08 "re-asserted repoint writes nothing" "$(census)" "$before_d6r"

core_section C14
core C14.1 "$(q "SELECT group_concat(customer_ref||'('||COALESCE(email,'null')||')',' ')
                 FROM (SELECT * FROM v_customer ORDER BY customer_ref)")" "C001(alice@newmail.com)"

banner "2: MODEL  (what HOOK shows on its own)"

own_section M01 "Manifest, stage and hook integrity after every delivery"
replay M01
own_section M02 "Hooks: a registry, four frames, no hubs or links"
replay M02
own_section M03 "Baseline values on D0"
replay M03
own_section M04 "Insert-only delta frames"
replay M04
own_section M05 "Hubs on demand: concepts are derived, not stored"
replay M05
own_section M06 "Frames are insert-only, and smaller than the archive"
replay M06
own_section M07 "Soft rule on read"
replay M07
own_section M08 "Re-point as a plain frame row"
replay M08

own_section M09 "Hook integrity: a bad key set is caught"
q "INSERT INTO frame__oms__order(hk_order, hk_customer, order_ref, change_type, diff_str, load_ts, record_source)
   VALUES('OMS.ORD|O-999','ERP.CUST|C001','O-999','INSERT','x','2027-03-01 00:00:00','TEST');" >/dev/null
own "a customer hook from an unregistered/wrong key set is flagged" \
   "$(q "SELECT hook_column||'='||hook||' expected '||expected_keyset FROM v_hook_violation")" \
   "hk_customer=ERP.CUST|C001 expected CRM.CUST"
own "...and does NOT integrate: ERP.CUST|C001 is not CRM.CUST|C001" \
   "$(q "SELECT COALESCE(placed_by,'<none>') FROM v_order WHERE order_ref='O-999'")" "<none>"

own_section M10 "Load control: a file_id names CONTENT (same block in all ten suites)"
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

own_section M11 "Restore after delete, and the same-extract tiebreak through replay"
# Own database pair: the fixtures never reach the core scenario. Neither
# case occurs in the shared deliveries, so without this section the
# frame loader's restore path, the rowid tiebreak and the replay row
# order could all be broken without a single assertion failing.
export DB="$LOGDIR/m11.db" ARCHIVE_DB="$LOGDIR/m11_archive.db"
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null 2>&1
m11(){ BATCH_TS="$3" "$PROJ/scripts/load_feed.sh" "$1" "$2" >/dev/null 2>&1 || echo "  (load_feed.sh $2 exited $?)"; }
m11 "$PROJ/source/d0_baseline.sql"       B0 '2026-02-05 08:00:00'
m11 "$PROJ/source/d3_cust_tombstone.sql" D3 '2026-03-16 08:00:00'
m11 "$HERE/fixtures/d7_restore.sql"      D7 '2027-04-01 08:00:00'
own "restore: C002 re-sent with its pre-delete values is live again" \
   "$(q "SELECT customer_name||'/'||email FROM v_customer WHERE customer_ref='C002'")" "Bob Jones/bob@example.com"
own "restore: frame rows INSERT > DELETE > INSERT" \
   "$(q "SELECT group_concat(change_type,'>') FROM (SELECT change_type FROM frame__crm__customer WHERE customer_id='C002' ORDER BY load_ts)")" "INSERT>DELETE>INSERT"
m11 "$HERE/fixtures/d8_tiebreak_wide.sql" D8 '2027-04-02 08:00:00'
own "tiebreak: equal extract_dt -> the last row in the file wins" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C004'")" "last@x.com"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
own "tiebreak: still the last row after rebuild (seq_nbr order restored)" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C004'")" "last@x.com"
own "restore: still live after rebuild" \
   "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "1"
export DB="$SAVE_DB" ARCHIVE_DB="$SAVE_ARCHIVE_DB"

rm -f "$DB" "$ARCHIVE_DB"
summary
