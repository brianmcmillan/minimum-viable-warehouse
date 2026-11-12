#!/usr/bin/env bash
# =====================================================================
# Metrics-mart test suite -- the shared delivery scenarios against a 3NF
# resource/metric model, plus the behaviours that are this model's own:
# current-state resources updated in place, deletes as res_status,
# identity through RES_ALIAS, numeric attributes as METRIC_SAMPLE rows,
# derived summaries and weekly aggregates, closed code tables, and an
# archive-backed rebuild that reproduces every surrogate and srcd_ts.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
# No `set -e`: every assertion must run so one failure doesn't hide the rest.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/metrics_test).db}"
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

# Row counts of every table the loaders write.
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
    UNION ALL SELECT 11,'event',  COUNT(*) FROM calndr_event
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
  UNION ALL SELECT 'egrp', event_grp_id, event_grp_code||'|'||COALESCE(event_grp_name,''), srcd_ts FROM cal_evt_grp
  UNION ALL SELECT 'evt', event_id, event_code||'|'||res_grp_id||'|'||COALESCE(event_grp_id,'')||'|'||cal_evt_type||'|'||inheritance_flag||'|'||
                   COALESCE(event_start_dt,'')||'|'||event_start_tm||'|'||COALESCE(duration,'')||'|'||
                   COALESCE(active_start_dt,'')||'|'||COALESCE(active_end_dt,'')||'|'||COALESCE(days_of_week,'')||'|'||
                   COALESCE(month_end_flag,'')||'|'||COALESCE(months,'')||'|'||COALESCE(year,''), srcd_ts FROM calndr_event
  ORDER BY 1,2,3,4;"; }

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
  [ "$SKIPPED" -eq 0 ] && ck "[$file_id] manifest: COMPLETE after all loaders" \
     "$(aq "SELECT status FROM arch.loaded_files WHERE file_id='$file_id'")" "COMPLETE"
  ck "[$file_id] stage blank after delivery" \
     "$(q 'SELECT COUNT(*) FROM source_landing_stage')" "0"
  ck "[$file_id] integrity views empty" \
     "$(q 'SELECT (SELECT COUNT(*) FROM v_res_type_rel_violation)+(SELECT COUNT(*) FROM v_res_grp_path_violation)')" "0"; }

status(){ q "SELECT status FROM v_res WHERE res_type='$1' AND res_code='$2'"; }
price(){  q "SELECT printf('%.2f', price) FROM v_product WHERE sku='$1'"; }
nsamp(){  q "SELECT COUNT(*) FROM v_metric_sample WHERE res_code='$1' AND metric_code='$2'"; }

echo "== Fresh db + archive =="; rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null

echo; echo "== D0: FULL baseline =="
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
ck "baseline: 2 customers, 3 products, 2 orders in the perspectives" \
   "$(q "SELECT (SELECT COUNT(*) FROM v_customer)||'/'||(SELECT COUNT(*) FROM v_product)||'/'||(SELECT COUNT(*) FROM v_order)")" "2/3/2"
ck "baseline: one RES table holds all three types" \
   "$(q "SELECT group_concat(res_type||'='||n,',') FROM (SELECT res_type, COUNT(*) n FROM res GROUP BY res_type ORDER BY res_type)")" \
   "CUSTOMER=2,ORDER=2,PRODUCT=3"
ck "baseline: deterministic res_id in (res_type, res_code) order" \
   "$(q "SELECT group_concat(res_code||'='||res_id,',') FROM (SELECT * FROM res ORDER BY res_id)")" \
   "C001=1,C002=2,O-100=3,O-101=4,SKU-1=5,SKU-2=6,SKU-3=7"
ck "baseline: providers created from source_system, in name order" \
   "$(q "SELECT group_concat(provider_name||'='||provider_id,',') FROM (SELECT * FROM provider ORDER BY provider_id)")" \
   "CRM=1,OMS=2,PIM=3"
ck "baseline: every resource has an alias that resolves to it" \
   "$(q "SELECT COUNT(*) FROM res r JOIN res_alias a ON a.res_type=r.res_type AND a.res_alias=r.res_code AND a.res_id=r.res_id")" "7"
ck "baseline: C001 email v1" "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@example.com"
ck "baseline: batch_no on the staging rows is the archive's load_seq" \
   "$(aq "SELECT (SELECT DISTINCT batch_no FROM res_stg)||'/'||(SELECT load_seq FROM arch.loaded_files WHERE file_id='B0')")" "1/1"
ck "METRIC: numeric attributes are samples, not columns (3 prices + 2 amounts)" \
   "$(q "SELECT group_concat(metric_code||'='||n,',') FROM (SELECT metric_code, COUNT(*) n FROM v_metric_sample GROUP BY metric_code ORDER BY metric_code)")" \
   "amount=2,price=3"
ck "METRIC: no price or amount column exists on any resource table" \
   "$(q "SELECT COUNT(*) FROM pragma_table_info('res') WHERE name IN ('price','amount')")" "0"
ck "METRIC: METRIC_STG2 resolved every staged name to a surrogate" \
   "$(q "SELECT COUNT(*)||'/'||SUM(res_id IS NOT NULL AND metric_id IS NOT NULL AND provider_id IS NOT NULL) FROM metric_stg2")" "5/5"
ck "METRIC: v_product.price reads the newest sample" "$(price SKU-1)" "9.99"
ck "METRIC: sample value is typed REAL" \
   "$(q "SELECT DISTINCT typeof(value) FROM metric_sample")" "real"
