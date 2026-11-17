#!/usr/bin/env bash
# =====================================================================
# Kimball star test suite -- the shared delivery scenarios, replayed
# against SCD2 dimensions and a transactional fact, plus the
# Kimball-specific behaviours: frozen surrogate keys in facts, Type-1
# vs Type-2 change handling, in-place fact restatement, and a
# archive-backed rebuild that reproduces every surrogate key.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
# No `set -e`: every assertion must run so one failure doesn't hide the rest.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/kimball_test).db}"
export ARCHIVE_DB="${DB%.db}_archive.db"
PASS=0; FAIL=0; FEED_N=0; SKIPPED=0
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
ck(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1";
      else FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s  (got '%s', expected '%s')\n" "$1" "$2" "$3"; fi; }
ck_abort(){ local label="$1" sql="$2" want="$3" out
      out="$("$SQLITE" "$ARCHIVE_DB" "$sql" 2>&1)"
      case "$out" in *"$want"*) PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$label";;
        *) FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s  (got '%s')\n" "$label" "$out";; esac; }

census(){ q "SELECT group_concat(t||'='||n,' ') FROM (
    SELECT 1 o,'dim_cust' t,COUNT(*) n FROM dim_customer
    UNION ALL SELECT 2,'dim_prod',  COUNT(*) FROM dim_product
    UNION ALL SELECT 3,'fact_ord',  COUNT(*) FROM fact_orders
    UNION ALL SELECT 4,'fact_line', COUNT(*) FROM fact_order_lines
    ORDER BY o);"; }

# Full logical snapshot: every dim version (surrogate keys included) and
# every fact row. Rebuild must reproduce this byte-for-byte.
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
     "$(pq "SELECT COUNT(*) FROM arch.loaded_files WHERE file_id='$file_id'")" "1"
  [ "$SKIPPED" -eq 0 ] && ck "[$file_id] manifest: COMPLETE after all loaders" \
     "$(pq "SELECT status FROM arch.loaded_files WHERE file_id='$file_id'")" "COMPLETE"
  ck "[$file_id] stage blank after delivery" \
     "$(q "SELECT (SELECT COUNT(*) FROM stg_customer_l1)+(SELECT COUNT(*) FROM stg_product_l1)
                +(SELECT COUNT(*) FROM stg_order_l1)+(SELECT COUNT(*) FROM stg_order_line_l1)")" "0"; }

versions(){ q "SELECT COUNT(*) FROM dim_customer WHERE customer_ref='$1'"; }

echo "== Fresh db + archive =="; rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null

echo; echo "== D0: FULL baseline =="
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
ck "baseline: 2 customers current"  "$(q 'SELECT COUNT(*) FROM mart_customers')" "2"
ck "baseline: 3 products current"   "$(q 'SELECT COUNT(*) FROM mart_products')" "3"
ck "baseline: 2 facts, 3 lines"     "$(q "SELECT (SELECT COUNT(*) FROM fact_orders)||'/'||(SELECT COUNT(*) FROM fact_order_lines)")" "2/3"
ck "baseline: C001 email v1"        "$(q "SELECT email FROM mart_customers WHERE customer_ref='C001'")" "alice@example.com"
ck "baseline: dim_date generated"   "$(q "SELECT COUNT(*)>700 FROM dim_date")" "1"
ck "baseline: fact joins the calendar (O-100 -> Sunday)" \
   "$(q "SELECT d.weekday FROM fact_orders f JOIN dim_date d ON d.date_key=f.placed_date_key WHERE f.order_ref='O-100'")" "Sunday"
ck "decode dim: raw 'P' lives in archive, mart shows PENDING" \
   "$(pq "SELECT (SELECT DISTINCT status FROM arch.hist_order WHERE order_ref='O-100')||'/'||
                (SELECT status FROM mart_orders WHERE order_ref='O-100')")" "P/PENDING"

echo; echo "== D1: CRM 14-day INCREMENTAL window (C001 changed; C002 absent) =="
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
ck "SCD2: C001 now has 2 versions"             "$(versions C001)" "2"
ck "SCD2: exactly one is current"              "$(q "SELECT COUNT(*) FROM dim_customer WHERE customer_ref='C001' AND is_current=1")" "1"
ck "SCD2: old version expired at batch ts"     "$(q "SELECT row_exp_ts FROM dim_customer WHERE customer_ref='C001' AND is_current=0")" "2026-03-02 08:00:00"
ck "INCREMENTAL: C002 NOT deleted (60-day stale)" "$(q "SELECT COUNT(*) FROM mart_customers WHERE customer_ref='C002'")" "1"
ck "INCREMENTAL: C002 no version churn"        "$(versions C002)" "1"
ck "FROZEN KEY: O-100 fact still points at C001 v1" \
   "$(q "SELECT c.email FROM fact_orders f JOIN dim_customer c ON c.customer_key=f.customer_key WHERE f.order_ref='O-100'")" "alice@example.com"
ck "  ...while the current dim says newmail"   "$(q "SELECT email FROM mart_customers WHERE customer_ref='C001'")" "alice@newmail.com"

echo; echo "== D2: PIM FULL snapshot (SKU-3 discontinued) =="
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
ck "FULL: SKU-3 expired + deleted-marker version (2 rows)" \
   "$(q "SELECT COUNT(*) FROM dim_product WHERE sku='SKU-3'")" "2"
ck "FULL: SKU-3 current version flagged deleted" \
   "$(q "SELECT is_deleted FROM dim_product WHERE sku='SKU-3' AND is_current=1")" "1"
