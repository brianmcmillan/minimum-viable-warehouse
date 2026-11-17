#!/usr/bin/env bash
# =====================================================================
# INCREMENTAL variant test suite -- proves safe delete semantics under a
# realistic feed cadence. Pure shell + sqlite3, no other deps.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
# No `set -e`: every assertion must run so one failure doesn't hide the rest.
# Loudness comes from feed() and q() instead -- an infrastructure failure
# (loader crash, bad SQL) is reported at its origin, never as a downstream
# cascade of mysterious assertion mismatches.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/focal_inc_test).db}"
# The raw layer is a second, durable database. Isolate it per run, or the
# archive from a previous run would make every delivery here a skipped
# duplicate.
export ARCHIVE_DB="${DB%.db}_archive.db"
export SQLITE
PASS=0; FAIL=0; FEED_N=0; SKIPPED=0
LOGDIR="$(mktemp -d)"; trap 'rm -rf "$LOGDIR"' EXIT

# A query that errors returns a value no assertion can match, and says why.
q(){ local out rc=0
     out="$("$SQLITE" "$DB" "$1" 2>&1)" || rc=$?
     if [ "$rc" -ne 0 ]; then
       printf "  \033[31mSQL ERROR\033[0m (exit %d): %s\n    query: %s\n" "$rc" "$out" "$1" >&2
       printf '<SQL-ERROR>'; return 0
     fi
     printf '%s' "$out"; }

# Same, with the raw layer attached as `arch` (loaded_files lives there now).
aq(){ local out rc=0
      out="$("$SQLITE" -cmd "ATTACH DATABASE '$ARCHIVE_DB' AS arch" "$DB" "$1" 2>&1)" || rc=$?
      if [ "$rc" -ne 0 ]; then
        printf "  \033[31mSQL ERROR\033[0m (exit %d): %s\n    query: %s\n" "$rc" "$out" "$1" >&2
        printf '<SQL-ERROR>'; return 0
      fi
      printf '%s' "$out"; }