ck "PARENT: O-100's parent resource is customer C001" \
   "$(q "SELECT parent FROM v_res WHERE res_code='O-100'")" "CUSTOMER:C001"
ck "CODE TABLE: raw 'P' stored, PENDING decoded on read by a join" \
   "$(q "SELECT (SELECT status_code FROM res_order o JOIN res r USING(res_id) WHERE r.res_code='O-100')||'/'||
                (SELECT status FROM v_order WHERE order_ref='O-100')")" "P/PENDING"
ck "CODE TABLE: open currency domain learned USD and EUR from the feed" \
   "$(q "SELECT group_concat(currency_code,',') FROM (SELECT currency_code FROM currency ORDER BY 1)")" "EUR,USD"
ck "GROUPS: order lines became 1 root + 2 order groups, 3 memberships" \
   "$(q "SELECT (SELECT COUNT(*) FROM res_grp WHERE group_path='/ORDER' OR group_path LIKE '/ORDER/%')||'/'||
                (SELECT COUNT(*) FROM res_resgrp x JOIN res_grp g USING(res_grp_id) WHERE g.group_path LIKE '/ORDER/%')")" "3/3"
ck "TYPE GROUPS: /TYPE plus one group per resource type" \
   "$(q "SELECT group_concat(group_path,',') FROM (SELECT group_path FROM res_grp WHERE group_path='/TYPE' OR group_path LIKE '/TYPE/%' ORDER BY 1)")" \
   "/TYPE,/TYPE/CUSTOMER,/TYPE/ORDER,/TYPE/PRODUCT"
ck "GROUPS: res_grp_id in (level, path) order, parents before children" \
   "$(q "SELECT group_concat(group_path||'='||res_grp_id,',') FROM (SELECT * FROM res_grp ORDER BY res_grp_id)")" \
   "/ORDER=1,/TYPE=2,/ORDER/O-100=3,/ORDER/O-101=4,/TYPE/CUSTOMER=5,/TYPE/ORDER=6,/TYPE/PRODUCT=7"
ck "TYPE GROUPS: every resource is a member of its type's group" \
   "$(q "SELECT COUNT(*) FROM res r JOIN res_grp g ON g.group_path='/TYPE/'||r.res_type
         JOIN res_resgrp x ON x.res_grp_id=g.res_grp_id AND x.res_id=r.res_id")" "7"
ck "GROUPS: parent, level and path agree (/ORDER/O-100 is level 2 under /ORDER)" \
   "$(q "SELECT g.group_level||'/'||p.group_path FROM res_grp g JOIN res_grp p ON p.res_grp_id=g.parent_res_grp WHERE g.group_path='/ORDER/O-100'")" "2//ORDER"
ck "GROUPS: v_order_line reads memberships back as order lines" \
   "$(q "SELECT group_concat(order_ref||'~'||sku,',') FROM (SELECT * FROM v_order_line ORDER BY 1,2)")" \
   "O-100~SKU-1,O-100~SKU-2,O-101~SKU-2"
ck "AGGREGATES: one daily summary and one week per sample" \
   "$(q "SELECT (SELECT COUNT(*) FROM metric_summary)||'/'||(SELECT COUNT(*) FROM metric_weekly)")" "5/5"
ck "AGGREGATES: weeks start on Monday (2026-02-05 is in the week of 02-02)" \
   "$(q "SELECT DISTINCT start_lcl_dt FROM metric_weekly")" "2026-02-02"
ck "AGGREGATES: O-100's group week at list price equals its recorded amount" \
   "$(q "SELECT printf('%.2f',value_sum)||'/'||(SELECT printf('%.2f',amount) FROM v_order WHERE order_ref='O-100')
         FROM v_group_weekly WHERE group_path='/ORDER/O-100' AND metric_code='price'")" "29.49/29.49"

echo; echo "== D1: CRM INCREMENTAL 14-day window (C001 email changes; C002 absent) =="
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
ck "stale-window trap: absent C002 is NOT deleted" "$(status CUSTOMER C002)" "LIVE"
ck "C001 email updated" "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@newmail.com"
ck "CURRENT STATE: the change is an UPDATE in place (still 1 row for C001)" \
   "$(q "SELECT COUNT(*) FROM res_customer WHERE res_id=1")" "1"
ck "CURRENT STATE: the old email is gone from the mart, kept by the archive" \
   "$(aq "SELECT (SELECT COUNT(*) FROM res_customer WHERE email_addr='alice@example.com')||'/'||
                 (SELECT COUNT(DISTINCT value_str) FROM arch.source_landing_history
                  WHERE business_key='C001' AND attribute_name='email_addr')")" "0/2"
ck "CHANGED ROWS ONLY: res_customer restamped, RES row for C001 untouched" \
   "$(q "SELECT (SELECT srcd_ts FROM res_customer WHERE res_id=1)||'/'||(SELECT srcd_ts FROM res WHERE res_id=1)")" \
   "2026-03-02 08:00:00/2026-02-05 08:00:00"
ck "CURRENT FEEDS ONLY: the CRM delivery did not touch products or samples" \
   "$(q "SELECT (SELECT COUNT(*) FROM metric_sample)||'/'||(SELECT MAX(srcd_ts) FROM res WHERE res_type='PRODUCT')")" \
   "5/2026-02-05 08:00:00"

