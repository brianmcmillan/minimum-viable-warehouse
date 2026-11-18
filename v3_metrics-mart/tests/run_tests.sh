#!/usr/bin/env bash
# =====================================================================
# Metrics mart test suite.
#
# PART 1, CORE: the fourteen sections every one of the ten suites runs,
# in the same order and with the same labels (tests/core_spec.tsv at the
# repo root). Each model supplies its own SQL; the nine question
# answers live in tests/answers/Q<n>.sql. The mart keeps current state
# only; history it updated away is answered from the raw archive, the
# final answer. One core assertion is a known GAP (C04.3).
# PART 2, MODEL: what the metrics mart shows on its own -- one RES table
# for every type, metrics as samples, code tables, groups, aggregates
# over CALNDR weeks, updates in place, and its fixtures.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/metrics_test).db}"
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

# An answer that reads the raw archive: tests/answers/Q<n>.sql run with the
# archive attached as `arch` (the files say so in their header).
aans(){ local out rc=0
        out="$("$SQLITE" -cmd "ATTACH DATABASE '$ARCHIVE_DB' AS arch" "$DB" < "$HERE/answers/Q$1.sql" 2>&1)" || rc=$?
        [ "$rc" -eq 0 ] || { printf "  \033[31mSQL ERROR\033[0m Q%s: %s\n" "$1" "$out" >&2
                             printf '<SQL-ERROR>'; return 0; }
        printf '%s' "$out"; }