ck "FULL: SKU-3 gone from mart_products"     "$(q "SELECT COUNT(*) FROM mart_products WHERE sku='SKU-3'")" "0"
ck "FULL: SKU-3 last-known attrs preserved"  "$(q "SELECT product_name FROM dim_product WHERE sku='SKU-3' AND is_current=1")" "Gizmo"
ck "FULL: SKU-1 price 8.99 via new version"  "$(q "SELECT price FROM mart_products WHERE sku='SKU-1'")" "8.99"
ck "FULL: SKU-2 unchanged -> no churn"       "$(q "SELECT COUNT(*) FROM dim_product WHERE sku='SKU-2'")" "1"

echo; echo "== D3: INCREMENTAL tombstone deletes C002 =="
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
ck "tombstone: C002 current version is a deleted marker" \
   "$(q "SELECT is_deleted FROM dim_customer WHERE customer_ref='C002' AND is_current=1")" "1"
ck "tombstone: C002 gone from mart_customers" "$(q "SELECT COUNT(*) FROM mart_customers WHERE customer_ref='C002'")" "0"
ck "tombstone: last-known attrs carried onto the marker" \
   "$(q "SELECT customer_name FROM dim_customer WHERE customer_ref='C002' AND is_current=1")" "Bob Jones"
ck "POINT-IN-TIME: O-101 still answers 'Bob Jones' at purchase" \
   "$(q "SELECT placed_by_at_purchase FROM mart_orders WHERE order_ref='O-101'")" "Bob Jones"
ck "  ...and NULL for placed_by_current (matches the sibling demos)" \
   "$(q "SELECT COALESCE(placed_by_current,'<none>') FROM mart_orders WHERE order_ref='O-101'")" "<none>"

echo; echo "== D4: INCREMENTAL adds C003; recency de-dup at stage =="
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
ck "recency: newest email wins (not MAX)" "$(q "SELECT email FROM mart_customers WHERE customer_ref='C003'")" "new@x.com"
ck "recency: one delivery -> one version" "$(versions C003)" "1"

echo; echo "== Load control: re-deliver D1 (same file_id) must be skipped =="
before="$(census)"
feed d1_cust_win_day60.sql D1 '2026-04-10 08:00:00'
ck "dup file skipped: star unchanged" "$(census)" "$before"

echo; echo "== D5: YEARLY FULL reconciliation (C003 gone at source) =="
feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'
ck "reconcile: C003 deleted by absence (FULL)" \
   "$(q "SELECT is_deleted FROM dim_customer WHERE customer_ref='C003' AND is_current=1")" "1"
ck "reconcile: C001 unchanged content -> NO new version (still 2)" "$(versions C001)" "2"
ck "reconcile: C002 already deleted -> no churn (still 2)"         "$(versions C002)" "2"
ck "reconcile: mart shows only C001" "$(q "SELECT group_concat(customer_ref,',') FROM mart_customers")" "C001"

echo; echo "== True loader idempotence: same content, NEW file_id, writes nothing =="
before_r="$(census)"
feed d5_cust_yearly_full.sql D5R '2027-01-10 08:00:00'
ck "re-asserted current state writes zero star rows" "$(census)" "$before_r"

echo; echo "== Archive: append-only is absolute =="
ck "archive captured every delivered row" \
   "$(pq "SELECT (SELECT COUNT(*) FROM arch.hist_customer)+(SELECT COUNT(*) FROM arch.hist_product)
              +(SELECT COUNT(*) FROM arch.hist_order)+(SELECT COUNT(*) FROM arch.hist_order_line)")" \
   "$(pq "SELECT SUM(row_count) FROM arch.loaded_files")"
ck_abort "UPDATE on hist_customer aborts" "UPDATE hist_customer SET full_name='x';" "append-only"
ck_abort "DELETE on hist_order aborts"    "DELETE FROM hist_order;" "append-only"

echo; echo "== Rebuild: the star is disposable (archive is the truth) =="
before_snap="$(snap)"
rm -f "$DB"                              # exactly what `make clean` does
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
ck "clean+rebuild: star identical, SURROGATE KEYS included" "$(snap)" "$before_snap"

echo; echo "== Type 1 vs Type 2: the decode dim updates in place =="
q "UPDATE dim_order_status SET status_name='PLACED' WHERE status_code='P';" >/dev/null
ck "Type 1 change: every fact reads PLACED instantly, no reload" \
   "$(q "SELECT DISTINCT status FROM mart_orders")" "PLACED"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1
ck "  ...and rebuild resets it: schema seed is the source of truth" \
   "$(q "SELECT DISTINCT status FROM mart_orders")" "PENDING"

echo; echo "== Restatement: OMS re-points O-101 to C001 -> fact UPDATE in place =="
feed d6_repoint.sql D6 '2027-02-01 08:00:00' "$HERE/fixtures"
ck "repoint: fact row count unchanged (an UPDATE, not an insert)" \
   "$(q "SELECT COUNT(*) FROM fact_orders")" "2"
ck "repoint: O-101 now keyed to C001's current version" \
   "$(q "SELECT placed_by_at_purchase FROM mart_orders WHERE order_ref='O-101'")" "Alice Smith"
ck "repoint: prior pairing survives ONLY in the archive" \
   "$(pq "SELECT COUNT(*) FROM arch.hist_order WHERE order_ref='O-101' AND customer_ref='C002'")" "1"
before_d6r="$(census)"
feed d6_repoint.sql D6R '2027-02-15 08:00:00' "$HERE/fixtures"
ck "re-asserted repoint writes nothing" "$(census)" "$before_d6r"

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
printf "  RESULT: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "====================================================================="
rm -f "$DB" "$ARCHIVE_DB"
[ "$FAIL" -eq 0 ] || exit 1