echo; echo "== D2: PIM FULL snapshot (SKU-1 repriced; SKU-3 absent) =="
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
ck "FULL absence: SKU-3 deleted (res_status = 0)" "$(status PRODUCT SKU-3)" "DELETED"
ck "FULL absence: router staged it as load_oper = 'D'" \
   "$(q "SELECT load_oper||'/'||res_status FROM res_stg WHERE res_code='SKU-3'")" "D/0"
ck "no ghost row: deleted SKU-3 is out of v_product" \
   "$(q "SELECT COUNT(*) FROM v_product WHERE sku='SKU-3'")" "0"
ck "SKU-3 keeps its samples: measurement history outlives the resource" "$(nsamp SKU-3 price)" "1"
ck "SKU-1 current price is the newest sample" "$(price SKU-1)" "8.99"
ck "SKU-1 price history is two samples" \
   "$(q "SELECT group_concat(printf('%.2f',value),'>') FROM (SELECT value FROM v_metric_sample WHERE res_code='SKU-1' ORDER BY sample_utc_ts)")" "9.99>8.99"
ck "OBSERVATION: unchanged SKU-2 price seen again is a NEW sample" "$(nsamp SKU-2 price)" "2"
ck "...but its unchanged name and currency wrote nothing" \
   "$(q "SELECT (SELECT srcd_ts FROM res WHERE res_code='SKU-2')||'/'||(SELECT p.srcd_ts FROM res_product p JOIN res r USING(res_id) WHERE r.res_code='SKU-2')")" \
   "2026-02-05 08:00:00/2026-02-05 08:00:00"
ck "AGGREGATES: SKU-1 now has two weeks" \
   "$(q "SELECT group_concat(week_start||'='||printf('%.2f',value),',') FROM (SELECT * FROM v_metric_weekly WHERE res_code='SKU-1' ORDER BY week_start)")" \
   "2026-02-02=9.99,2026-03-02=8.99"
ck "AGGREGATES: untouched weeks keep their srcd_ts" \
   "$(q "SELECT COUNT(DISTINCT srcd_ts) FROM metric_weekly WHERE start_lcl_dt='2026-02-02'")" "1"
ck "AGGREGATES: O-100's group week reprices to 28.49 (amount stays 29.49)" \
   "$(q "SELECT printf('%.2f',value_sum) FROM v_group_weekly WHERE group_path='/ORDER/O-100' AND metric_code='price' AND week_start='2026-03-02'")" "28.49"

echo; echo "== D3: CRM INCREMENTAL with explicit tombstone for C002 =="
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
ck "tombstone: C002 deleted" "$(status CUSTOMER C002)" "DELETED"
ck "tombstone: the row is kept with its last-known name" \
   "$(q "SELECT res_name FROM res WHERE res_code='C002'")" "Bob Jones"
ck "tombstone: O-101 survives, placed_by is NULL (owner not live)" \
   "$(q "SELECT order_ref||'/'||COALESCE(placed_by,'NULL') FROM v_order WHERE order_ref='O-101'")" "O-101/NULL"
ck "tombstone: O-101 still points at C002 (parent_res is not cleared)" \
   "$(q "SELECT parent FROM v_res WHERE res_code='O-101'")" "CUSTOMER:C002"

echo; echo "== D4: CRM INCREMENTAL adds C003 (email delivered twice) =="
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
ck "recency dedup: newest extract wins, not MAX(value)" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C003'")" "new@x.com"
ck "new resource continues the surrogate sequence (C003 = 8)" \
   "$(q "SELECT res_id FROM res WHERE res_code='C003'")" "8"

echo; echo "== Re-send D1 under the same file_id =="
before="$(snap)"
feed d1_cust_win_day60.sql D1 '2026-04-03 08:00:00'
ck "load control: duplicate delivery skipped" "$SKIPPED" "1"
ck "load control: the mart is unchanged" "$(snap)" "$before"

echo; echo "== D5: CRM yearly FULL reconciliation (only C001 remains) =="
before_c001="$(q "SELECT srcd_ts FROM res WHERE res_id=1")/$(q "SELECT srcd_ts FROM res_customer WHERE res_id=1")"
feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'
ck "FULL reconciliation: C003 deleted by absence" "$(status CUSTOMER C003)" "DELETED"
ck "NOCHANGE: C001 restated unchanged writes nothing" \
   "$(q "SELECT srcd_ts FROM res WHERE res_id=1")/$(q "SELECT srcd_ts FROM res_customer WHERE res_id=1")" "$before_c001"
ck "FULL reconciliation: already-deleted C002 is not restamped" \
   "$(q "SELECT srcd_ts FROM res WHERE res_code='C002'")" "2026-03-16 08:00:00"
ck "END STATE: same answer as the nine sibling models" \
   "$(q "SELECT group_concat(customer_ref||'('||email||')',' ') FROM (SELECT * FROM v_customer ORDER BY 1)")" \
   "C001(alice@newmail.com)"
ck "END STATE: products" \
   "$(q "SELECT group_concat(sku||'='||printf('%.2f',price),' ') FROM (SELECT * FROM v_product ORDER BY 1)")" \
   "SKU-1=8.99 SKU-2=19.50"
ck "END STATE: census" "$(census)" \
   "res=8 live=5 alias=8 grp=7 member=11 provider=3 sample=7 summary=7 weekly=7 grpwk=13 event=0"