archive_state(){ aq "SELECT (SELECT COUNT(*) FROM arch.loaded_files)||'/'||(SELECT COUNT(*) FROM arch.hist_customer)
                      ||'/'||(SELECT COUNT(*) FROM arch.hist_product)||'/'||(SELECT COUNT(*) FROM arch.hist_order)
                      ||'/'||(SELECT COUNT(*) FROM arch.hist_order_line)"; }
census(){ q "SELECT group_concat(t||'='||n,' ') FROM (
    SELECT 1 o,'res' t,COUNT(*) n FROM res
    UNION ALL SELECT 2,'live',    COUNT(*) FROM res WHERE res_status=1
    UNION ALL SELECT 3,'alias',   COUNT(*) FROM res_alias
    UNION ALL SELECT 4,'grp',     COUNT(*) FROM res_grp
    UNION ALL SELECT 5,'member',  COUNT(*) FROM res_resgrp
    UNION ALL SELECT 6,'provider',COUNT(*) FROM provider
    UNION ALL SELECT 7,'sample',  COUNT(*) FROM metric_sample
    UNION ALL SELECT 8,'summary', COUNT(*) FROM metric_summary
    UNION ALL SELECT 9,'weekly',  COUNT(*) FROM metric_weekly
    UNION ALL SELECT 10,'grpwk',  COUNT(*) FROM grp_metric_weekly
    ORDER BY o);"; }

# Full logical snapshot: every surrogate, value and srcd_ts in the mart.
snap(){ q "
  SELECT 'res', res_id, res_type||'|'||res_code||'|'||res_name||'|'||COALESCE(parent_res,'')||'|'||res_status, srcd_ts FROM res
  UNION ALL SELECT 'alias', res_id, res_type||'|'||res_alias, srcd_ts FROM res_alias
  UNION ALL SELECT 'cust', res_id, COALESCE(email_addr,'')||'|'||COALESCE(signup_date,''), srcd_ts FROM res_customer
  UNION ALL SELECT 'prod', res_id, COALESCE(currency_code,''), srcd_ts FROM res_product
  UNION ALL SELECT 'ord',  res_id, COALESCE(status_code,'')||'|'||COALESCE(currency_code,'')||'|'||COALESCE(placed_at,''), srcd_ts FROM res_order
  UNION ALL SELECT 'cur', 0, currency_code, srcd_ts FROM currency
  UNION ALL SELECT 'prov', provider_id, provider_name, srcd_ts FROM provider
  UNION ALL SELECT 'grp', res_grp_id, group_path||'|'||COALESCE(parent_res_grp,'')||'|'||group_level, srcd_ts FROM res_grp
  UNION ALL SELECT 'mem', res_grp_id, res_id, srcd_ts FROM res_resgrp
  UNION ALL SELECT 'smp', res_id, metric_id||'|'||sample_utc_ts||'|'||provider_id||'|'||value, srcd_d2k FROM metric_sample
  UNION ALL SELECT 'sum', res_id, metric_id||'|'||start_utc_ts||'|'||value||'|'||value_cnt, srcd_ts FROM metric_summary
  UNION ALL SELECT 'wk',  res_id, metric_id||'|'||start_lcl_dt||'|'||value||'|'||value_cnt, srcd_ts FROM metric_weekly
  UNION ALL SELECT 'gwk', res_id, res_grp_id||'|'||metric_id||'|'||start_lcl_dt||'|'||value, srcd_ts FROM grp_metric_weekly
  ORDER BY 1,2,3,4;"; }

status(){ q "SELECT status FROM v_res WHERE res_type='$1' AND res_code='$2'"; }
# Rows the archive holds: the shared wide layout (hist_* per source
# extract); optional $1 = file_id.
hist_rows(){ local w=""; [ -n "${1:-}" ] && w=" WHERE file_id='$1'"
  aq "SELECT (SELECT COUNT(*) FROM arch.hist_customer$w)+(SELECT COUNT(*) FROM arch.hist_product$w)
            +(SELECT COUNT(*) FROM arch.hist_order$w)+(SELECT COUNT(*) FROM arch.hist_order_line$w)"; }
# Level 2: a narrow-by-nature delivery straight into the narrow stage and
# through apply_delivery.sh -- no load control, no archive. $1 file,
# $2 BATCH_TS, $3 BATCH_NO.
level2(){ "$SQLITE" "$DB" "DELETE FROM source_landing_stage;"; "$SQLITE" "$DB" < "$1"
          BATCH_TS="$2" BATCH_NO="$3" "$PROJ/scripts/apply_delivery.sh" >/dev/null 2>&1; }
price(){  q "SELECT printf('%.2f', price) FROM v_product WHERE sku='$1'"; }
nsamp(){  q "SELECT COUNT(*) FROM v_metric_sample WHERE res_code='$1' AND metric_code='$2'"; }


# Run one delivery; abort the suite if a loader crashes. Its manifest,
# stage and integrity checks are model assertions: reported in M01 for
# the PART 1 deliveries, at once for PART 2 ones (FEED_SEC empty).
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
  [ "$SKIPPED" -eq 0 ] && fchk "[$file_id] manifest: COMPLETE after all loaders" \
     "$(aq "SELECT status FROM arch.loaded_files WHERE file_id='$file_id'")" "COMPLETE"
  fchk "[$file_id] stage blank after delivery" \
     "$(q 'SELECT COUNT(*) FROM source_landing_stage')" "0"
  fchk "[$file_id] integrity views empty" \
     "$(q 'SELECT (SELECT COUNT(*) FROM v_res_type_rel_violation)+(SELECT COUNT(*) FROM v_res_grp_path_violation)')" "0"
  return 0; }

banner "1: CORE  (the same fourteen sections, in this order, in all ten suites)"

core_section C01
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null
core C01.1 "$(census)|$(archive_state)" \
  "res=0 live=0 alias=0 grp=0 member=0 provider=0 sample=0 summary=0 weekly=0 grpwk=0|0/0/0/0/0"

core_section C02
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
core C02.1 "$(q "SELECT (SELECT COUNT(*) FROM v_customer)||'/'||(SELECT COUNT(*) FROM v_product)
                ||'/'||(SELECT COUNT(*) FROM v_order)||'/'||(SELECT COUNT(*) FROM v_order_line)")" "2/3/2/3"
core C02.2 "$(ans 5)" "PENDING"
core C02.3 "$(ans 6)" "48.99"
later M02 "baseline: one RES table holds all three types" \
   "$(q "SELECT group_concat(res_type||'='||n,',') FROM (SELECT res_type, COUNT(*) n FROM res GROUP BY res_type ORDER BY res_type)")" \
   "CUSTOMER=2,ORDER=2,PRODUCT=3"
later M02 "baseline: deterministic res_id in (res_type, res_code) order" \
   "$(q "SELECT group_concat(res_code||'='||res_id,',') FROM (SELECT * FROM res ORDER BY res_id)")" \
   "C001=1,C002=2,O-100=3,O-101=4,SKU-1=5,SKU-2=6,SKU-3=7"
later M02 "baseline: providers created from source_system, in name order" \
   "$(q "SELECT group_concat(provider_name||'='||provider_id,',') FROM (SELECT * FROM provider ORDER BY provider_id)")" \
   "CRM=1,OMS=2,PIM=3"
later M02 "baseline: every resource has an alias that resolves to it" \
   "$(q "SELECT COUNT(*) FROM res r JOIN res_alias a ON a.res_type=r.res_type AND a.res_alias=r.res_code AND a.res_id=r.res_id")" "7"
later M02 "baseline: C001 email v1" "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@example.com"
later M02 "baseline: batch_no on the staging rows is the archive's load_seq" \
   "$(aq "SELECT (SELECT DISTINCT batch_no FROM res_stg)||'/'||(SELECT load_seq FROM arch.loaded_files WHERE file_id='B0')")" "1/1"
later M03 "METRIC: numeric attributes are samples, not columns (3 prices + 2 amounts)" \
   "$(q "SELECT group_concat(metric_code||'='||n,',') FROM (SELECT metric_code, COUNT(*) n FROM v_metric_sample GROUP BY metric_code ORDER BY metric_code)")" \
   "amount=2,price=3"
later M03 "METRIC: no price or amount column exists on any resource table" \
   "$(q "SELECT COUNT(*) FROM pragma_table_info('res') WHERE name IN ('price','amount')")" "0"
later M03 "METRIC: METRIC_STG2 resolved every staged name to a surrogate" \
   "$(q "SELECT COUNT(*)||'/'||SUM(res_id IS NOT NULL AND metric_id IS NOT NULL AND provider_id IS NOT NULL) FROM metric_stg2")" "5/5"
later M03 "METRIC: v_product.price reads the newest sample" "$(price SKU-1)" "9.99"
later M03 "METRIC: sample value is typed REAL" \
   "$(q "SELECT DISTINCT typeof(value) FROM metric_sample")" "real"
later M04 "PARENT: O-100's parent resource is customer C001" \
   "$(q "SELECT parent FROM v_res WHERE res_code='O-100'")" "CUSTOMER:C001"
later M04 "CODE TABLE: raw 'P' stored, PENDING decoded on read by a join" \
   "$(q "SELECT (SELECT status_code FROM res_order o JOIN res r USING(res_id) WHERE r.res_code='O-100')||'/'||
                (SELECT status FROM v_order WHERE order_ref='O-100')")" "P/PENDING"
later M04 "CODE TABLE: open currency domain learned USD and EUR from the feed" \
   "$(q "SELECT group_concat(currency_code,',') FROM (SELECT currency_code FROM currency ORDER BY 1)")" "EUR,USD"
later M05 "GROUPS: order lines became 1 root + 2 order groups, 3 memberships" \
   "$(q "SELECT (SELECT COUNT(*) FROM res_grp WHERE group_path='/ORDER' OR group_path LIKE '/ORDER/%')||'/'||
                (SELECT COUNT(*) FROM res_resgrp x JOIN res_grp g USING(res_grp_id) WHERE g.group_path LIKE '/ORDER/%')")" "3/3"
later M05 "TYPE GROUPS: /TYPE plus one group per resource type" \
   "$(q "SELECT group_concat(group_path,',') FROM (SELECT group_path FROM res_grp WHERE group_path='/TYPE' OR group_path LIKE '/TYPE/%' ORDER BY 1)")" \
   "/TYPE,/TYPE/CUSTOMER,/TYPE/ORDER,/TYPE/PRODUCT"
later M05 "GROUPS: res_grp_id in (level, path) order, parents before children" \
   "$(q "SELECT group_concat(group_path||'='||res_grp_id,',') FROM (SELECT * FROM res_grp ORDER BY res_grp_id)")" \
   "/ORDER=1,/TYPE=2,/ORDER/O-100=3,/ORDER/O-101=4,/TYPE/CUSTOMER=5,/TYPE/ORDER=6,/TYPE/PRODUCT=7"
later M05 "TYPE GROUPS: every resource is a member of its type's group" \
   "$(q "SELECT COUNT(*) FROM res r JOIN res_grp g ON g.group_path='/TYPE/'||r.res_type
         JOIN res_resgrp x ON x.res_grp_id=g.res_grp_id AND x.res_id=r.res_id")" "7"
later M05 "GROUPS: parent, level and path agree (/ORDER/O-100 is level 2 under /ORDER)" \
   "$(q "SELECT g.group_level||'/'||p.group_path FROM res_grp g JOIN res_grp p ON p.res_grp_id=g.parent_res_grp WHERE g.group_path='/ORDER/O-100'")" "2//ORDER"
later M05 "GROUPS: v_order_line reads memberships back as order lines" \
   "$(q "SELECT group_concat(order_ref||'~'||sku,',') FROM (SELECT * FROM v_order_line ORDER BY 1,2)")" \
   "O-100~SKU-1,O-100~SKU-2,O-101~SKU-2"
later M06 "AGGREGATES: one daily summary and one week per sample" \
   "$(q "SELECT (SELECT COUNT(*) FROM metric_summary)||'/'||(SELECT COUNT(*) FROM metric_weekly)")" "5/5"
later M06 "AGGREGATES: weeks start on Monday (2026-02-05 is in the week of 02-02)" \
   "$(q "SELECT DISTINCT start_lcl_dt FROM metric_weekly")" "2026-02-02"
later M06 "AGGREGATES: O-100's group week at list price equals its recorded amount" \
   "$(q "SELECT printf('%.2f',value_sum)||'/'||(SELECT printf('%.2f',amount) FROM v_order WHERE order_ref='O-100')
         FROM v_group_weekly WHERE group_path='/ORDER/O-100' AND metric_code='price'")" "29.49/29.49"

core_section C03
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
core C03.1 "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@newmail.com"
core C03.2 "$(status CUSTOMER C002)" "LIVE"
core C03.3 "$(q "SELECT (SELECT srcd_ts FROM res WHERE res_code='C002')||'/'||(SELECT c.srcd_ts FROM res_customer c JOIN res r USING(res_id) WHERE r.res_code='C002')")" \
           "2026-02-05 08:00:00/2026-02-05 08:00:00"
core C03.4 "$(q "SELECT (SELECT srcd_ts FROM res_customer WHERE res_id=1)||'/'||(SELECT srcd_ts FROM res WHERE res_id=1)")" \
           "2026-03-02 08:00:00/2026-02-05 08:00:00"
later M07 "CURRENT STATE: the change is an UPDATE in place (still 1 row for C001)" \
   "$(q "SELECT COUNT(*) FROM res_customer WHERE res_id=1")" "1"
later M07 "CURRENT STATE: the old email is gone from the mart, kept by the archive" \
   "$(aq "SELECT (SELECT COUNT(*) FROM res_customer WHERE email_addr='alice@example.com')||'/'||
                 (SELECT COUNT(DISTINCT email_addr) FROM arch.hist_customer WHERE customer_id='C001')")" "0/2"
later M07 "CURRENT FEEDS ONLY: the CRM delivery did not touch products or samples" \
   "$(q "SELECT (SELECT COUNT(*) FROM metric_sample)||'/'||(SELECT MAX(srcd_ts) FROM res WHERE res_type='PRODUCT')")" \
   "5/2026-02-05 08:00:00"

core_section C04
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
core C04.1 "$(price SKU-1)" "8.99"
core C04.2 "$(q "SELECT COUNT(*) FROM v_product WHERE sku='SKU-3'")" "0"
core_gap C04.3 "$(q "SELECT (SELECT srcd_ts FROM res WHERE res_code='SKU-2')||'/'||(SELECT p.srcd_ts FROM res_product p JOIN res r USING(res_id) WHERE r.res_code='SKU-2')")/$(nsamp SKU-2 price)" \
  "2026-02-05 08:00:00/2026-02-05 08:00:00/1" \
  "an unchanged price seen again is a NEW sample by design (metrics are observations); name and currency wrote nothing"
core C04.4 "$(ans 4)" "9.99>8.99"
later M07 "FULL absence: SKU-3 deleted (res_status = 0)" "$(status PRODUCT SKU-3)" "DELETED"
later M07 "FULL absence: router staged it as load_oper = 'D'" \
   "$(q "SELECT load_oper||'/'||res_status FROM res_stg WHERE res_code='SKU-3'")" "D/0"
later M03 "SKU-3 keeps its samples: measurement history outlives the resource" "$(nsamp SKU-3 price)" "1"
later M03 "OBSERVATION: unchanged SKU-2 price seen again is a NEW sample" "$(nsamp SKU-2 price)" "2"
later M03 "...but its unchanged name and currency wrote nothing" \
   "$(q "SELECT (SELECT srcd_ts FROM res WHERE res_code='SKU-2')||'/'||(SELECT p.srcd_ts FROM res_product p JOIN res r USING(res_id) WHERE r.res_code='SKU-2')")" \
   "2026-02-05 08:00:00/2026-02-05 08:00:00"
later M06 "AGGREGATES: SKU-1 now has two weeks" \
   "$(q "SELECT group_concat(week_start||'='||printf('%.2f',value),',') FROM (SELECT * FROM v_metric_weekly WHERE res_code='SKU-1' ORDER BY week_start)")" \
   "2026-02-02=9.99,2026-03-02=8.99"
later M06 "AGGREGATES: untouched weeks keep their srcd_ts" \
   "$(q "SELECT COUNT(DISTINCT srcd_ts) FROM metric_weekly WHERE start_lcl_dt='2026-02-02'")" "1"
later M06 "AGGREGATES: O-100's group week reprices to 28.49 (amount stays 29.49)" \
   "$(q "SELECT printf('%.2f',value_sum) FROM v_group_weekly WHERE group_path='/ORDER/O-100' AND metric_code='price' AND week_start='2026-03-02'")" "28.49"

core_section C05
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
core C05.1 "$(status CUSTOMER C002)" "DELETED"
core C05.2 "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "0"
core C05.3 "$(q "SELECT order_ref||'/'||COALESCE(placed_by,'NULL') FROM v_order WHERE order_ref='O-101'")" "O-101/NULL"
core C05.4 "$(q "SELECT r.res_name||'/'||c.email_addr FROM res r JOIN res_customer c USING(res_id) WHERE r.res_code='C002'")" \
           "Bob Jones/bob@example.com"
core C05.5 "$(aans 7)" "Bob Jones"
later M04 "tombstone: O-101 still points at C002 (parent_res is not cleared)" \
   "$(q "SELECT parent FROM v_res WHERE res_code='O-101'")" "CUSTOMER:C002"

core_section C06
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
core C06.1 "$(status CUSTOMER C003)" "LIVE"
core C06.2 "$(q "SELECT email FROM v_customer WHERE customer_ref='C003'")" "new@x.com"
later M02 "new resource continues the surrogate sequence (C003 = 8)" \
   "$(q "SELECT res_id FROM res WHERE res_code='C003'")" "8"

core_section C07
before="$(snap)"; before_arch="$(archive_state)"
feed d1_cust_win_day60.sql D1 '2026-04-03 08:00:00'
core C07.1 "$SKIPPED" "1"
core C07.2 "$(snap)" "$before"
core C07.3 "$(archive_state)" "$before_arch"
# D1's id, different content (two other customers): refused before any write.
cat > "$LOGDIR/reused_id.sql" <<'SQL'
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C009','Tam Per','t@x.com','2027-01-01','2027-01-01','UPSERT','INCREMENTAL'),
('C010','Tam Per','u@x.com','2027-01-01','2027-01-01','UPSERT','INCREMENTAL');
SQL
rc=0; BATCH_TS='2026-04-11 08:00:00' "$PROJ/scripts/load_feed.sh" "$LOGDIR/reused_id.sql" D1 \
  >"$LOGDIR/reused_id.log" 2>&1 || rc=$?
core C07.4 "$([ "$rc" -ne 0 ] && grep -q '^FATAL' "$LOGDIR/reused_id.log" && echo rejected || echo "accepted (exit $rc)")|$(snap)|$(archive_state)" \
           "rejected|$before|$before_arch"
q "DELETE FROM source_landing_stage;" >/dev/null

core_section C08
before_c001="$(q "SELECT srcd_ts FROM res WHERE res_id=1")/$(q "SELECT srcd_ts FROM res_customer WHERE res_id=1")"
feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'
core C08.1 "$(status CUSTOMER C003)" "DELETED"
core C08.2 "$(ans 1)" "C001"
core C08.3 "$(ans 2)" "C002,C003"
# The mart updates the email in place; the history is answered from the
# raw archive, which is the final answer (Q3 reads it).
core C08.4 "$(aans 3)" "alice@example.com>alice@newmail.com"
later M07 "NOCHANGE: C001 restated unchanged writes nothing" \
   "$(q "SELECT srcd_ts FROM res WHERE res_id=1")/$(q "SELECT srcd_ts FROM res_customer WHERE res_id=1")" "$before_c001"
later M07 "FULL reconciliation: already-deleted C002 is not restamped" \
   "$(q "SELECT srcd_ts FROM res WHERE res_code='C002'")" "2026-03-16 08:00:00"
later M07 "END STATE: same answer as the nine sibling models" \
   "$(q "SELECT group_concat(customer_ref||'('||email||')',' ') FROM (SELECT * FROM v_customer ORDER BY 1)")" \
   "C001(alice@newmail.com)"
later M07 "END STATE: products" \
   "$(q "SELECT group_concat(sku||'='||printf('%.2f',price),' ') FROM (SELECT * FROM v_product ORDER BY 1)")" \
   "SKU-1=8.99 SKU-2=19.50"
later M07 "END STATE: census" "$(census)" \
   "res=8 live=5 alias=8 grp=7 member=11 provider=3 sample=7 summary=7 weekly=7 grpwk=13"

core_section C09
before_r="$(snap)"
feed d5_cust_yearly_full.sql D5R '2027-01-05 08:00:00'
core C09.1 "$(snap)" "$before_r"

core_section C10
core C10.1 "$(hist_rows)" "$(aq 'SELECT SUM(row_count) FROM arch.loaded_files')"
core C10.2 "$(printf '%s ' "$(refused "UPDATE hist_customer SET full_name='x' WHERE seq_nbr=1;" "append-only")"
              for t in hist_product hist_order hist_order_line; do
                printf '%s ' "$(refused "UPDATE $t SET op=op;" "append-only")"; done)" \
           "refused refused refused refused "
core C10.3 "$(for t in hist_customer hist_product hist_order hist_order_line; do
                printf '%s ' "$(refused "DELETE FROM $t;" "append-only")"; done)" \
           "refused refused refused refused "
