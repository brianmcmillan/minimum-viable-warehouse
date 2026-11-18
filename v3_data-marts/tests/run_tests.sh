#!/usr/bin/env bash
# =====================================================================
# Kimball star test suite.
#
# PART 1, CORE: the fourteen sections every one of the ten suites runs,
# in the same order and with the same labels (tests/core_spec.tsv at the
# repo root). Each model supplies its own SQL; the nine question
# answers live in tests/answers/Q<n>.sql.
# PART 2, MODEL: what the star shows on its own -- SCD2 versioning with
# deleted-marker versions, frozen surrogate keys in the facts, the
# generated date dimension, the Type 1 decode dimension, and the
# re-point as a fact UPDATE.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/kimball_test).db}"
export ARCHIVE_DB="${DB%.db}_archive.db"
FEED_N=0; SKIPPED=0
LOGDIR="$(mktemp -d)"; trap 'rm -rf "$LOGDIR"' EXIT

q(){  local out rc=0; out="$("$SQLITE" "$DB" "$1" 2>&1)" || rc=$?
      [ "$rc" -eq 0 ] || { printf "  \033[31mSQL ERROR\033[0m %s\n    %s\n" "$out" "$1" >&2
                           printf '<SQL-ERROR>'; return 0; }
      printf '%s' "$out"; }