echo; echo "== Raw layer: append-only, no unlock path =="
ck_abort "archive rejects UPDATE" \
  "UPDATE source_landing_history SET value_str='x' WHERE seq_nbr=1;" "append-only"
ck_abort "archive rejects DELETE" \
  "DELETE FROM source_landing_history;" "append-only"
cat > "$LOGDIR/drift.sql" <<'SQL'
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('CRM','CUSTOMER','C002','_tombstone',NULL,NULL,NULL,'2026-03-17','DELETE','INCREMENTAL');
SQL
out="$(BATCH_TS='2026-03-17 08:00:00' "$PROJ/scripts/load_feed.sh" "$LOGDIR/drift.sql" D3 2>&1)"; rc=$?
ck "a used file_id with different content is rejected" \
   "$([ "$rc" -ne 0 ] && echo rejected || echo accepted)" "rejected"
q "DELETE FROM source_landing_stage;" >/dev/null

echo; echo "== Rebuild: the mart is disposable =="
before="$(snap)"; before_census="$(census)"
rm -f "$DB"
"$PROJ/scripts/rebuild.sh" >"$LOGDIR/rebuild1.log" 2>&1
ck "rebuild: census identical" "$(census)" "$before_census"
ck "rebuild: every surrogate, value and srcd_ts identical" "$(snap)" "$before"

echo; echo "== A stale FULL snapshot is not applied twice =="
# CRM's last delivery (D5) was FULL and still sits in source_landing. An OMS
# delivery now creates a stub customer. If a later non-CRM delivery re-read
# the old CRM snapshot, the stub would look "absent from a FULL" and die.
cat > "$LOGDIR/stub1.sql" <<'SQL'
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('OMS','ORDER','O-150','order_ref','O-150',NULL,NULL,'2027-01-10','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-150','customer_ref','C888',NULL,NULL,'2027-01-10','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-150','status','P',NULL,NULL,'2027-01-10','UPSERT','INCREMENTAL');
SQL
cat > "$LOGDIR/stub2.sql" <<'SQL'
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('OMS','ORDER','O-150','order_ref','O-150',NULL,NULL,'2027-01-11','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-150','status','S',NULL,NULL,'2027-01-11','UPSERT','INCREMENTAL');
SQL
feed stub1.sql DS1 '2027-01-10 08:00:00' "$LOGDIR"
ck "stub customer C888 created by the OMS delivery" "$(status CUSTOMER C888)" "LIVE"
feed stub2.sql DS2 '2027-01-11 08:00:00' "$LOGDIR"
ck "the next OMS delivery leaves C888 alone: only arriving feeds are processed" \
   "$(status CUSTOMER C888)" "LIVE"
ck "...and O-150 took its status change in place (P -> S)" \
   "$(q "SELECT status FROM v_order WHERE order_ref='O-150'")" "SHIPPED"

echo; echo "== Tiebreak fixture: same key, same extract_ts, file order decides =="
feed d6_tiebreak.sql D6 '2027-02-01 08:00:00' "$HERE/fixtures"
ck "tiebreak: the LAST row in the file wins" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C004'")" "last@x.com"

echo; echo "== Closed code table: an unknown status fails the load =="
before="$(snap)"
cat > "$LOGDIR/badstatus.sql" <<'SQL'
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('OMS','ORDER','O-999','order_ref','O-999',NULL,NULL,'2027-01-20','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-999','status','X',NULL,NULL,'2027-01-20','UPSERT','INCREMENTAL');
SQL
out="$(BATCH_TS='2027-02-02 08:00:00' "$PROJ/scripts/load_feed.sh" "$LOGDIR/badstatus.sql" DX 2>&1)"; rc=$?
ck "unknown status code 'X' is REJECTED by the foreign key" \
   "$([ "$rc" -ne 0 ] && echo rejected || echo accepted)" "rejected"
ck "  ...and the resource load rolled back as one step (no O-999)" "$(snap)" "$before"
ck "  ...the failed delivery stays retryable (STARTED)" \
   "$(aq "SELECT status FROM arch.loaded_files WHERE file_id='DX'")" "STARTED"
ck "  ...with its staged rows preserved as forensics" \
   "$(q 'SELECT COUNT(*) FROM source_landing_stage')" "2"
q "DELETE FROM source_landing_stage;" >/dev/null   # clean up for the next block

echo; echo "== Re-point: OMS moves O-101 from C002 to C001 =="
feed d7_repoint.sql D7 '2027-02-03 08:00:00' "$HERE/fixtures"
ck "repoint: O-101's parent is now C001" \
   "$(q "SELECT parent FROM v_res WHERE res_code='O-101'")" "CUSTOMER:C001"
ck "repoint: placed_by resolves to Alice Smith" \
   "$(q "SELECT placed_by FROM v_order WHERE order_ref='O-101'")" "Alice Smith"
ck "repoint: IN PLACE -- the mart no longer knows C002 ever owned it" \
   "$(q "SELECT COUNT(*) FROM res WHERE res_code='O-101' AND parent_res=2")" "0"
ck "repoint: ...the archive does" \
   "$(aq "SELECT group_concat(value_str,'>') FROM (SELECT value_str FROM arch.source_landing_history
          WHERE business_key='O-101' AND attribute_name='customer_ref' ORDER BY load_seq)")" "C002>C001"
ck "repoint: unchanged status, currency and placed_at wrote nothing" \
   "$(q "SELECT o.srcd_ts FROM res_order o JOIN res r USING(res_id) WHERE r.res_code='O-101'")" "2026-02-05 08:00:00"