cat > "$LOGDIR/drift.sql" <<'SQL'
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C002',NULL,NULL,NULL,'2026-03-17','DELETE','INCREMENTAL');
SQL
out="$(BATCH_TS='2026-03-17 08:00:00' "$PROJ/scripts/load_feed.sh" "$LOGDIR/drift.sql" D3 2>&1)"; rc=$?
later M08 "a used file_id with different content is rejected" \
   "$([ "$rc" -ne 0 ] && echo rejected || echo accepted)" "rejected"
q "DELETE FROM source_landing_stage;" >/dev/null

core_section C11
before="$(snap)"; before_census="$(census)"
rm -f "$DB"
"$PROJ/scripts/rebuild.sh" >"$LOGDIR/rebuild1.log" 2>&1
core C11.1 "$(census)|$(snap)" "$before_census|$before"
rm -f "$DB"
make -s -C "$PROJ" rebuild >/dev/null 2>&1; rc=$?
later M08 "make rebuild exits 0" "$rc" "0"
later M08 "make rebuild: every surrogate (res_id, provider_id, res_grp_id), value and srcd_ts identical" "$(snap)" "$before"
later M08 "archive tables are exactly the shared wide layout" \
   "$(aq "SELECT group_concat(name,',') FROM (SELECT name FROM arch.sqlite_master WHERE type='table' ORDER BY name)")" \
   "hist_customer,hist_order,hist_order_line,hist_product,loaded_files"