ck(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1";
      else FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s  (got '%s', expected '%s')\n" "$1" "$2" "$3"; fi; }

# Expected-failure check for KNOWN GAPS: asserts the DESIRED behaviour.
# Today it fails, prints amber, and does not fail the suite. The strict
# part: if it ever PASSES, the gap has been fixed -- the suite goes RED
# on purpose, telling you to promote the ckx() lines to ck() and delete
# the defect assertions next to them.
GAPS=0
ckx(){ if [ "$2" = "$3" ]; then FAIL=$((FAIL+1));
         printf "  \033[31mXPASS\033[0m %s -- the driving-key gap appears FIXED.\n" "$1"
         printf "        Promote this ckx() to ck() and remove the paired defect assertion.\n"
       else GAPS=$((GAPS+1));
         printf "  \033[33mGAP \033[0m %s  (got '%s', wanted '%s')\n" "$1" "$2" "$3"; fi; }
ckey(){ q "SELECT customer_key FROM customer_idfr WHERE customer_idfr='$1'"; }
# Deliveries arrive wide. Rows a delivery carried (wide stage) and rows the
# archive holds for it (the shared hist_* layout; no narrow table).
wide_rows(){ q "SELECT (SELECT COUNT(*) FROM stg_customer_l1)+(SELECT COUNT(*) FROM stg_product_l1)
                      +(SELECT COUNT(*) FROM stg_order_l1)+(SELECT COUNT(*) FROM stg_order_line_l1)"; }
hist_rows(){ local w=""; [ -n "${1:-}" ] && w=" WHERE file_id='$1'"
  aq "SELECT (SELECT COUNT(*) FROM arch.hist_customer$w)+(SELECT COUNT(*) FROM arch.hist_product$w)
            +(SELECT COUNT(*) FROM arch.hist_order$w)+(SELECT COUNT(*) FROM arch.hist_order_line$w)"; }

# Row census across every data table, as "tbl=n tbl=n ...". Compared as one
# string so a failure names the table that grew.
census(){ q "SELECT group_concat(t||'='||n,' ') FROM (
    SELECT 1 o,'customer_idfr'    t,COUNT(*) n FROM customer_idfr
    UNION ALL SELECT 2,'customer_focal',   COUNT(*) FROM customer_focal
    UNION ALL SELECT 3,'customer_desc',    COUNT(*) FROM customer_desc
    UNION ALL SELECT 4,'product_idfr',     COUNT(*) FROM product_idfr
    UNION ALL SELECT 5,'product_focal',    COUNT(*) FROM product_focal
    UNION ALL SELECT 6,'product_desc',     COUNT(*) FROM product_desc
    UNION ALL SELECT 7,'order_idfr',       COUNT(*) FROM order_idfr
    UNION ALL SELECT 8,'order_focal',      COUNT(*) FROM order_focal
    UNION ALL SELECT 9,'order_desc',       COUNT(*) FROM order_desc
    UNION ALL SELECT 10,'order_customer_x',COUNT(*) FROM order_customer_x
    UNION ALL SELECT 11,'order_product_x', COUNT(*) FROM order_product_x
    ORDER BY o);"; }

# A pipeline name ends with its feed, or has the feed followed by ':'
# ("IDFR:CUSTOMER:CRM.CUSTOMER", "REL:PLACED_BY:OMS.ORDER:INCREMENTAL").
# Matching on the delimiters keeps OMS.ORDER from matching OMS.ORDER_LINE.
FEED_MATCH="(p.pipeline LIKE '%:'||d.f OR p.pipeline LIKE '%:'||d.f||':%')"

# Structural invariant checked after EVERY delivery: loaded_files must agree
# with what the loaders actually did, and the loaders must have processed
# exactly the feeds the delivery carried -- no stale feeds from earlier
# deliveries, and none of the delivery's own feeds silently skipped.
# A skipped delivery writes nothing at all.
ck_load_control(){ local file_id="$1" ts="$2"
  ck "[$file_id] loaded_files: recorded exactly once" \
     "$(aq "SELECT COUNT(*) FROM arch.loaded_files WHERE file_id='$file_id'")" "1"
  if [ "$SKIPPED" -eq 1 ]; then
    ck "[$file_id] loaded_files: skipped delivery ran no loader" \
       "$(q "SELECT COUNT(*) FROM meta_procinst WHERE batch_ts='$ts'")" "0"
    return
  fi
  ck "[$file_id] loaded_files: marked COMPLETE after every loader" \
     "$(aq "SELECT status FROM arch.loaded_files WHERE file_id='$file_id'")" "COMPLETE"
  ck "[$file_id] loaded_files: row_count matches rows delivered" \
     "$(aq "SELECT row_count FROM arch.loaded_files WHERE file_id='$file_id'")" \
     "$(wide_rows)"
  ck "[$file_id] archive: raw rows captured verbatim" \
     "$(hist_rows "$file_id")" \
     "$(wide_rows)"

  # No loader touched a feed this delivery did not carry.
  ck "[$file_id] scope: no loader ran outside the delivery's feeds" \
     "$(q "WITH d AS (SELECT DISTINCT source_system||'.'||source_entity f FROM source_landing_stage)
           SELECT COUNT(*) FROM meta_procinst p
           WHERE p.batch_ts='$ts' AND NOT EXISTS (SELECT 1 FROM d WHERE $FEED_MATCH)")" "0"

  # Every feed the delivery carried ran each loader it is mapped to.
  ck "[$file_id] scope: every delivered feed ran its mapped loaders" \
     "$(q "WITH d0 AS (SELECT DISTINCT source_system ss, source_entity se FROM source_landing_stage),
                want AS (
                  SELECT m.role k, m.source_system||'.'||m.source_entity f
                    FROM meta_source_map m JOIN d0 ON d0.ss=m.source_system AND d0.se=m.source_entity
                   WHERE m.role IN ('IDFR','DESC')
                  UNION
                  SELECT 'REL', m.source_system||'.'||m.source_entity
                    FROM meta_rel_map m JOIN d0 ON d0.ss=m.source_system AND d0.se=m.source_entity)
           SELECT COUNT(*) FROM want d
           WHERE NOT EXISTS (SELECT 1 FROM meta_procinst p
                             WHERE p.batch_ts='$ts' AND p.pipeline LIKE d.k||':%' AND $FEED_MATCH)")" "0"; }

# Run one delivery. A non-zero loader aborts the suite immediately: past that
# point every assertion measures a half-loaded database, not the code.
feed(){ local src="$1" file_id="$2" ts="$3" rc=0 log
  FEED_N=$((FEED_N+1)); log="$LOGDIR/$FEED_N-$file_id.log"
  BATCH_TS="$ts" "$PROJ/scripts/load_feed.sh" "$PROJ/source/$src" "$file_id" >"$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf "\n  \033[31mABORT\033[0m load_feed.sh exited %d at delivery %s (%s)\n" "$rc" "$file_id" "$src"
    printf "  ---- loader output ----\n"; sed 's/^/  | /' "$log"; printf "  -----------------------\n"
    printf "\n  %d passed, %d failed before the abort.\n" "$PASS" "$FAIL"; exit 1
  fi
  if grep -q 'SKIP duplicate' "$log"; then SKIPPED=1; else SKIPPED=0; fi
  ck_load_control "$file_id" "$ts"; }

echo "== Fresh db =="; rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null

echo; echo "== D0: FULL baseline =="
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
ck "baseline: 2 customers"          "$(q 'SELECT COUNT(*) FROM customer_focal')" "2"
ck "baseline: 3 products"           "$(q 'SELECT COUNT(*) FROM product_focal')" "3"
ck "baseline: C001 email v1"        "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@example.com"

echo; echo "== D1: CRM 14-day INCREMENTAL window (C001 changed; C002 absent) =="
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
ck "INCREMENTAL: C001 email updated"                 "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@newmail.com"
ck "INCREMENTAL: C002 NOT deleted (60-day stale)"    "$(q "SELECT row_st FROM customer_desc WHERE customer_key=$(ckey C002) AND type_key=11 ORDER BY eff_tmstp DESC,ver_tmstp DESC LIMIT 1")" "Y"
ck "INCREMENTAL: C002 email unchanged"               "$(q "SELECT email FROM v_customer WHERE customer_ref='C002'")" "bob@example.com"
ck "INCREMENTAL: C002 no version churn (1 row)"      "$(q "SELECT COUNT(*) FROM customer_desc WHERE customer_key=$(ckey C002) AND type_key=11")" "1"
ck "INCREMENTAL: still 2 customers"                  "$(q 'SELECT COUNT(*) FROM customer_focal')" "2"

echo; echo "== D2: PIM FULL snapshot (SKU-3 discontinued) =="
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
sku3="$(q "SELECT product_key FROM product_idfr WHERE product_idfr='SKU-3'")"
ck "FULL: SKU-3 deleted on absence"        "$(q "SELECT row_st FROM product_desc WHERE product_key=$sku3 AND type_key=20 ORDER BY eff_tmstp DESC,ver_tmstp DESC LIMIT 1")" "N"
ck "FULL: SKU-3 key still exists"          "$(q "SELECT COUNT(*) FROM product_focal WHERE product_key=$sku3")" "1"
ck "FULL: SKU-1 price changed 8.99"        "$(q "SELECT price FROM v_product WHERE sku='SKU-1'")" "8.99"

echo; echo "== D3: INCREMENTAL tombstone deletes C002 =="
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
ck "tombstone: C002 now deleted"          "$(q "SELECT row_st FROM customer_desc WHERE customer_key=$(ckey C002) AND type_key=11 ORDER BY eff_tmstp DESC,ver_tmstp DESC LIMIT 1")" "N"
ck "tombstone: C002 gone from v_customer" "$(q "SELECT COALESCE(email,'<none>') FROM v_customer WHERE customer_ref='C002'")" "<none>"

echo; echo "== D4: INCREMENTAL adds C003; recency de-dup =="
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
ck "recency: newest email wins (not MAX)"  "$(q "SELECT email FROM v_customer WHERE customer_ref='C003'")" "new@x.com"

echo; echo "== Load control: re-deliver D1 (same file_id) must be skipped =="
before="$(q 'SELECT COUNT(*) FROM customer_desc')"
feed d1_cust_win_day60.sql D1 '2026-04-10 08:00:00'
ck "dup file skipped: desc rows unchanged" "$(q 'SELECT COUNT(*) FROM customer_desc')" "$before"
ck "dup file: D1 recorded once"            "$(aq "SELECT COUNT(*) FROM arch.loaded_files WHERE file_id='D1'")" "1"
ck "dup file: D1 archived once"            "$(hist_rows D1)" \
                                           "$(aq "SELECT row_count FROM arch.loaded_files WHERE file_id='D1'")"

echo; echo "== D5: YEARLY FULL reconciliation (C003 gone at source) =="
feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'
ck "reconcile: C003 deleted by absence (FULL)" "$(q "SELECT row_st FROM customer_desc WHERE customer_key=$(ckey C003) AND type_key=11 ORDER BY eff_tmstp DESC,ver_tmstp DESC LIMIT 1")" "N"
ck "reconcile: C001 survives"                  "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@newmail.com"
ck "reconcile: C002 stays deleted"             "$(q "SELECT COALESCE(email,'<none>') FROM v_customer WHERE customer_ref='C002'")" "<none>"

echo; echo "== Contrast: absence deletes under FULL, never under INCREMENTAL =="
ck "C002 survived the incremental window, only died to a tombstone" \
   "$(q "SELECT COUNT(*) FROM customer_desc WHERE customer_key=$(ckey C002) AND type_key=11 AND row_st='N'")" "1"

echo; echo "== Idempotence: replaying the whole sequence must change nothing =="
census_0="$(census)"
files_0="$(aq 'SELECT COUNT(*) FROM arch.loaded_files')"
arch_0="$(hist_rows)"
inst_0="$(q 'SELECT COUNT(*) FROM meta_procinst')"
feed d0_baseline.sql         B0 '2027-01-05 08:00:00'
feed d1_cust_win_day60.sql   D1 '2027-01-05 08:01:00'
feed d2_prod_full_v2.sql     D2 '2027-01-05 08:02:00'
feed d3_cust_tombstone.sql   D3 '2027-01-05 08:03:00'
feed d4_cust_recency.sql     D4 '2027-01-05 08:04:00'
feed d5_cust_yearly_full.sql D5 '2027-01-05 08:05:00'
ck "replay: zero new data rows"     "$(census)" "$census_0"
ck "replay: zero new loaded_files"  "$(aq 'SELECT COUNT(*) FROM arch.loaded_files')" "$files_0"
ck "replay: zero new archived rows" "$(hist_rows)" "$arch_0"
ck "replay: zero new pipeline runs" "$(q 'SELECT COUNT(*) FROM meta_procinst')" "$inst_0"

echo; echo "== True loader idempotence: same content, NEW file_id, loaders RUN, write nothing =="
# The replay block above proves the skip guard (same file_id -> loaders never
# run). This proves the loaders themselves: d5's content re-asserts the
# current warehouse state, so under a fresh file_id every loader runs and
# every delta must come up empty. loaded_files and the archive DO grow (one
# control row, d5's raw rows) -- that is load control working -- so only the
# data-table census is compared.
before_d5r="$(census)"
feed d5_cust_yearly_full.sql D5R '2027-02-15 08:00:00'
ck "re-asserted current state writes zero data rows" "$(census)" "$before_d5r"

echo; echo "== KNOWN GAP: driving-key re-point (fixture d7_repoint.sql) =="
# OMS corrects O-101 from C002 to C001. Every sibling demo handles this
# (DV effectivity sat, Kimball fact update, Inmon order version, Anchor
# historized tie, OBT latest-wins). Focal's load_rel.sh only knows
# NEW / tombstone-DEL / FULL-absence-DEL -- a re-pointed driving key
# inserts the new pair and leaves the old one active.
BATCH_TS='2027-03-01 08:00:00' "$PROJ/scripts/load_feed.sh" \
  "$HERE/fixtures/d7_repoint.sql" D7 >"$LOGDIR/d7.log" 2>&1 \
  || { echo "  ABORT: repoint fixture crashed the loader"; sed 's/^/  | /' "$LOGDIR/d7.log"; exit 1; }
okey="$(q "SELECT order_key FROM order_idfr WHERE order_idfr='O-101'")"

# Today's DEFECT, asserted so an accidental behaviour change is caught:
ck  "defect today: O-101 has BOTH pairings active (one order, two customers)" \
    "$(q "SELECT COUNT(*) FROM order_customer_x WHERE order_key=$okey AND type_key=90 AND row_st='Y'")" "2"

# The DESIRED behaviour, as expected failures (amber, non-fatal):
ckx "desired: exactly ONE active pairing for the driving key" \
    "$(q "SELECT COUNT(*) FROM order_customer_x WHERE order_key=$okey AND type_key=90 AND row_st='Y'")" "1"
ckx "desired: the active pairing is C001" \
    "$(q "SELECT group_concat(customer_key,',') FROM order_customer_x
          WHERE order_key=$okey AND type_key=90 AND row_st='Y'")" "$(ckey C001)"
# NOTE deliberately NOT asserted: v_order.placed_by. Under the defect it
# is UNDEFINED -- the view picks one of the two active pairings with
# LIMIT 1 and no ORDER BY, so any expected value can pass by planner
# accident (observed in this suite's own first run). That nondeterminism
# is itself a symptom of the gap; assert it only after the fix.

if [ "$GAPS" -gt 0 ]; then
  echo "  ---------------------------------------------------------------"
  echo "  SUGGESTED FIX (see also INCREMENTAL.md 'Known gap'):"
  echo "    1. Declare the driving side per relationship, e.g. add a"
  echo "       driving_role column to meta_relationship ('SOURCE' for"
  echo "       PLACED_BY: an order has one customer at a time; NULL for"
  echo "       CONTAINS: order lines are additive pairs)."
  echo "    2. In load_rel.sh, add a del_repoint CTE next to del_tomb:"
  echo "       close (flag='DEL') every ACTIVE target pair whose driving"
  echo "       key appears in src with a DIFFERENT counterpart, gated on"
  echo "       driving_role. new_delta already inserts the new pair."
  echo "    3. Flip the ckx() assertions above to ck(), drop the defect"
  echo "       assertion, and re-run the suite's mutation checks."
  echo "  ---------------------------------------------------------------"
fi

echo; echo "== Level 1: the wide -> narrow transform (stage_narrow.sh) =="
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
ck "level 1: 6 wide rows -> 21 narrow rows (customer 4+4+1, product 4, order 6, line 2)" \
   "$(q 'SELECT COUNT(*) FROM source_landing_stage')" "21"
ck "level 1: type routing, customer (signup_date -> value_ts; empty email -> all NULL)" "$(types C1)" \
   "customer_ref:text/null/null full_name:text/null/null email_addr:null/null/null signup_date:null/null/text customer_ref:text/null/null full_name:text/null/null email_addr:text/null/null signup_date:null/null/text"
ck "level 1: type routing, product (price -> value_num, currency -> value_str)" "$(types S1)" \
   "sku:text/null/null prod_name:text/null/null price:null/real/null currency:text/null/null"
ck "level 1: type routing, order (amount -> value_num, placed_at -> value_ts)" "$(types O1)" \
   "order_ref:text/null/null customer_ref:text/null/null status:text/null/null amount:null/real/null currency:text/null/null placed_at:null/null/text"
ck "level 1: signup_date lands in value_ts" \
   "$(q "SELECT DISTINCT value_ts FROM source_landing_stage WHERE business_key='C1' AND attribute_name='signup_date'")" "2026-01-01"
ck "level 1: derived key rows (customer_ref=C1, sku=S1, order_ref=O1)" \
   "$(q "SELECT group_concat(a||'='||v,' ') FROM (SELECT attribute_name a, value_str v, MIN(rowid) r
         FROM source_landing_stage
         WHERE (business_key,attribute_name) IN (VALUES ('C1','customer_ref'),('S1','sku'),('O1','order_ref'))
         GROUP BY 1,2 ORDER BY r)")" "customer_ref=C1 sku=S1 order_ref=O1"
ck "level 1: order line keyed order_ref~sku, carrying both ends" \
   "$(types 'O1~S1')|$(q "SELECT group_concat(value_str,',') FROM (SELECT value_str FROM source_landing_stage WHERE business_key='O1~S1' ORDER BY rowid)")" \
   "order_ref:text/null/null sku:text/null/null|O1,S1"
ck "level 1: empty column -> a row holding SQL NULL (not skipped, not the string)" \
   "$(q "SELECT COUNT(*)||'/'||typeof(MAX(value_str)) FROM source_landing_stage
         WHERE business_key='C1' AND attribute_name='email_addr' AND value_str IS NULL")" "1/null"
ck "level 1: no value is ever the string 'NULL'" \
   "$(q "SELECT COUNT(*) FROM source_landing_stage WHERE 'NULL' IN (value_str, value_ts)")" "0"
ck "level 1: a DELETE emits exactly one _tombstone row, op DELETE" \
   "$(q "SELECT COUNT(*)||'|'||MAX(attribute_name)||'|'||MAX(op) FROM source_landing_stage WHERE business_key='C2'")" "1|_tombstone|DELETE"
ck "level 1: order is feed, then wide row, then attribute position" \
   "$(q "SELECT group_concat(e,',') FROM (SELECT source_entity e, MIN(rowid) r FROM source_landing_stage GROUP BY 1 ORDER BY r)")|$(q "SELECT group_concat(attribute_name,',') FROM (SELECT attribute_name FROM source_landing_stage WHERE business_key='C1' ORDER BY rowid)")" \
   "CUSTOMER,PRODUCT,ORDER,ORDER_LINE|customer_ref,full_name,email_addr,signup_date,customer_ref,full_name,email_addr,signup_date"
ck "level 1: within one (key, attribute) the later wide row gets the later rowid" \
   "$(q "SELECT COALESCE(value_str,'<null>') FROM source_landing_stage WHERE business_key='C1' AND attribute_name='email_addr' ORDER BY rowid DESC LIMIT 1")" "b@x"
first_pass="$(q 'SELECT * FROM source_landing_stage ORDER BY rowid')"
"$PROJ/scripts/stage_narrow.sh" >/dev/null 2>&1
ck "level 1: re-running stage_narrow emits identical rows (it clears first, order is fixed)" \
   "$(q 'SELECT * FROM source_landing_stage ORDER BY rowid')" "$first_pass"
# The shared corpus: every row of every old narrow delivery is reproduced.
# Only D4 emits more (8 vs 5): wide sends C003's whole record twice.
for n in d0_baseline d1_cust_win_day60 d2_prod_full_v2 d3_cust_tombstone d4_cust_recency d5_cust_yearly_full; do
  q "DELETE FROM stg_customer_l1; DELETE FROM stg_product_l1; DELETE FROM stg_order_l1; DELETE FROM stg_order_line_l1;
     DROP TABLE IF EXISTS narrow_ref; CREATE TABLE narrow_ref AS SELECT * FROM source_landing_stage WHERE 0;" >/dev/null
  "$SQLITE" "$DB" < "$PROJ/source/$n.sql"
  sed 's/INSERT INTO source_landing_stage/INSERT INTO narrow_ref/' "$HERE/fixtures/narrow/$n.sql" | "$SQLITE" "$DB"
  "$PROJ/scripts/stage_narrow.sh" >/dev/null 2>&1
  ck "level 1: unpivoted $n reproduces every row of the old narrow file" \
     "$(q "SELECT COUNT(*) FROM (SELECT * FROM narrow_ref EXCEPT SELECT * FROM source_landing_stage)")/$(q 'SELECT COUNT(*) FROM narrow_ref')" \
     "0/$(q 'SELECT COUNT(*) FROM narrow_ref')"
done

echo; echo "== Level 2: the narrow loaders, fed narrow rows directly =="
# Narrow-by-nature fixtures go straight into source_landing_stage and
# through apply_delivery.sh. They bypass load_feed.sh and the wide archive,
# so they run in their own scratch database that no rebuild ever reads.
export DB="$LOGDIR/level2.db" ARCHIVE_DB="$LOGDIR/level2_archive.db"
l2(){ "$SQLITE" "$DB" "DELETE FROM source_landing_stage;"; "$SQLITE" "$DB" < "$1"
      BATCH_TS="$2" "$PROJ/scripts/apply_delivery.sh" >/dev/null 2>&1; }
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null 2>&1
l2 "$HERE/fixtures/d6_tiebreak.sql" '2027-02-01 08:00:00'
ck "level 2: equal extract_ts -> the last narrow row wins (attribute-level tiebreak)" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C004'")" "last@x.com"
l2 "$HERE/fixtures/narrow/d4_cust_recency.sql" '2027-02-02 08:00:00'
ck "level 2: per-attribute recency -- newest extract_ts wins, not MAX" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C003'")" "new@x.com"
export DB="$SAVE_DB" ARCHIVE_DB="$SAVE_ARCHIVE_DB"

echo; echo "== Load control: a file_id names CONTENT (same block in all ten suites) =="
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
ck "reuse: crashed delivery X1 is left STARTED" \
   "$([ "$rc" -ne 0 ] && echo crashed)/$(x1_status)" "crashed/STARTED"
before="$(frozen)"
ck "reuse: STARTED X1 re-sent with a different row count is REJECTED" "$(rejected "$(reuse "$R_MORE")")" "rejected"
ck "reuse:   ... archive and warehouse untouched" "$(frozen)" "$before"
ck "reuse: STARTED X1 re-sent with the same row count, one value changed, is REJECTED" \
   "$(rejected "$(reuse "$R_EDIT")")" "rejected"
ck "reuse:   ... archive and warehouse untouched" "$(frozen)" "$before"
ck "reuse: STARTED X1 re-sent with its original content retries to COMPLETE" \
   "$(reuse "$R_ORIG")/$(x1_status)" "0/COMPLETE"
before="$(frozen)"
ck "reuse: COMPLETE X1 re-sent with the same row count, one value changed, is REJECTED" \
   "$(rejected "$(reuse "$R_EDIT")")" "rejected"
ck "reuse:   ... archive and warehouse untouched" "$(frozen)" "$before"
ck "reuse: COMPLETE X1 re-sent with a different row count is REJECTED" "$(rejected "$(reuse "$R_MORE")")" "rejected"
ck "reuse:   ... archive and warehouse untouched" "$(frozen)" "$before"
ck "reuse: COMPLETE X1 re-sent with its original content is skipped" \
   "$(reuse "$R_ORIG")/$(grep -c 'SKIP duplicate' "$LOGDIR/reuse.log")" "0/1"
ck "reuse:   ... archive and warehouse untouched" "$(frozen)" "$before"
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
ck "reuse: delivery X2 crashed before the archive write is left STARTED" \
   "$([ "$rc" -ne 0 ] && echo crashed)/$(x2_state)" "crashed/STARTED"
before="$(frozen)"
ck "reuse: STARTED X2 (nothing archived) re-sent with a different row count is REJECTED" \
   "$(rejected "$(x2 "$R_MORE")")" "rejected"
ck "reuse:   ... archive and warehouse untouched" "$(frozen)" "$before"
ck "reuse: STARTED X2 re-sent with its original content retries to COMPLETE" \
   "$(x2 "$R_ORIG")/$(x2_state)" "0/COMPLETE"
export DB="$SAVE_DB" ARCHIVE_DB="$SAVE_ARCHIVE_DB"

echo; echo "====================================================================="
printf "  RESULT: %d passed, %d failed, %d known gap(s)\n" "$PASS" "$FAIL" "$GAPS"
echo "====================================================================="
[ "$FAIL" -eq 0 ] || exit 1