ck "repoint: the restated amount is a new observation (2 samples)" "$(nsamp O-101 amount)" "2"
before="$(snap)"
feed d7_repoint.sql D7R '2027-02-15 08:00:00' "$HERE/fixtures"
ck "re-asserted repoint (same extract) writes nothing" "$(snap)" "$before"

echo; echo "== Partial narrow delivery: one attribute of one product =="
feed d8_metric_obs.sql D8 '2027-03-01 08:00:00' "$HERE/fixtures"
ck "partial: SKU-2 price is the new observation" "$(price SKU-2)" "21.50"
ck "partial: absent attributes mean no change (name and currency kept)" \
   "$(q "SELECT product_name||'/'||currency FROM v_product WHERE sku='SKU-2'")" "Gadget/USD"
ck "partial: INCREMENTAL absence deleted no product" \
   "$(q "SELECT COUNT(*) FROM v_product")" "2"

echo; echo "== Correction: same sample key, different value =="
before_n="$(nsamp SKU-2 price)"
feed d8c_metric_correction.sql D8C '2027-03-04 08:00:00' "$HERE/fixtures"
ck "correction: the 2027-03-01 sample is OVERWRITTEN (21.5 -> 20.5)" \
   "$(q "SELECT printf('%.2f',value) FROM v_metric_sample WHERE res_code='SKU-2' AND sample_utc_ts='2027-03-01 00:00:00'")" "20.50"
ck "correction: one new sample only (the 03-03 observation)" "$(nsamp SKU-2 price)" "$((before_n+1))"
ck "correction: the archive kept both values for that moment" \
   "$(aq "SELECT COUNT(DISTINCT value_num) FROM arch.source_landing_history
          WHERE business_key='SKU-2' AND attribute_name='price' AND extract_ts='2027-03-01'")" "2"
ck "AGGREGATES: the week of 2027-03-01 averages both samples (cnt 2, min 20.5, max 22.5)" \
   "$(q "SELECT printf('%.2f',value)||'/'||value_cnt||'/'||printf('%.2f',value_min)||'/'||printf('%.2f',value_max)
         FROM v_metric_weekly WHERE res_code='SKU-2' AND week_start='2027-03-01'")" "21.50/2/20.50/22.50"
ck "AGGREGATES: the corrected daily summary was updated, not duplicated" \
   "$(q "SELECT COUNT(*)||'/'||printf('%.2f',MAX(s.value)) FROM metric_summary s JOIN res r USING(res_id)
         WHERE r.res_code='SKU-2' AND s.start_utc_ts='2027-03-01 00:00:00'")" "1/20.50"

echo; echo "== Lifecycle: restore, auto-created parent, membership tombstone =="
feed d9_lifecycle.sql D9 '2027-04-01 08:00:00' "$HERE/fixtures"
ck "restore: C002 delivered again is LIVE again, same res_id" \
   "$(q "SELECT status||'/'||res_id FROM v_res WHERE res_code='C002'")" "LIVE/2"
ck "auto-create: unknown parent C777 became a stub customer (name = code)" \
   "$(q "SELECT res_name||'/'||status FROM v_res WHERE res_type='CUSTOMER' AND res_code='C777'")" "C777/LIVE"
ck "auto-create: O-102 hangs off the stub" \
   "$(q "SELECT parent FROM v_res WHERE res_code='O-102'")" "CUSTOMER:C777"
ck "open code table: GBP learned from the feed" \
   "$(q "SELECT COUNT(*) FROM currency WHERE currency_code='GBP'")" "1"
ck "membership tombstone: O-100~SKU-1 removed, O-100~SKU-2 kept" \
   "$(q "SELECT group_concat(sku,',') FROM (SELECT sku FROM v_order_line WHERE order_ref='O-100' ORDER BY 1)")" "SKU-2"
ck "membership tombstone: SKU-1's order-group weeks are gone, its own weeks are not" \
   "$(q "SELECT (SELECT COUNT(*) FROM grp_metric_weekly w JOIN res_grp g USING(res_grp_id)
                 WHERE w.res_id=5 AND g.group_path LIKE '/ORDER/%')||'/'||(SELECT COUNT(*) FROM metric_weekly WHERE res_id=5)")" "0/2"
ck "TYPE GROUPS: a delete takes nothing out of a type group (SKU-3 still in /TYPE/PRODUCT)" \
   "$(q "SELECT COUNT(*) FROM res_resgrp x JOIN res_grp g USING(res_grp_id) JOIN res r USING(res_id)
         WHERE g.group_path='/TYPE/PRODUCT' AND r.res_code='SKU-3'")" "1"

echo; echo "== Membership FULL snapshot: an absent order line is removed =="
cat > "$LOGDIR/lines_full.sql" <<'SQL'
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('OMS','ORDER_LINE','O-100~SKU-2','order_ref','O-100',NULL,NULL,'2027-04-05','UPSERT','FULL'),
('OMS','ORDER_LINE','O-100~SKU-2','sku','SKU-2',NULL,NULL,'2027-04-05','UPSERT','FULL');
SQL
feed lines_full.sql DL '2027-04-05 08:00:00' "$LOGDIR"
ck "FULL absence: O-101~SKU-2 removed, O-100~SKU-2 kept" \
   "$(q "SELECT group_concat(order_ref||'~'||sku,',') FROM (SELECT * FROM v_order_line ORDER BY 1,2)")" "O-100~SKU-2"