later M08 "no archived table has a key/value (attribute_name) column" \
   "$(aq "SELECT COUNT(*) FROM arch.sqlite_master m, pragma_table_info(m.name, 'arch') c
          WHERE m.type='table' AND c.name='attribute_name'")" "0"

core_section C12
# The label is one row of the order_status code table, joined on read: one
# UPDATE relabels every order. Tried on a copy of the mart -- the main mart
# repeats it live, after its last rebuild, in M19.
cp "$DB" "$LOGDIR/rule.db"
"$SQLITE" "$LOGDIR/rule.db" "UPDATE order_status SET status_name='PLACED' WHERE status_code='P';"
core C12.1 "$(DB="$LOGDIR/rule.db" ans 9)" "O-100=PLACED,O-101=PLACED"

core_section C13
feed d7_repoint.sql D7 '2027-02-03 08:00:00' "$HERE/fixtures"
core C13.1 "$(ans 8)" "Alice Smith"
# The re-point updates parent_res in place; the earlier owner is answered
# from the raw archive (M07 shows the mart itself no longer knows it).
core C13.2 "$(aq "SELECT group_concat(DISTINCT customer_ref) FROM arch.hist_order
                  WHERE order_ref='O-101' AND customer_ref<>'C001'")" "C002"
later M04 "repoint: O-101's parent is now C001" \
   "$(q "SELECT parent FROM v_res WHERE res_code='O-101'")" "CUSTOMER:C001"
