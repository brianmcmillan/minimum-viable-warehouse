#!/usr/bin/env bash
# =====================================================================
# RAW LAYER test suite -- proves the derived warehouse is disposable.
#
# The claim under test: every delivery ever accepted is captured verbatim
# and append-only, and replaying the archive regenerates the warehouse
# EXACTLY -- surrogate keys included. If that holds, a loader bug or a
# changed business rule is fixed by `make rebuild` rather than by a
# restore from backup.
#
#   ./tests/test_archive.sh     (or)   make test
# =====================================================================
# No `set -e`: every assertion must run so one failure doesn't hide the rest.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/focal_arch_test).db}"
export ARCHIVE_DB="${DB%.db}_archive.db"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

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
# Assert a statement is REJECTED, and by the message we expect.
ck_abort(){ local label="$1" sql="$2" want="$3" out
      out="$("$SQLITE" "$ARCHIVE_DB" "$sql" 2>&1)"
      case "$out" in *"$want"*) PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$label";;
        *) FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s  (got '%s')\n" "$label" "$out";; esac; }
feed(){  BATCH_TS="$3" "$PROJ/scripts/load_feed.sh" "$PROJ/source/$1" "$2" >/dev/null 2>&1; }
feedf(){ BATCH_TS="$3" "$PROJ/scripts/load_feed.sh" "$1" "$2" >/dev/null 2>&1; }
# Current value of C00n's email, straight from the descriptor table.
email(){ q "SELECT val_str FROM customer_desc
            WHERE type_key=11 AND customer_key=(SELECT customer_key FROM customer_idfr WHERE customer_idfr='$1')
            ORDER BY eff_tmstp DESC, ver_tmstp DESC LIMIT 1"; }

# Logical shape of the whole warehouse: keys, descriptors, links.
# Excludes popln_tmstp / inst_key / inst_row_key -- reassigned by definition.
snap(){ q "
  SELECT 'cidfr',customer_idfr,customer_key FROM customer_idfr
  UNION ALL SELECT 'pidfr',product_idfr,product_key FROM product_idfr
  UNION ALL SELECT 'oidfr',order_idfr,order_key FROM order_idfr
  UNION ALL SELECT 'cfocal',customer_key,row_st FROM customer_focal
  UNION ALL SELECT 'pfocal',product_key,row_st FROM product_focal
  UNION ALL SELECT 'ofocal',order_key,row_st FROM order_focal
  UNION ALL SELECT 'cdesc',customer_key||'/'||type_key||'/'||eff_tmstp||'/'||ver_tmstp,
      row_st||'/'||COALESCE(val_str,'')||'/'||COALESCE(val_num,'')||'/'||COALESCE(uom,'')||'/'||COALESCE(sta_tmstp,'') FROM customer_desc
  UNION ALL SELECT 'pdesc',product_key||'/'||type_key||'/'||eff_tmstp||'/'||ver_tmstp,
      row_st||'/'||COALESCE(val_str,'')||'/'||COALESCE(val_num,'')||'/'||COALESCE(uom,'') FROM product_desc
  UNION ALL SELECT 'odesc',order_key||'/'||type_key||'/'||eff_tmstp||'/'||ver_tmstp,
      row_st||'/'||COALESCE(val_str,'')||'/'||COALESCE(val_num,'')||'/'||COALESCE(uom,'') FROM order_desc
  UNION ALL SELECT 'ocx',order_key||'/'||customer_key||'/'||type_key||'/'||eff_tmstp,row_st FROM order_customer_x
  UNION ALL SELECT 'opx',order_key||'/'||product_key||'/'||type_key||'/'||eff_tmstp,row_st FROM order_product_x
  ORDER BY 1,2,3;"; }

demo(){ rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null 2>&1
  feed d0_baseline.sql        B0 '2026-02-05 08:00:00'
  feed d1_cust_win_day60.sql  D1 '2026-03-02 08:00:00'
  feed d2_prod_full_v2.sql    D2 '2026-03-02 09:00:00'
  feed d3_cust_tombstone.sql  D3 '2026-03-16 08:00:00'
  feed d4_cust_recency.sql    D4 '2026-04-02 08:00:00'
  feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'; }

echo "== Fresh warehouse + archive =="; demo

# ---------------------------------------------------------------- 1
echo; echo "== 1. The archive captured every delivery, verbatim =="
src_rows=$(grep -hc "^('" "$PROJ"/source/d*.sql | paste -sd+ - | bc)
ck "archive holds every staged row from every source file" \
   "$(aq 'SELECT COUNT(*) FROM arch.source_landing_history')" "$src_rows"
ck "6 deliveries recorded, all COMPLETE" \
   "$(aq "SELECT COUNT(*) FROM arch.loaded_files WHERE status='COMPLETE'")" "6"
ck "load_seq is dense and in ingest order" \
   "$(aq "SELECT group_concat(file_id,',') FROM (SELECT file_id FROM arch.loaded_files ORDER BY load_seq)")" \
   "B0,D1,D2,D3,D4,D5"
ck "raw value survives ingest-time translation ('P', not 'PENDING')" \
   "$(aq "SELECT DISTINCT value_str FROM arch.source_landing_history
          WHERE attribute_name='status' AND business_key='O-100'")" "P"

seq_before="$(aq "SELECT load_seq FROM arch.loaded_files WHERE file_id='D1'")"
rows_before="$(aq 'SELECT COUNT(*) FROM arch.source_landing_history')"
feed d1_cust_win_day60.sql D1 '2027-01-01 08:00:00'
ck "re-sending D1 archives zero new rows" \
   "$(aq 'SELECT COUNT(*) FROM arch.source_landing_history')" "$rows_before"
ck "re-sending D1 leaves load_seq unchanged" \
   "$(aq "SELECT load_seq FROM arch.loaded_files WHERE file_id='D1'")" "$seq_before"

# A file_id names a delivery's CONTENT. Reusing it for different content is
# the one hazard idempotent (INSERT OR IGNORE) archiving cannot detect itself.
cat > "$WORK/tamper.sql" <<'SQL'
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('CRM','CUSTOMER','C009','customer_ref','C009',NULL,NULL,'2027-01-01','UPSERT','INCREMENTAL');
SQL
out="$(BATCH_TS='2027-01-01 09:00:00' "$PROJ/scripts/load_feed.sh" "$WORK/tamper.sql" D1 2>&1)"; rc=$?
ck "reused file_id with different content is REJECTED" \
   "$([ "$rc" -ne 0 ] && echo rejected || echo accepted)" "rejected"
ck "  ...and says why" "$(printf '%s' "$out" | grep -c 'identifies a delivery' )" "1"

# ---------------------------------------------------------------- 2
echo; echo "== 2. Append-only is absolute (no unlock path exists) =="
ck_abort "UPDATE on source_landing_history aborts" \
  "UPDATE source_landing_history SET value_str='x';" "append-only"
ck_abort "DELETE on source_landing_history aborts" \
  "DELETE FROM source_landing_history;" "append-only"
ck "archive intact after both attempts" \
   "$(aq 'SELECT COUNT(*) FROM arch.source_landing_history')" "$rows_before"

# ---------------------------------------------------------------- 3
echo; echo "== 3. Rebuild reproduces the warehouse exactly (keys included) =="
# INGESTED is the ground truth: what the loaders built from the delivery
# files themselves. Every rebuild below is compared against THAT, never
# against a previous rebuild -- a deterministically-wrong replay would
# agree with itself and sail through.
demo
ingested="$(snap)"
ingested_keys="$(q "SELECT group_concat(customer_idfr||'='||customer_key,',')
                    FROM (SELECT * FROM customer_idfr ORDER BY customer_idfr)")"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
ck "rebuild: warehouse is identical, surrogate keys and all" "$(snap)" "$ingested"
# Smoke check, NOT a regression test for the inst_key gate that load_keys.sh
# drops. Under genesis replay *_idfr starts empty, so that gate matches and
# _focal populates either way -- reinstating it does not fail this suite.
# It only bites where something seeds *_idfr before replaying, which nothing
# here does. Removing it is hardening; do not claim coverage we do not have.
ck "rebuild: focal rows repopulated" \
   "$(q 'SELECT COUNT(*) FROM customer_focal')" "3"
ck "rebuild: lineage regenerated, not carried over" \
   "$(q "SELECT CASE WHEN COUNT(*)>0 THEN 'yes' ELSE 'no' END FROM meta_procinst")" "yes"

# ---------------------------------------------------------------- 4
echo; echo "== 4. Keys are DERIVED, not preserved: clean + rebuild =="
rm -f "$DB"                       # exactly what `make clean` does to build/
ck "focal.db really is gone" "$([ -f "$DB" ] && echo present || echo gone)" "gone"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
ck "clean+rebuild: same keys as INGEST, from the archive alone" \
   "$(q "SELECT group_concat(customer_idfr||'='||customer_key,',')
         FROM (SELECT * FROM customer_idfr ORDER BY customer_idfr)")" \
   "$ingested_keys"
ck "clean+rebuild: warehouse identical to INGEST" "$(snap)" "$ingested"

# ---------------------------------------------------------------- 5
echo; echo "== 5. Replay order is load-bearing =="
ck "rebuild.sh replays ORDER BY load_seq" \
   "$(grep -c 'ORDER BY load_seq' "$PROJ/scripts/rebuild.sh")" "1"
ck "load_keys.sh iterates feeds deterministically" \
   "$(grep -c 'ORDER BY m.entity_id' "$PROJ/scripts/load_keys.sh")" "1"
# The hazard the ORDER BY prevents: keys follow arrival order.
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null 2>&1
feed d4_cust_recency.sql D4 '2026-01-01 00:00:00'
feed d0_baseline.sql     B0 '2026-02-05 08:00:00'
ck "out-of-order replay WOULD misassign keys (C003 -> 1001, not 1003)" \
   "$(q "SELECT customer_key FROM customer_idfr WHERE customer_idfr='C003'")" "1001"

# ---------------------------------------------------------------- 6
echo; echo "== 6. Recency dedup survives replay (stage restored in seq_nbr order) =="
demo
# (a) recency by extract_ts -- settled before rowid is ever consulted.
ck "ingest: newest email by extract_ts wins" "$(email C003)" "new@x.com"
# (b) the tiebreak that actually depends on physical row order: two values,
#     one extract_ts. Only the last row in the file may win. This is the case
#     seq_nbr exists for, and d4 cannot cover it.
feedf "$HERE/fixtures/d6_tiebreak.sql" D6 '2027-02-01 08:00:00'
ck "ingest: equal extract_ts -> last row in the file wins" "$(email C004)" "last@x.com"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1
ck "after rebuild: extract_ts recency preserved"  "$(email C003)" "new@x.com"
ck "after rebuild: rowid tiebreak preserved"      "$(email C004)" "last@x.com"

# ---------------------------------------------------------------- 7
echo; echo "== 7. Business rules re-derive from raw values =="
# rebuild.sh re-seeds metadata from schema/, so a rule change is an edit to
# the seed -- not an UPDATE that the next rebuild would discard. Exercise it
# in a throwaway copy of the project.
cp -R "$PROJ" "$WORK/proj"
rm -rf "$WORK/proj/build" "$WORK/proj/archive"
(
  export DB="$WORK/proj/build/focal.db" ARCHIVE_DB="$WORK/proj/archive/a.db"
  "$WORK/proj/scripts/init_db.sh" >/dev/null 2>&1
  BATCH_TS='2026-02-05 08:00:00' "$WORK/proj/scripts/load_feed.sh" "$WORK/proj/source/d0_baseline.sql" B0 >/dev/null 2>&1
  before_status="$("$SQLITE" "$DB" "SELECT status FROM v_order WHERE order_ref='O-100'")"
  # The rule changes. The raw 'P' in the archive does not.
  sed -i.bak "s/(30,'P','PENDING')/(30,'P','PLACED')/" "$WORK/proj/schema/03_seed_metadata.sql"
  "$WORK/proj/scripts/rebuild.sh" >/dev/null 2>&1
  after_status="$("$SQLITE" "$DB" "SELECT status FROM v_order WHERE order_ref='O-100'")"
  echo "$before_status|$after_status" > "$WORK/rule.txt"
)
ck "changed meta_value_map is applied retroactively (PENDING -> PLACED)" \
   "$(cat "$WORK/rule.txt")" "PENDING|PLACED"

# ---------------------------------------------------------------- 8
echo; echo "== 8. Delete semantics survive replay, not just row counts =="
demo
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1
ck "replay: SKU-3 still deleted by FULL absence" \
   "$(q "SELECT row_st FROM product_desc WHERE product_key=(SELECT product_key FROM product_idfr WHERE product_idfr='SKU-3')
         AND type_key=20 ORDER BY eff_tmstp DESC, ver_tmstp DESC LIMIT 1")" "N"
ck "replay: C002 still deleted by tombstone" \
   "$(q "SELECT COALESCE(email,'<none>') FROM v_customer WHERE customer_ref='C002'")" "<none>"
ck "replay: C003 still reconciled away by the yearly FULL" \
   "$(q "SELECT row_st FROM customer_desc WHERE customer_key=(SELECT customer_key FROM customer_idfr WHERE customer_idfr='C003')
         AND type_key=11 ORDER BY eff_tmstp DESC, ver_tmstp DESC LIMIT 1")" "N"
ck "replay: C001 survives with its updated email" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@newmail.com"

# ---------------------------------------------------------------- 9
echo; echo "== 9. archive-status reports and deletes nothing =="
rows="$(aq 'SELECT COUNT(*) FROM arch.source_landing_history')"
out="$("$PROJ/scripts/archive_status.sh" 2>&1)"; rc=$?
ck "archive_status.sh exits 0" "$rc" "0"
ck "  ...reports the per-feed breakdown" "$(printf '%s' "$out" | grep -c 'rows_per_delivery')" "1"
ck "  ...and deleted nothing" "$(aq 'SELECT COUNT(*) FROM arch.source_landing_history')" "$rows"

# ---------------------------------------------------------------- 10
echo; echo "== 10. demo is repeatable (fresh archive each time) =="
demo; census_1="$(snap)"
demo; ck "second demo yields the same warehouse" "$(snap)" "$census_1"

echo; echo "====================================================================="
printf "  RESULT: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "====================================================================="
rm -f "$DB" "$ARCHIVE_DB"
[ "$FAIL" -eq 0 ] || exit 1