ck "FULL absence: the empty group /ORDER/O-101 is kept (groups are not deleted)" \
   "$(q "SELECT COUNT(*) FROM res_grp WHERE group_path='/ORDER/O-101'")" "1"

echo; echo "== RES_TYPE_REL: a parent of the wrong type fails the load =="
before="$(snap)"
q "DELETE FROM res_type_rel;" >/dev/null
cat > "$LOGDIR/badrel.sql" <<'SQL'
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('OMS','ORDER','O-103','order_ref','O-103',NULL,NULL,'2027-04-02','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-103','customer_ref','C001',NULL,NULL,'2027-04-02','UPSERT','INCREMENTAL');
SQL
out="$(BATCH_TS='2027-04-02 08:00:00' "$PROJ/scripts/load_feed.sh" "$LOGDIR/badrel.sql" DR 2>&1)"; rc=$?
ck "pairing not listed in RES_TYPE_REL is REJECTED by the load guard" \
   "$([ "$rc" -ne 0 ] && echo rejected || echo accepted)" "rejected"
q "INSERT INTO res_type_rel VALUES('CUSTOMER','ORDER','P','2026-01-01 00:00:00'); DELETE FROM source_landing_stage;" >/dev/null
ck "  ...and nothing was written" "$(snap)" "$before"

echo; echo "== Calendar C1: one event at each level, all tied to RES_GRP =="
feed c1_calendar.sql C1 '2027-01-04 08:00:00' "$PROJ/source_ext"
occ(){ q "SELECT group_concat(occur_dt,',') FROM (SELECT occur_dt FROM v_calndr_occurrence WHERE event_code='$1' ORDER BY 1)"; }
reach(){ q "SELECT group_concat(res_code,',') FROM (SELECT DISTINCT res_code FROM v_res_calendar WHERE event_code='$1' ORDER BY 1)"; }
ck "five events, event_id in event_code order" \
   "$(q "SELECT group_concat(event_code||'='||event_id,',') FROM (SELECT * FROM calndr_event ORDER BY event_id)")" \
   "C001-REVIEW=1,NEWYEAR=2,ORDER-FREEZE=3,PIM-MAINT=4,SPRING-SALE=5"
ck "EVENT GROUPS: three created from the feed, ids in code order, name = code" \
   "$(q "SELECT group_concat(event_grp_code||'='||event_grp_id||'/'||event_grp_name,',') FROM (SELECT * FROM cal_evt_grp ORDER BY event_grp_id)")" \
   "HOLIDAYS-2027=1/HOLIDAYS-2027,OPS-2027=2/OPS-2027,PROMOS-2026=3/PROMOS-2026"
ck "EVENT GROUPS: each event is in its group; C001-REVIEW is in none" \
   "$(q "SELECT group_concat(event_code||'='||COALESCE(event_grp_code,'-'),',') FROM (SELECT * FROM v_calndr_event ORDER BY event_code)")" \
   "C001-REVIEW=-,NEWYEAR=HOLIDAYS-2027,ORDER-FREEZE=OPS-2027,PIM-MAINT=OPS-2027,SPRING-SALE=PROMOS-2026"
ck "EVENT GROUPS: every OPS-2027 date that reaches SKU-2 (5 Sundays + the freeze)" \
   "$(q "SELECT COUNT(DISTINCT occur_dt) FROM v_res_calendar WHERE event_grp_code='OPS-2027' AND res_code='SKU-2'")" "6"
ck "events are keyed on res_grp_id: no res_type or res_code column" \
   "$(q "SELECT group_concat(name,',') FROM (SELECT name FROM pragma_table_info('calndr_event')
         WHERE name IN ('res_type','res_code','res_grp_id') ORDER BY 1)")" "res_grp_id"
ck "single resource: /RES/CUSTOMER/C001 created at level 3 under /RES/CUSTOMER and /RES" \
   "$(q "SELECT g.group_level||'|'||p.group_path||'|'||pp.group_path FROM res_grp g
         JOIN res_grp p ON p.res_grp_id=g.parent_res_grp JOIN res_grp pp ON pp.res_grp_id=p.parent_res_grp
         WHERE g.group_path='/RES/CUSTOMER/C001'")" "3|/RES/CUSTOMER|/RES"
ck "single resource: its one member is C001's res_id" \
   "$(q "SELECT group_concat(x.res_id) FROM res_resgrp x JOIN res_grp g USING(res_grp_id) WHERE g.group_path='/RES/CUSTOMER/C001'")" "1"
ck "C001-REVIEW: month ends, January to June 2027" "$(occ C001-REVIEW)" \
   "2027-01-31,2027-02-28,2027-03-31,2027-04-30,2027-05-31,2027-06-30"
ck "C001-REVIEW: reaches C001 and nothing else" "$(reach C001-REVIEW)" "C001"
ck "PIM-MAINT: every Sunday in January 2027" "$(occ PIM-MAINT)" \
   "2027-01-03,2027-01-10,2027-01-17,2027-01-24,2027-01-31"
ck "PIM-MAINT (/TYPE/PRODUCT): reaches every product and only products" \
   "$(q "SELECT group_concat(DISTINCT res_type)||'/'||COUNT(DISTINCT res_id) FROM v_res_calendar WHERE event_code='PIM-MAINT'")" \
   "PRODUCT/$(q "SELECT COUNT(*) FROM res WHERE res_type='PRODUCT'")"