later M07 "repoint: IN PLACE -- the mart no longer knows C002 ever owned it" \
   "$(q "SELECT COUNT(*) FROM res WHERE res_code='O-101' AND parent_res=2")" "0"
later M07 "repoint: ...the archive does" \
   "$(aq "SELECT group_concat(customer_ref,'>') FROM (SELECT customer_ref FROM arch.hist_order
          WHERE order_ref='O-101' ORDER BY load_seq)")" "C002>C001"
later M04 "repoint: unchanged status, currency and placed_at wrote nothing" \
   "$(q "SELECT o.srcd_ts FROM res_order o JOIN res r USING(res_id) WHERE r.res_code='O-101'")" "2026-02-05 08:00:00"
later M03 "repoint: the restated amount is a new observation (2 samples)" "$(nsamp O-101 amount)" "2"
before="$(snap)"
feed d7_repoint.sql D7R '2027-02-15 08:00:00' "$HERE/fixtures"
later M07 "re-asserted repoint (same extract) writes nothing" "$(snap)" "$before"

core_section C14
core C14.1 "$(q "SELECT group_concat(customer_ref||'('||COALESCE(email,'null')||')',' ')
                 FROM (SELECT * FROM v_customer ORDER BY customer_ref)")" "C001(alice@newmail.com)"

banner "2: MODEL  (what the metrics mart shows on its own)"
FEED_SEC=""

own_section M01 "Manifest, stage and integrity after every delivery"
replay M01
own_section M02 "One RES table, deterministic surrogates, providers and aliases"
replay M02
own_section M03 "Metrics are samples, not columns"
replay M03
own_section M04 "Parents and code tables"
replay M04
own_section M05 "Groups: order lines and resource types"
replay M05
own_section M06 "Aggregates: daily summaries, weeks and group weeks"
replay M06
own_section M07 "Current state: a change is an update in place"
replay M07
own_section M08 "Raw layer: re-use rejected, make rebuild, the wide archive"
replay M08

own_section M09 "A stale FULL snapshot is not applied twice"
# CRM's last delivery (D5) was FULL and still sits in source_landing. An OMS
# delivery now creates a stub customer. If a later non-CRM delivery re-read
# the old CRM snapshot, the stub would look "absent from a FULL" and die.
# Wide rows restate the whole record: O-150 never has an amount, currency
# or placed_at (empty = NULL, no value), and the second delivery restates
# the customer it already had.
cat > "$LOGDIR/stub1.sql" <<'SQL'
INSERT INTO stg_order_l1(order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode) VALUES
('O-150','C888','P',NULL,NULL,NULL,'2027-01-10','UPSERT','INCREMENTAL');
SQL
cat > "$LOGDIR/stub2.sql" <<'SQL'
INSERT INTO stg_order_l1(order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode) VALUES
('O-150','C888','S',NULL,NULL,NULL,'2027-01-11','UPSERT','INCREMENTAL');
SQL
feed stub1.sql DS1 '2027-01-10 08:00:00' "$LOGDIR"
own "stub customer C888 created by the OMS delivery" "$(status CUSTOMER C888)" "LIVE"
feed stub2.sql DS2 '2027-01-11 08:00:00' "$LOGDIR"
own "the next OMS delivery leaves C888 alone: only arriving feeds are processed" \
   "$(status CUSTOMER C888)" "LIVE"