pq(){ local out rc=0
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

census(){ q "SELECT group_concat(t||'='||n,' ') FROM (
    SELECT 1 o,'dim_cust' t,COUNT(*) n FROM dim_customer
    UNION ALL SELECT 2,'dim_prod',  COUNT(*) FROM dim_product
    UNION ALL SELECT 3,'fact_ord',  COUNT(*) FROM fact_orders
    UNION ALL SELECT 4,'fact_line', COUNT(*) FROM fact_order_lines
    ORDER BY o);"; }
archive_state(){ pq "SELECT (SELECT COUNT(*) FROM arch.loaded_files)||'/'||(SELECT COUNT(*) FROM arch.hist_customer)
                      ||'/'||(SELECT COUNT(*) FROM arch.hist_product)||'/'||(SELECT COUNT(*) FROM arch.hist_order)
                      ||'/'||(SELECT COUNT(*) FROM arch.hist_order_line)"; }

snap(){ q "
  SELECT 'dc', customer_key, customer_ref, COALESCE(customer_name,''), COALESCE(email,''),
         row_eff_ts, row_exp_ts, is_current, is_deleted FROM dim_customer
  UNION ALL
  SELECT 'dp', product_key, sku, COALESCE(product_name,''), COALESCE(price,''),
         row_eff_ts, row_exp_ts, is_current, is_deleted FROM dim_product
  UNION ALL
  SELECT 'fo', customer_key, order_ref, status_key, COALESCE(amount,''),
         placed_date_key, COALESCE(placed_at,''), 0, 0 FROM fact_orders
  UNION ALL
  SELECT 'fl', product_key, order_ref, placed_date_key, '', '', '', 0, 0 FROM fact_order_lines
  ORDER BY 1,2,3;"; }

# Run one delivery; abort the suite if a loader crashes. Its manifest
# and stage checks are model assertions, reported in M01.
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
     "$(pq "SELECT COUNT(*) FROM arch.loaded_files WHERE file_id='$file_id'")" "1"
  [ "$SKIPPED" -eq 0 ] && later M01 "[$file_id] manifest: COMPLETE after all loaders" \
     "$(pq "SELECT status FROM arch.loaded_files WHERE file_id='$file_id'")" "COMPLETE"
  later M01 "[$file_id] stage blank after delivery" \
     "$(q "SELECT (SELECT COUNT(*) FROM stg_customer_l1)+(SELECT COUNT(*) FROM stg_product_l1)
                +(SELECT COUNT(*) FROM stg_order_l1)+(SELECT COUNT(*) FROM stg_order_line_l1)")" "0"; }

versions(){ q "SELECT COUNT(*) FROM dim_customer WHERE customer_ref='$1'"; }

banner "1: CORE  (the same fourteen sections, in this order, in all ten suites)"

core_section C01
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null
core C01.1 "$(census)|$(archive_state)" "dim_cust=0 dim_prod=0 fact_ord=0 fact_line=0|0/0/0/0/0"

core_section C02
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
core C02.1 "$(q "SELECT (SELECT COUNT(*) FROM mart_customers)||'/'||(SELECT COUNT(*) FROM mart_products)
                ||'/'||(SELECT COUNT(*) FROM fact_orders)||'/'||(SELECT COUNT(*) FROM fact_order_lines)")" "2/3/2/3"
core C02.2 "$(ans 5)" "PENDING"
core C02.3 "$(ans 6)" "48.99"
later M02 "baseline: C001 email v1" "$(q "SELECT email FROM mart_customers WHERE customer_ref='C001'")" "alice@example.com"
later M02 "baseline: dim_date generated" "$(q "SELECT COUNT(*)>700 FROM dim_date")" "1"
later M02 "baseline: fact joins the calendar (O-100 -> Sunday)" \
   "$(q "SELECT d.weekday FROM fact_orders f JOIN dim_date d ON d.date_key=f.placed_date_key WHERE f.order_ref='O-100'")" "Sunday"
later M03 "decode dim: raw 'P' lives in archive, mart shows PENDING" \
   "$(pq "SELECT (SELECT DISTINCT status FROM arch.hist_order WHERE order_ref='O-100')||'/'||
                (SELECT status FROM mart_orders WHERE order_ref='O-100')")" "P/PENDING"

core_section C03
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
core C03.1 "$(q "SELECT email FROM mart_customers WHERE customer_ref='C001'")" "alice@newmail.com"
core C03.2 "$(q "SELECT COUNT(*) FROM mart_customers WHERE customer_ref='C002'")" "1"
core C03.3 "$(versions C002)" "1"
core C03.4 "$(q "SELECT COUNT(DISTINCT customer_name)||'/'||COUNT(DISTINCT signup_date) FROM dim_customer WHERE customer_ref='C001'")" "1/1"
later M04 "SCD2: C001 now has 2 versions"          "$(versions C001)" "2"
later M04 "SCD2: exactly one is current"           "$(q "SELECT COUNT(*) FROM dim_customer WHERE customer_ref='C001' AND is_current=1")" "1"
later M04 "SCD2: old version expired at batch ts"  "$(q "SELECT row_exp_ts FROM dim_customer WHERE customer_ref='C001' AND is_current=0")" "2026-03-02 08:00:00"
later M05 "FROZEN KEY: O-100 fact still points at C001 v1" \
   "$(q "SELECT c.email FROM fact_orders f JOIN dim_customer c ON c.customer_key=f.customer_key WHERE f.order_ref='O-100'")" "alice@example.com"

core_section C04
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
core C04.1 "$(q "SELECT price FROM mart_products WHERE sku='SKU-1'")" "8.99"
core C04.2 "$(q "SELECT COUNT(*) FROM mart_products WHERE sku='SKU-3'")" "0"
core C04.3 "$(q "SELECT COUNT(*) FROM dim_product WHERE sku='SKU-2'")" "1"
core C04.4 "$(ans 4)" "9.99>8.99"
later M04 "FULL: SKU-3 expired + deleted-marker version (2 rows)" \
   "$(q "SELECT COUNT(*) FROM dim_product WHERE sku='SKU-3'")" "2"
later M04 "FULL: SKU-3 current version flagged deleted" \
   "$(q "SELECT is_deleted FROM dim_product WHERE sku='SKU-3' AND is_current=1")" "1"
later M04 "FULL: SKU-3 last-known attrs preserved" \
   "$(q "SELECT product_name FROM dim_product WHERE sku='SKU-3' AND is_current=1")" "Gizmo"

core_section C05
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
core C05.1 "$(q "SELECT is_deleted FROM dim_customer WHERE customer_ref='C002' AND is_current=1")" "1"
core C05.2 "$(q "SELECT COUNT(*) FROM mart_customers WHERE customer_ref='C002'")" "0"
core C05.3 "$(q "SELECT COALESCE(placed_by_current,'<none>') FROM mart_orders WHERE order_ref='O-101'")" "<none>"
core C05.4 "$(q "SELECT customer_name||'/'||email FROM dim_customer WHERE customer_ref='C002' AND is_deleted=0")" \
           "Bob Jones/bob@example.com"
core C05.5 "$(ans 7)" "Bob Jones"
later M04 "tombstone: last-known attrs carried onto the marker" \
   "$(q "SELECT customer_name FROM dim_customer WHERE customer_ref='C002' AND is_current=1")" "Bob Jones"

core_section C06
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
core C06.1 "$(q "SELECT COUNT(*) FROM mart_customers WHERE customer_ref='C003'")" "1"
core C06.2 "$(q "SELECT email FROM mart_customers WHERE customer_ref='C003'")" "new@x.com"
later M04 "recency: one delivery -> one version" "$(versions C003)" "1"

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
core C08.1 "$(q "SELECT is_deleted FROM dim_customer WHERE customer_ref='C003' AND is_current=1")" "1"
core C08.2 "$(ans 1)" "C001"
core C08.3 "$(ans 2)" "C002,C003"
core C08.4 "$(ans 3)" "alice@example.com>alice@newmail.com"
later M04 "reconcile: C001 unchanged content -> NO new version (still 2)" "$(versions C001)" "2"
later M04 "reconcile: C002 already deleted -> no churn (still 2)"         "$(versions C002)" "2"

core_section C09
before_r="$(census)"
feed d5_cust_yearly_full.sql D5R '2027-01-10 08:00:00'
core C09.1 "$(census)" "$before_r"

core_section C10
core C10.1 "$(pq "SELECT (SELECT COUNT(*) FROM arch.hist_customer)+(SELECT COUNT(*) FROM arch.hist_product)
              +(SELECT COUNT(*) FROM arch.hist_order)+(SELECT COUNT(*) FROM arch.hist_order_line)")" \
           "$(pq "SELECT SUM(row_count) FROM arch.loaded_files")"
core_abort C10.2 "UPDATE hist_customer SET full_name='x';" "append-only"
core_abort C10.3 "DELETE FROM hist_order;" "append-only"

core_section C11
before_snap="$(snap)"
rm -f "$DB"                              # exactly what `make clean` does
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
core C11.1 "$(snap)" "$before_snap"

core_section C12
# The decode dimension is Type 1: one UPDATE relabels every fact at once.
q "UPDATE dim_order_status SET status_name='PLACED' WHERE status_code='P';" >/dev/null
core C12.1 "$(ans 9)" "O-100=PLACED,O-101=PLACED"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1
later M03 "  ...and rebuild resets it: schema seed is the source of truth" \
   "$(q "SELECT DISTINCT status FROM mart_orders")" "PENDING"

core_section C13
feed d6_repoint.sql D6 '2027-02-01 08:00:00' "$HERE/fixtures"
core C13.1 "$(ans 8)" "Alice Smith"
# The fact row is restated in place, so the star no longer holds O-101's
# earlier owner. The raw archive does, and the archive is the final answer.
core C13.2 "$(pq "SELECT group_concat(DISTINCT customer_ref) FROM arch.hist_order
                  WHERE order_ref='O-101' AND customer_ref<>'C001'")" "C002"
later M06 "repoint: fact row count unchanged (an UPDATE, not an insert)" \
   "$(q "SELECT COUNT(*) FROM fact_orders")" "2"
later M06 "repoint: O-101 now keyed to C001's current version" \
   "$(q "SELECT placed_by_at_purchase FROM mart_orders WHERE order_ref='O-101'")" "Alice Smith"
later M06 "repoint: prior pairing survives ONLY in the archive" \
   "$(pq "SELECT COUNT(*) FROM arch.hist_order WHERE order_ref='O-101' AND customer_ref='C002'")" "1"
before_d6r="$(census)"
feed d6_repoint.sql D6R '2027-02-15 08:00:00' "$HERE/fixtures"
later M06 "re-asserted repoint writes nothing" "$(census)" "$before_d6r"

core_section C14
core C14.1 "$(q "SELECT group_concat(customer_ref||'('||COALESCE(email,'null')||')',' ')
                 FROM (SELECT * FROM mart_customers ORDER BY customer_ref)")" "C001(alice@newmail.com)"

banner "2: MODEL  (what the Kimball star shows on its own)"

own_section M01 "Manifest and stage after every delivery"
replay M01
own_section M02 "Baseline values and the generated date dimension"
replay M02
own_section M03 "Decode dimension: raw code in the archive, Type 1 label in the mart"
replay M03
own_section M04 "SCD2 versioning with deleted-marker versions"
replay M04
own_section M05 "Frozen surrogate keys in the facts"
replay M05
own_section M06 "Re-point as a fact UPDATE"
replay M06

own_section M07 "Load control: a file_id names CONTENT (same block in all ten suites)"
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