ck "NEWYEAR (/TYPE, inherited): one date, every resource of every type" \
   "$(occ NEWYEAR)/$(q "SELECT COUNT(DISTINCT res_id) FROM v_res_calendar WHERE event_code='NEWYEAR'")" \
   "2027-01-01/$(q "SELECT COUNT(*) FROM res")"
ck "ORDER-FREEZE: the last day of December 2027" "$(occ ORDER-FREEZE)" "2027-12-31"
ck "SPRING-SALE: every day from 1 to 7 March 2026" "$(occ SPRING-SALE)" \
   "2026-03-01,2026-03-02,2026-03-03,2026-03-04,2026-03-05,2026-03-06,2026-03-07"
ck "CONTEXT: the two 2026-03-02 price samples carry SPRING-SALE" \
   "$(q "SELECT group_concat(res_code||'@'||printf('%.2f',value)||'='||event_code,',') FROM
         (SELECT * FROM v_metric_sample_event WHERE event_grp_code='PROMOS-2026' ORDER BY res_code)")" \
   "SKU-1@8.99=SPRING-SALE,SKU-2@19.50=SPRING-SALE"
ck "CONTEXT: a sample outside every event carries none (SKU-1 on 2026-02-05)" \
   "$(q "SELECT COUNT(*) FROM v_metric_sample_event WHERE res_code='SKU-1' AND date(sample_utc_ts)='2026-02-05'")" "0"
ck "ORDER-FREEZE (/ORDER, inherited): reaches the products on remaining order lines" \
   "$(reach ORDER-FREEZE)" "SKU-2"
q "INSERT INTO res_grp(res_grp_id,res_grp_name,group_level,group_path,srcd_ts)
   VALUES(999,'ORDERS',1,'/ORDERS','2027-01-04 08:00:00');
   INSERT INTO res_resgrp VALUES(999,5,'2027-01-04 08:00:00');" >/dev/null
ck "inheritance stops at the path separator: /ORDER does not reach a group named /ORDERS" \
   "$(reach ORDER-FREEZE)" "SKU-2"
q "DELETE FROM res_resgrp WHERE res_grp_id=999; DELETE FROM res_grp WHERE res_grp_id=999;" >/dev/null

before="$(snap)"
feed c1_calendar.sql C1R '2027-01-05 08:00:00' "$PROJ/source_ext"
ck "unchanged calendar re-delivered under a new id writes nothing" "$(snap)" "$before"

echo; echo "== Calendar C2: a one-attribute change and a tombstone =="
feed c2_calendar_changes.sql C2 '2027-01-11 08:00:00' "$HERE/fixtures"
ck "inheritance off: ORDER-FREEZE reaches nothing (/ORDER has no direct members)" \
   "$(q "SELECT COUNT(*) FROM v_res_calendar WHERE event_code='ORDER-FREEZE'")" "0"
ck "partial delivery: ORDER-FREEZE keeps its target, group, months and year" \
   "$(q "SELECT target||'|'||event_grp_code||'|'||months||'|'||year FROM v_calndr_event WHERE event_code='ORDER-FREEZE'")" \
   "/ORDER|OPS-2027|NNNNNNNNNNNY|2027"
ck "EVENT GROUPS: PIM-MAINT moved to MAINT-2027, created by this delivery as id 4" \
   "$(q "SELECT e.event_grp_code||'='||x.event_grp_id FROM v_calndr_event e JOIN cal_evt_grp x USING(event_grp_code)
         WHERE e.event_code='PIM-MAINT'")" "MAINT-2027=4"
ck "changed rows only: ORDER-FREEZE restamped, C001-REVIEW untouched" \
   "$(q "SELECT group_concat(event_code||'='||srcd_ts,',') FROM (SELECT * FROM calndr_event WHERE event_code IN ('ORDER-FREEZE','C001-REVIEW') ORDER BY 1)")" \
   "C001-REVIEW=2027-01-04 08:00:00,ORDER-FREEZE=2027-01-11 08:00:00"
ck "tombstone: NEWYEAR deleted" "$(q "SELECT COUNT(*) FROM calndr_event WHERE event_code='NEWYEAR'")" "0"
ck "INCREMENTAL absence: PIM-MAINT kept" "$(q "SELECT COUNT(*) FROM calndr_event WHERE event_code='PIM-MAINT'")" "1"

echo; echo "== Calendar C3: FULL delivery lists only C001-REVIEW =="
feed c3_calendar_full.sql C3 '2027-01-18 08:00:00' "$HERE/fixtures"
ck "FULL absence: ORDER-FREEZE, PIM-MAINT and SPRING-SALE deleted, C001-REVIEW kept" \
   "$(q "SELECT group_concat(event_code,',') FROM calndr_event")" "C001-REVIEW"
ck "NOCHANGE: the restated C001-REVIEW kept its srcd_ts" \
   "$(q "SELECT srcd_ts FROM calndr_event WHERE event_code='C001-REVIEW'")" "2027-01-04 08:00:00"
ck "deleting events leaves their event groups in place" \
   "$(q "SELECT COUNT(*) FROM cal_evt_grp")" "4"
ck "deleting events leaves their resource groups in place" \
   "$(q "SELECT COUNT(*) FROM res_grp WHERE group_path IN ('/RES/CUSTOMER/C001','/ORDER','/TYPE/PRODUCT')")" "3"