own "...and O-150 took its status change in place (P -> S)" \
   "$(q "SELECT status FROM v_order WHERE order_ref='O-150'")" "SHIPPED"

own_section M10 "Tiebreak fixture: same key, same extract_ts, file order decides"
feed d6_tiebreak_wide.sql D6 '2027-02-01 08:00:00' "$HERE/fixtures"
own "tiebreak: the LAST row in the file wins" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C004'")" "last@x.com"

own_section M11 "Closed code table: an unknown status fails the load"
before="$(snap)"
cat > "$LOGDIR/badstatus.sql" <<'SQL'
INSERT INTO stg_order_l1(order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode) VALUES
('O-999',NULL,'X',NULL,NULL,NULL,'2027-01-20','UPSERT','INCREMENTAL');
SQL
out="$(BATCH_TS='2027-02-02 08:00:00' "$PROJ/scripts/load_feed.sh" "$LOGDIR/badstatus.sql" DX 2>&1)"; rc=$?
own "unknown status code 'X' is REJECTED by the foreign key" \
   "$([ "$rc" -ne 0 ] && echo rejected || echo accepted)" "rejected"
own "  ...and the resource load rolled back as one step (no O-999)" "$(snap)" "$before"
own "  ...the failed delivery stays retryable (STARTED)" \
   "$(aq "SELECT status FROM arch.loaded_files WHERE file_id='DX'")" "STARTED"
own "  ...with its staged rows preserved as forensics" \
   "$(q 'SELECT COUNT(*) FROM stg_order_l1')" "1"
q "DELETE FROM stg_order_l1; DELETE FROM source_landing_stage;" >/dev/null   # clean up for the next block

own_section M12 "Price observation: a new SKU-2 price (wide d8)"
# The partial-delivery rule this block used to test (absent attributes
# mean "no change") is narrow by nature: it runs at level 2 below, with
# the unchanged d8_metric_obs.sql, in a scratch database.
feed d8_metric_obs_wide.sql D8 '2027-03-01 08:00:00' "$HERE/fixtures"

own_section M13 "Correction: same sample key, different value"
before_n="$(nsamp SKU-2 price)"
feed d8c_metric_correction.sql D8C '2027-03-04 08:00:00' "$HERE/fixtures"
own "correction: the 2027-03-01 sample is OVERWRITTEN (21.5 -> 20.5)" \
   "$(q "SELECT printf('%.2f',value) FROM v_metric_sample WHERE res_code='SKU-2' AND sample_utc_ts='2027-03-01 00:00:00'")" "20.50"
own "correction: one new sample only (the 03-03 observation)" "$(nsamp SKU-2 price)" "$((before_n+1))"
own "correction: the archive kept both values for that moment" \
   "$(aq "SELECT COUNT(DISTINCT price) FROM arch.hist_product
          WHERE sku='SKU-2' AND extract_dt='2027-03-01'")" "2"
own "AGGREGATES: the week of 2027-03-01 averages both samples (cnt 2, min 20.5, max 22.5)" \
   "$(q "SELECT printf('%.2f',value)||'/'||value_cnt||'/'||printf('%.2f',value_min)||'/'||printf('%.2f',value_max)
         FROM v_metric_weekly WHERE res_code='SKU-2' AND week_start='2027-03-01'")" "21.50/2/20.50/22.50"
own "AGGREGATES: the corrected daily summary was updated, not duplicated" \
   "$(q "SELECT COUNT(*)||'/'||printf('%.2f',MAX(s.value)) FROM metric_summary s JOIN res r USING(res_id)
         WHERE r.res_code='SKU-2' AND s.start_utc_ts='2027-03-01 00:00:00'")" "1/20.50"

own_section M14 "Lifecycle: restore, auto-created parent, membership tombstone"
feed d9_lifecycle.sql D9 '2027-04-01 08:00:00' "$HERE/fixtures"
own "restore: C002 delivered again is LIVE again, same res_id" \
   "$(q "SELECT status||'/'||res_id FROM v_res WHERE res_code='C002'")" "LIVE/2"
own "auto-create: unknown parent C777 became a stub customer (name = code)" \
   "$(q "SELECT res_name||'/'||status FROM v_res WHERE res_type='CUSTOMER' AND res_code='C777'")" "C777/LIVE"
own "auto-create: O-102 hangs off the stub" \
   "$(q "SELECT parent FROM v_res WHERE res_code='O-102'")" "CUSTOMER:C777"
own "open code table: GBP learned from the feed" \
   "$(q "SELECT COUNT(*) FROM currency WHERE currency_code='GBP'")" "1"
own "membership tombstone: O-100~SKU-1 removed, O-100~SKU-2 kept" \
   "$(q "SELECT group_concat(sku,',') FROM (SELECT sku FROM v_order_line WHERE order_ref='O-100' ORDER BY 1)")" "SKU-2"
own "membership tombstone: SKU-1's order-group weeks are gone, its own weeks are not" \
   "$(q "SELECT (SELECT COUNT(*) FROM grp_metric_weekly w JOIN res_grp g USING(res_grp_id)
                 WHERE w.res_id=5 AND g.group_path LIKE '/ORDER/%')||'/'||(SELECT COUNT(*) FROM metric_weekly WHERE res_id=5)")" "0/2"
own "TYPE GROUPS: a delete takes nothing out of a type group (SKU-3 still in /TYPE/PRODUCT)" \
   "$(q "SELECT COUNT(*) FROM res_resgrp x JOIN res_grp g USING(res_grp_id) JOIN res r USING(res_id)
         WHERE g.group_path='/TYPE/PRODUCT' AND r.res_code='SKU-3'")" "1"

own_section M15 "Membership FULL snapshot: an absent order line is removed"
cat > "$LOGDIR/lines_full.sql" <<'SQL'
INSERT INTO stg_order_line_l1(order_ref, sku, extract_dt, op, load_mode) VALUES
('O-100','SKU-2','2027-04-05','UPSERT','FULL');
SQL
feed lines_full.sql DL '2027-04-05 08:00:00' "$LOGDIR"
own "FULL absence: O-101~SKU-2 removed, O-100~SKU-2 kept" \
   "$(q "SELECT group_concat(order_ref||'~'||sku,',') FROM (SELECT * FROM v_order_line ORDER BY 1,2)")" "O-100~SKU-2"
own "FULL absence: the empty group /ORDER/O-101 is kept (groups are not deleted)" \
   "$(q "SELECT COUNT(*) FROM res_grp WHERE group_path='/ORDER/O-101'")" "1"

own_section M16 "RES_TYPE_REL: a parent of the wrong type fails the load"
before="$(snap)"
q "DELETE FROM res_type_rel;" >/dev/null
cat > "$LOGDIR/badrel.sql" <<'SQL'
INSERT INTO stg_order_l1(order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode) VALUES
('O-103','C001',NULL,NULL,NULL,NULL,'2027-04-02','UPSERT','INCREMENTAL');
SQL
out="$(BATCH_TS='2027-04-02 08:00:00' "$PROJ/scripts/load_feed.sh" "$LOGDIR/badrel.sql" DR 2>&1)"; rc=$?
own "pairing not listed in RES_TYPE_REL is REJECTED by the load guard" \
   "$([ "$rc" -ne 0 ] && echo rejected || echo accepted)" "rejected"
q "INSERT INTO res_type_rel VALUES('CUSTOMER','ORDER','P','2026-01-01 00:00:00'); DELETE FROM source_landing_stage;" >/dev/null
own "  ...and nothing was written" "$(snap)" "$before"

own_section M17 "Day table kept; calendar events removed"
own "no calendar-event table or view exists" \
   "$(q "SELECT COUNT(*) FROM sqlite_master WHERE instr(name,'calndr_event')>0 OR instr(name,'cal_evt')>0")" "0"
own "CALNDR: one row per day, 2026-01-01 to 2027-12-31" \
   "$(q "SELECT COUNT(*)||'|'||COUNT(DISTINCT calndr_date)||'|'||MIN(calndr_date)||'|'||MAX(calndr_date) FROM calndr")" \
   "730|730|2026-01-01|2027-12-31"

own_section M18 "Rebuild after every fixture"
before="$(snap)"; before_census="$(census)"
rm -f "$DB"
"$PROJ/scripts/rebuild.sh" >"$LOGDIR/rebuild2.log" 2>&1
own "rebuild: census identical" "$(census)" "$before_census"
own "rebuild: every surrogate, value and srcd_ts identical" "$(snap)" "$before"
own "rebuild: the two failed deliveries (DX, DR) were not replayed" \
   "$(q "SELECT COUNT(*) FROM res WHERE res_code IN ('O-999','O-103')")" "0"
own "rebuild: tiebreak survives replay (seq_nbr order restored)" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C004'")" "last@x.com"
own "rebuild: CALNDR reseeded, one row per day" \
   "$(q "SELECT COUNT(*) FROM calndr")" "730"

own_section M19 "Code table relabel: one row, every order, no reload"
q "UPDATE order_status SET status_name='PLACED' WHERE status_code='P';" >/dev/null
own "relabel: every pending order reads PLACED instantly" \
   "$(q "SELECT group_concat(DISTINCT status) FROM v_order WHERE order_ref IN ('O-100','O-101')")" "PLACED"

own_section M20 "A new metric is a row: no DDL, no loader change"
tables_before="$(q "SELECT COUNT(*)||'/'||SUM(length(sql)) FROM sqlite_master")"
q "INSERT INTO metric(metric_id,value_type,metric_code,metric_name,unit_of_measure,srcd_ts)
   VALUES(3,'GAUGE','weight_kg','Shipping weight','kg','2027-05-01 00:00:00');
   INSERT INTO meta_attribute_map(source_system,source_entity,source_attribute,target_kind,slot,metric_code)
   VALUES('PIM','PRODUCT','weight_kg','METRIC','value_num','weight_kg');" >/dev/null
cat > "$LOGDIR/weight.sql" <<'SQL'
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('PIM','PRODUCT','SKU-1','weight_kg',NULL,0.35,NULL,'2027-05-01','UPSERT','INCREMENTAL');
SQL
# weight_kg is a NEW attribute: the shared wide layout has no column for
# it, so this delivery is narrow by nature and runs at level 2 -- straight
# into the narrow stage, outside load control and the archive. It comes
# after the last "rebuild reproduces" assertion; the rebuild below only
# asserts that the seed is reset. (Under a wide raw layer a new metric
# from a source also needs a new wide column; see README.)
level2 "$LOGDIR/weight.sql" '2027-05-01 08:00:00' "$(( $(aq 'SELECT MAX(load_seq) FROM arch.loaded_files') + 1 ))"
own "[DW] integrity views empty" \
   "$(q 'SELECT (SELECT COUNT(*) FROM v_res_type_rel_violation)+(SELECT COUNT(*) FROM v_res_grp_path_violation)')" "0"
own "new metric: its first sample loaded and aggregated" \
   "$(q "SELECT printf('%.2f',value)||'/'||value_cnt FROM v_metric_weekly WHERE res_code='SKU-1' AND metric_code='weight_kg'")" "0.35/1"