echo; echo "== Calendar: bad targets and types fail the load =="
bad_event(){ local id="$1" path="$2" type="$3"
  cat > "$LOGDIR/$id.sql" <<SQL
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('OPS','CALNDR_EVENT','BAD','event_code','BAD',NULL,NULL,'2027-01-20','UPSERT','INCREMENTAL'),
('OPS','CALNDR_EVENT','BAD','group_path','$path',NULL,NULL,'2027-01-20','UPSERT','INCREMENTAL'),
('OPS','CALNDR_EVENT','BAD','cal_evt_type','$type',NULL,NULL,'2027-01-20','UPSERT','INCREMENTAL'),
('OPS','CALNDR_EVENT','BAD','event_start_dt',NULL,NULL,'2027-02-01','2027-01-20','UPSERT','INCREMENTAL');
SQL
  BATCH_TS='2027-01-20 08:00:00' "$PROJ/scripts/load_feed.sh" "$LOGDIR/$id.sql" "$id" >/dev/null 2>&1; local rc=$?
  q "DELETE FROM source_landing_stage;" >/dev/null
  [ "$rc" -ne 0 ] && echo rejected || echo accepted; }
before="$(snap)"
ck "a target group that does not exist is rejected" "$(bad_event CB1 /NOPE HOLIDAY)" "rejected"
ck "a /RES/ target for an unknown resource is rejected" "$(bad_event CB2 /RES/CUSTOMER/C999 HOLIDAY)" "rejected"
ck "an unknown cal_evt_type is rejected by its foreign key" "$(bad_event CB3 /TYPE PARTY)" "rejected"
ck "  ...and none of the three wrote anything" "$(snap)" "$before"

echo; echo "== Rebuild after every fixture =="
before="$(snap)"; before_census="$(census)"
rm -f "$DB"
"$PROJ/scripts/rebuild.sh" >"$LOGDIR/rebuild2.log" 2>&1
ck "rebuild: census identical" "$(census)" "$before_census"
ck "rebuild: every surrogate, value and srcd_ts identical" "$(snap)" "$before"
ck "rebuild: the two failed deliveries (DX, DR) were not replayed" \
   "$(q "SELECT COUNT(*) FROM res WHERE res_code IN ('O-999','O-103')")" "0"
ck "rebuild: tiebreak survives replay (seq_nbr order restored)" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C004'")" "last@x.com"

echo; echo "== Code table relabel: one row, every order, no reload =="
q "UPDATE order_status SET status_name='PLACED' WHERE status_code='P';" >/dev/null
ck "relabel: every pending order reads PLACED instantly" \
   "$(q "SELECT group_concat(DISTINCT status) FROM v_order WHERE order_ref IN ('O-100','O-101')")" "PLACED"

echo; echo "== A new metric is a row: no DDL, no loader change =="
tables_before="$(q "SELECT COUNT(*)||'/'||SUM(length(sql)) FROM sqlite_master")"
q "INSERT INTO metric(metric_id,value_type,metric_code,metric_name,unit_of_measure,srcd_ts)
   VALUES(3,'GAUGE','weight_kg','Shipping weight','kg','2027-05-01 00:00:00');
   INSERT INTO meta_attribute_map(source_system,source_entity,source_attribute,target_kind,slot,metric_code)
   VALUES('PIM','PRODUCT','weight_kg','METRIC','value_num','weight_kg');" >/dev/null
cat > "$LOGDIR/weight.sql" <<'SQL'
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('PIM','PRODUCT','SKU-1','weight_kg',NULL,0.35,NULL,'2027-05-01','UPSERT','INCREMENTAL');
SQL
feed weight.sql DW '2027-05-01 08:00:00' "$LOGDIR"
ck "new metric: its first sample loaded and aggregated" \
   "$(q "SELECT printf('%.2f',value)||'/'||value_cnt FROM v_metric_weekly WHERE res_code='SKU-1' AND metric_code='weight_kg'")" "0.35/1"
ck "new metric: the schema did not change" \
   "$(q "SELECT COUNT(*)||'/'||SUM(length(sql)) FROM sqlite_master")" "$tables_before"
"$PROJ/scripts/rebuild.sh" >"$LOGDIR/rebuild3.log" 2>&1
ck "  ...and rebuild resets both: the schema seed is the source of truth" \
   "$(q "SELECT (SELECT DISTINCT status FROM v_order WHERE order_ref='O-100')||'/'||(SELECT COUNT(*) FROM metric)")" "PENDING/2"


echo; echo "== A recoded resource keeps its calendar =="
q "UPDATE res SET res_code='C001-NEW' WHERE res_id=1;
   UPDATE res_alias SET res_alias='C001-NEW' WHERE res_type='CUSTOMER' AND res_alias='C001';" >/dev/null
ck "recode: C001-REVIEW still reaches res_id 1, now under its new code" \
   "$(q "SELECT group_concat(DISTINCT res_id||'='||res_code) FROM v_res_calendar WHERE event_code='C001-REVIEW'")" "1=C001-NEW"
ck "recode: the diagram's res_type + res_code key would have found nothing" \
   "$(q "SELECT COUNT(*) FROM res WHERE res_type='CUSTOMER' AND res_code='C001'")" "0"
echo; echo "====================================================================="
printf "  RESULT: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "====================================================================="
rm -f "$DB" "$ARCHIVE_DB"
[ "$FAIL" -eq 0 ] || exit 1