own "new metric: the schema did not change" \
   "$(q "SELECT COUNT(*)||'/'||SUM(length(sql)) FROM sqlite_master")" "$tables_before"
"$PROJ/scripts/rebuild.sh" >"$LOGDIR/rebuild3.log" 2>&1
own "  ...and rebuild resets both: the schema seed is the source of truth" \
   "$(q "SELECT (SELECT DISTINCT status FROM v_order WHERE order_ref='O-100')||'/'||(SELECT COUNT(*) FROM metric)")" "PENDING/2"


own_section M21 "Weeks come from CALNDR"
own "weeks: every week start is a Monday in CALNDR" \
   "$(q "SELECT COUNT(*) FROM metric_weekly w LEFT JOIN calndr c ON c.calndr_date = w.start_lcl_dt
         WHERE c.day_of_week IS NOT 1")" "0"
cat > "$LOGDIR/outside.sql" <<'SQL'
INSERT INTO stg_product_l1(sku, prod_name, price, currency, extract_dt, op, load_mode) VALUES
('SKU-1','Widget',7.99,'USD','2028-01-10','UPSERT','INCREMENTAL');
SQL
samples_before="$(q "SELECT COUNT(*) FROM metric_sample")"
out="$(BATCH_TS='2028-01-10 08:00:00' "$PROJ/scripts/load_feed.sh" "$LOGDIR/outside.sql" DC 2>&1)"; rc=$?
q "DELETE FROM source_landing_stage;" >/dev/null
own "weeks: a sample dated outside CALNDR fails the load" \
   "$([ "$rc" -ne 0 ] && echo rejected || echo accepted)" "rejected"
own "  ...and no sample was written" "$(q "SELECT COUNT(*) FROM metric_sample")" "$samples_before"
q "UPDATE calndr SET day_of_week = 1 WHERE calndr_date = '2026-02-05';" >/dev/null
BATCH_TS='2028-02-01 08:00:00' "$PROJ/scripts/refresh_aggregates.sh" >/dev/null 2>&1
own "weeks: the week start comes from CALNDR, not from a date function" \
   "$(q "SELECT n_wk || '/' || (n_wk = n_day AND n_day > 0) FROM
         (SELECT (SELECT COUNT(*) FROM metric_weekly WHERE start_lcl_dt = '2026-02-05') AS n_wk,
                 (SELECT COUNT(*) FROM metric_summary WHERE date(start_utc_ts) = '2026-02-05') AS n_day)" | cut -d/ -f2)" "1"
own_section M22 "Unpivoted D0..D5 build the same mart as the old narrow files"
# Two scratch database pairs, created after every rebuild assertion above
# and never read by one. The wide files go through load_feed.sh; the old
# narrow deliveries (tests/fixtures/narrow) go straight into the narrow
# stage and through apply_delivery.sh (level 2) with the same BATCH_TS and
# BATCH_NO. Stage row counts differ (D4: 8 unpivoted vs 5 narrow); the
# loaded result may not.
SAVE_DB="$DB"; SAVE_ARCHIVE_DB="$ARCHIVE_DB"
SEQ="d0_baseline B0 1 2026-02-05 08:00:00
d1_cust_win_day60 D1 2 2026-03-02 08:00:00
d2_prod_full_v2 D2 3 2026-03-02 09:00:00
d3_cust_tombstone D3 4 2026-03-16 08:00:00
d4_cust_recency D4 5 2026-04-02 08:00:00
d5_cust_yearly_full D5 6 2026-12-31 08:00:00"
export DB="$LOGDIR/wide.db" ARCHIVE_DB="$LOGDIR/wide_archive.db"
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null 2>&1
while read -r n id seq d t; do
  BATCH_TS="$d $t" "$PROJ/scripts/load_feed.sh" "$PROJ/source/$n.sql" "$id" >/dev/null 2>&1
done <<< "$SEQ"
wide_snap="$(snap)"; wide_census="$(census)"
export DB="$LOGDIR/narrow_ref.db" ARCHIVE_DB="$LOGDIR/narrow_ref_archive.db"
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null 2>&1
while read -r n id seq d t; do
  level2 "$HERE/fixtures/narrow/$n.sql" "$d $t" "$seq"
done <<< "$SEQ"
own "same census from the old narrow files" "$(census)" "$wide_census"
own "same mart (every surrogate, value and srcd_ts) from the old narrow files" "$(snap)" "$wide_snap"

own_section M23 "Level 2: partial narrow delivery, one attribute of one product"
# d8_metric_obs.sql (unchanged) carries only SKU-2's price. A wide row
# always restates the whole record, so this rule -- absent attributes mean
# "no change" -- can only be exercised narrow: straight into the narrow
# stage, on top of the wide D0..D5 loaded above.
export DB="$LOGDIR/wide.db" ARCHIVE_DB="$LOGDIR/wide_archive.db"
level2 "$HERE/fixtures/d8_metric_obs.sql" '2027-03-01 08:00:00' 7
own "partial: SKU-2 price is the new observation" "$(price SKU-2)" "21.50"
own "partial: absent attributes mean no change (name and currency kept)" \
   "$(q "SELECT product_name||'/'||currency FROM v_product WHERE sku='SKU-2'")" "Gadget/USD"
own "partial: INCREMENTAL absence deleted no product" \
   "$(q "SELECT COUNT(*) FROM v_product")" "2"
export DB="$SAVE_DB" ARCHIVE_DB="$SAVE_ARCHIVE_DB"

own_section M24 "Level 1: the wide -> narrow transform (stage_narrow.sh)"
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

own_section M25 "Level 2: the narrow loaders, fed narrow rows directly"
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


own_section M26 "Load control: a file_id names CONTENT (same block in all ten suites)"
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
