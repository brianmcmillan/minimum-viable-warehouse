#!/usr/bin/env bash
# =====================================================================
# Data Vault 2.0 test suite -- the Focal demo's scenarios, replayed
# against a vault. Same deliveries, same safety rule (absence deletes
# only under FULL), plus the DV-specific behaviours: whole-row satellite
# grain, raw values preserved under soft rules, and driving-key
# effectivity on links, and the raw-layer archive: append-only, replayed
# by `make rebuild` into an identical vault. Pure shell + sqlite3.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
# No `set -e`: every assertion must run so one failure doesn't hide the rest.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/dv_test).db}"
export ARCHIVE_DB="${DB%.db}_archive.db"
PASS=0; FAIL=0; FEED_N=0; SKIPPED=0
LOGDIR="$(mktemp -d)"; trap 'rm -rf "$LOGDIR"' EXIT

q(){ local out rc=0
     out="$("$SQLITE" "$DB" "$1" 2>&1)" || rc=$?
     if [ "$rc" -ne 0 ]; then
       printf "  \033[31mSQL ERROR\033[0m (exit %d): %s\n    query: %s\n" "$rc" "$out" "$1" >&2
       printf '<SQL-ERROR>'; return 0
     fi
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

# Row census across every vault table, compared as one string so a
# failure names the table that grew. Hub and satellite counts exclude the
# reserved keys '0', '-1' and '-2' (written at init, not by a delivery).
census(){ q "SELECT group_concat(t||'='||n,' ') FROM (
    SELECT 1 o,'cust_h'   t,COUNT(*) n FROM rv_customer_h WHERE customer_bk NOT IN ('0','-1','-2')
    UNION ALL SELECT 2,'cust_hsat', COUNT(*) FROM rv_customer_hsat WHERE customer_bk NOT IN ('0','-1','-2')
    UNION ALL SELECT 3,'cust_sts',  COUNT(*) FROM rv_customer_sts WHERE customer_bk NOT IN ('0','-1','-2')
    UNION ALL SELECT 4,'prod_h',    COUNT(*) FROM rv_product_h WHERE product_bk NOT IN ('0','-1','-2')
    UNION ALL SELECT 5,'prod_hsat', COUNT(*) FROM rv_product_hsat WHERE product_bk NOT IN ('0','-1','-2')
    UNION ALL SELECT 6,'prod_sts',  COUNT(*) FROM rv_product_sts WHERE product_bk NOT IN ('0','-1','-2')
    UNION ALL SELECT 7,'ord_h',     COUNT(*) FROM rv_order_h WHERE order_bk NOT IN ('0','-1','-2')
    UNION ALL SELECT 8,'ord_hsat',  COUNT(*) FROM rv_order_hsat WHERE order_bk NOT IN ('0','-1','-2')
    UNION ALL SELECT 9,'ord_sts',   COUNT(*) FROM rv_order_sts WHERE order_bk NOT IN ('0','-1','-2')
    UNION ALL SELECT 10,'oc_l',     COUNT(*) FROM rv_order_customer_l
    UNION ALL SELECT 11,'op_l',     COUNT(*) FROM rv_order_product_l
    UNION ALL SELECT 12,'oc_eff',   COUNT(*) FROM bv_order_customer_l_effsat
    ORDER BY o);"; }

# Every rv_* and bv_* table, as the list of names the schema defines.
vault_tables(){ q "SELECT name FROM sqlite_master WHERE type='table'
                   AND (name LIKE 'rv\_%' ESCAPE '\' OR name LIKE 'bv\_%' ESCAPE '\')
                   ORDER BY name"; }
# Vault objects outside the rv_*/bv_* table list: the reference table and
# every bv_ view.
extra_objects(){ q "SELECT name FROM sqlite_master WHERE (type='table' AND name LIKE 'ref\_%' ESCAPE '\')
                    OR (type='view' AND name LIKE 'bv\_%' ESCAPE '\') ORDER BY name"; }
# Full content of one table, every column, in a total order (ORDER BY each
# column position), so two dumps are equal only if the rows are.
dump(){ q "SELECT * FROM $1 ORDER BY $(q "SELECT group_concat(cid+1,',') FROM pragma_table_info('$1')")"; }
# Snapshot every vault table, `make rebuild` from the archive, compare
# table by table. $1 labels the assertions.
rebuild_check(){ local label="$1" t tables want rc=0 snapdir="$LOGDIR/snap-$FEED_N"
  mkdir -p "$snapdir"; tables="$(vault_tables)"; extra="$(extra_objects)"
  for t in $tables $extra; do dump "$t" > "$snapdir/$t"; done
  rm -f "$DB"
  make -s -C "$PROJ" rebuild >"$LOGDIR/rebuild-$FEED_N.log" 2>&1 || rc=$?
  ck "[$label] make rebuild exits 0" "$rc" "0"
  ck "[$label] rebuilt vault has the same rv_*/bv_* tables" "$(vault_tables)" "$tables"
  for t in $tables; do
    # An empty or errored snapshot can never match: equal errors are not equal tables.
    want="$(cat "$snapdir/$t")"
    case "$want" in ''|*'<SQL-ERROR>'*) want="<no valid snapshot of $t>";; esac
    ck "[$label] $t reproduced row for row ($(grep -c "" "$snapdir/$t") rows)" \
       "$(dump "$t")" "$want"
  done
  # The reference table and the business vault's views (the computed
  # status satellite) are rebuilt too; snapshots were taken above.
  for t in $extra; do
    want="$(cat "$snapdir/$t")"
    case "$want" in ''|*'<SQL-ERROR>'*) want="<no valid snapshot of $t>";; esac
    ck "[$label] $t reproduced row for row ($(grep -c "" "$snapdir/$t") rows)" \
       "$(dump "$t")" "$want"
  done; }

# ---- reserved keys, CPIT tables, bridge -------------------------------
RES="('0','-1','-2')"
GHOST_TS='1900-01-01 00:00:00'
# Every hub holds exactly the three reserved rows, every raw satellite
# exactly one ghost row, all written at init with the BASELINE- sources.
reserved_check(){ local label="$1" e k t want
  for e in customer product order; do k="${e}_bk"
    for t in "rv_${e}_h" "rv_${e}_hsat" "rv_${e}_sts"; do
      case "$t" in
        *_h) want="-1=BASELINE-nullkey-required@$GHOST_TS,-2=BASELINE-nullkey-optional@$GHOST_TS,0=BASELINE-ghostrec@$GHOST_TS";;
        *)   want="0=BASELINE-ghostrec@$GHOST_TS";;
      esac
      ck "[$label] $t holds exactly its reserved rows" \
         "$(q "SELECT group_concat(k||'='||rsrc||'@'||ldts, ',') FROM
                 (SELECT $k k, rsrc, ldts FROM $t WHERE $k IN $RES ORDER BY k)")" "$want"
    done
  done; }
# CPIT invariants for one entity: one row per real hub key, no NULL
# pointer, every non-ghost pointer at the newest row of its satellite,
# every ghost pointer only where the key has no row there.
ptr_bad(){ local e="$1" k="$1_bk" sat="$2" col="$3"   # col: hsat | sts
  q "SELECT COUNT(*) FROM bv_${e}_cpit p WHERE NOT (
       (p.${col}_bk = p.$k AND p.${col}_ldts =
          (SELECT MAX(ldts) FROM $sat x WHERE x.$k = p.$k))
    OR (p.${col}_bk = '0' AND p.${col}_ldts = '$GHOST_TS'
        AND NOT EXISTS (SELECT 1 FROM $sat x WHERE x.$k = p.$k)))"; }
cpit_check(){ local label="$1" e k
  for e in customer product order; do k="${e}_bk"
    ck "[$label] bv_${e}_cpit: exactly one row per real hub key" \
       "$(q "SELECT (SELECT COUNT(*) FROM bv_${e}_cpit) = (SELECT COUNT(*) FROM rv_${e}_h WHERE $k NOT IN $RES)
                AND NOT EXISTS (SELECT $k FROM rv_${e}_h WHERE $k NOT IN $RES
                                EXCEPT SELECT $k FROM bv_${e}_cpit)")" "1"
    ck "[$label] bv_${e}_cpit: no NULL pointer" \
       "$(q "SELECT COUNT(*) FROM bv_${e}_cpit p WHERE $(q "SELECT group_concat('p.'||name||' IS NULL',' OR ')
              FROM pragma_table_info('bv_${e}_cpit')")")" "0"
    ck "[$label] bv_${e}_cpit: hsat pointers at the newest row, or the ghost" "$(ptr_bad "$e" "rv_${e}_hsat" hsat)" "0"
    ck "[$label] bv_${e}_cpit: sts pointers at the newest row, or the ghost"  "$(ptr_bad "$e" "rv_${e}_sts"  sts)"  "0"
  done
  ck "[$label] bv_order_cpit: effectivity pointer at the current pairing, or the ghost" \
     "$(q "SELECT COUNT(*) FROM bv_order_cpit p WHERE NOT (
             (p.eff_customer_bk, p.eff_ldts) IN
               (SELECT customer_bk, ldts FROM bv_order_customer_l_effsat e WHERE e.order_bk = p.order_bk
                ORDER BY start_date DESC, ldts DESC LIMIT 1)
          OR (p.eff_customer_bk = '0' AND p.eff_ldts = '$GHOST_TS'
              AND NOT EXISTS (SELECT 1 FROM bv_order_customer_l_effsat e WHERE e.order_bk = p.order_bk)))")" "0"
  ck "[$label] bv_order_bridge: one row per order line" \
     "$(q "SELECT (SELECT COUNT(*) FROM bv_order_bridge) = (SELECT COUNT(*) FROM rv_order_product_l)
              AND NOT EXISTS (SELECT order_bk, product_bk FROM rv_order_product_l
                              EXCEPT SELECT order_bk, product_bk FROM bv_order_bridge)")" "1"
  ck "[$label] bv_order_bridge: each line carries its order's current customer, or '0'" \
     "$(q "SELECT COUNT(*) FROM bv_order_bridge b WHERE b.customer_bk <>
             COALESCE((SELECT customer_bk FROM v_order_customer_current c WHERE c.order_bk = b.order_bk), '0')")" "0"; }
# Every info-mart and audit view, with its key column(s).
MART_KEYS="dim_customer:customer_ref dim_product:sku fact_order:order_ref
  v_customer_hsat_current:customer_bk v_product_hsat_current:product_bk v_order_hsat_current:order_bk
  v_customer_sts_current:customer_bk v_product_sts_current:product_bk v_order_sts_current:order_bk
  v_order_status_history:order_ref v_status_history:business_key"
# UPDATE / DELETE against the vault database must abort.
ck_abort_db(){ local label="$1" sql="$2" want="$3" out
      out="$("$SQLITE" "$DB" "$sql" 2>&1)"
      case "$out" in *"$want"*) PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$label";;
        *) FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s  (got '%s')\n" "$label" "$out";; esac; }

# Run one delivery; abort the suite if a loader crashes (past that point
# every assertion measures a half-loaded database, not the code).
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
  # Standing invariant: a delivery that returned success left the stage
  # blank. Residue after exit 0 would mean either the success-clear was
  # lost, or a failure was misreported as success.
  ck "[$file_id] stage blank after delivery" \
     "$(q "SELECT (SELECT COUNT(*) FROM stg_customer_l1)+(SELECT COUNT(*) FROM stg_product_l1)
                +(SELECT COUNT(*) FROM stg_order_l1)+(SELECT COUNT(*) FROM stg_order_line_l1)")" "0"; }

sts(){ q "SELECT sts FROM v_customer_sts_current WHERE customer_bk='$1'"; }

echo "== Fresh db + archive =="; rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null

echo; echo "== Reserved keys: written at init, before any delivery =="
reserved_check "init"

echo; echo "== D0: FULL baseline =="
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
ck "baseline: 2 customer keys"   "$(q "SELECT COUNT(*) FROM rv_customer_h WHERE customer_bk NOT IN ('0','-1','-2')")" "2"
ck "baseline: 3 product keys"    "$(q "SELECT COUNT(*) FROM rv_product_h WHERE product_bk NOT IN ('0','-1','-2')")" "3"
ck "baseline: 2 order keys"      "$(q "SELECT COUNT(*) FROM rv_order_h WHERE order_bk NOT IN ('0','-1','-2')")" "2"
ck "baseline: C001 email v1"     "$(q "SELECT email FROM dim_customer WHERE customer_ref='C001'")" "alice@example.com"
ck "baseline: 2 current order->customer pairings" \
   "$(q 'SELECT COUNT(*) FROM v_order_customer_current')" "2"
ck "RAW: vault stores source code 'P', mart translates" \
   "$(q "SELECT (SELECT status FROM rv_order_hsat WHERE order_bk='O-100')||'/'||
              (SELECT status FROM fact_order WHERE order_ref='O-100')")" "P/PENDING"

echo; echo "== D1: CRM 14-day INCREMENTAL window (C001 changed; C002 absent) =="
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
ck "INCREMENTAL: C001 email updated"              "$(q "SELECT email FROM dim_customer WHERE customer_ref='C001'")" "alice@newmail.com"
ck "INCREMENTAL: C002 NOT deleted (60-day stale)" "$(sts C002)" "I"
ck "INCREMENTAL: C002 email unchanged"            "$(q "SELECT email FROM dim_customer WHERE customer_ref='C002'")" "bob@example.com"
ck "INCREMENTAL: C002 no sat churn (1 row)"       "$(q "SELECT COUNT(*) FROM rv_customer_hsat WHERE customer_bk='C002'")" "1"
ck "grain: C001 change = ONE whole-row sat version (2 total)" \
   "$(q "SELECT COUNT(*) FROM rv_customer_hsat WHERE customer_bk='C001'")" "2"

echo; echo "== D2: PIM FULL snapshot (SKU-3 discontinued) =="
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
ck "FULL: SKU-3 deleted on absence (sts='D')" \
   "$(q "SELECT sts FROM v_product_sts_current WHERE product_bk='SKU-3'")" "D"
ck "FULL: SKU-3 hub key remains (insert-only)" \
   "$(q "SELECT COUNT(*) FROM rv_product_h WHERE product_bk='SKU-3'")" "1"
ck "FULL: SKU-3 history remains in its satellite" \
   "$(q "SELECT COUNT(*) FROM rv_product_hsat WHERE product_bk='SKU-3'")" "1"
ck "FULL: SKU-3 gone from dim_product" \
   "$(q "SELECT COUNT(*) FROM dim_product WHERE sku='SKU-3'")" "0"
ck "FULL: SKU-1 price changed 8.99"  "$(q "SELECT price FROM dim_product WHERE sku='SKU-1'")" "8.99"
ck "FULL: SKU-2 unchanged -> hashdiff wrote nothing (1 row)" \
   "$(q "SELECT COUNT(*) FROM rv_product_hsat WHERE product_bk='SKU-2'")" "1"

echo; echo "== D3: INCREMENTAL tombstone deletes C002 =="
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
ck "tombstone: C002 sts='D'"                "$(sts C002)" "D"
ck "tombstone: C002 gone from dim_customer" "$(q "SELECT COALESCE((SELECT email FROM dim_customer WHERE customer_ref='C002'),'<none>')")" "<none>"
ck "tombstone: O-101 placed_by now NULL"    "$(q "SELECT COALESCE((SELECT placed_by FROM fact_order WHERE order_ref='O-101'),'<none>')")" "<none>"
ck "tombstone: C002 attribute history intact" \
   "$(q "SELECT full_name FROM rv_customer_hsat WHERE customer_bk='C002'")" "Bob Jones"
ck "CPIT: deleted C002 keeps its row, its sts pointer names the 'D' row" \
   "$(q "SELECT st.sts||'@'||st.ldts FROM bv_customer_cpit p
          JOIN rv_customer_sts st ON st.customer_bk = p.sts_bk AND st.ldts = p.sts_ldts
         WHERE p.customer_bk='C002'")" "D@2026-03-16 08:00:00"

echo; echo "== D4: INCREMENTAL adds C003; recency de-dup at stage 2 =="
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
ck "recency: newest email wins (not MAX)" "$(q "SELECT email FROM dim_customer WHERE customer_ref='C003'")" "new@x.com"
ck "recency: one delivery -> one sat row" "$(q "SELECT COUNT(*) FROM rv_customer_hsat WHERE customer_bk='C003'")" "1"

echo; echo "== Load control: re-deliver D1 (same file_id) must be skipped =="
before="$(census)"
feed d1_cust_win_day60.sql D1 '2026-04-10 08:00:00'
ck "dup file skipped: vault unchanged" "$(census)" "$before"

echo; echo "== D5: YEARLY FULL reconciliation (C003 gone at source) =="
feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'
ck "reconcile: C003 deleted by absence (FULL)" "$(sts C003)" "D"
ck "reconcile: C001 survives"                  "$(q "SELECT email FROM dim_customer WHERE customer_ref='C001'")" "alice@newmail.com"
ck "reconcile: C002 stays deleted"             "$(sts C002)" "D"
ck "reconcile: C001 unchanged content -> NO new sat row (still 2)" \
   "$(q "SELECT COUNT(*) FROM rv_customer_hsat WHERE customer_bk='C001'")" "2"

echo; echo "== Contrast: absence deletes under FULL, never under INCREMENTAL =="
ck "C002 presence timeline is exactly I -> D (2 assertions)" \
   "$(q "SELECT group_concat(sts,'') FROM (SELECT sts FROM rv_customer_sts WHERE customer_bk='C002' ORDER BY ldts)")" "ID"

echo; echo "== Query assistance after D5: CPIT and bridge =="
cpit_check "after D5"

echo; echo "== Raw vault: insert-only, enforced =="
for t in $(q "SELECT name FROM sqlite_master WHERE type='table'
              AND (name LIKE 'rv\_%' ESCAPE '\' OR name LIKE 'ref\_%' ESCAPE '\'
                   OR name = 'bv_order_customer_l_effsat') ORDER BY name"); do
  ck_abort_db "UPDATE on $t aborts" "UPDATE $t SET ldts=ldts;" "insert-only"
  ck_abort_db "DELETE on $t aborts" "DELETE FROM $t;"          "insert-only"
done
ck "only the bv_ query-assist tables can be rewritten" \
   "$(q "SELECT group_concat(name,' ') FROM (SELECT name FROM sqlite_master m WHERE type='table'
          AND (name LIKE 'rv\_%' ESCAPE '\' OR name LIKE 'bv\_%' ESCAPE '\' OR name LIKE 'ref\_%' ESCAPE '\')
          AND NOT EXISTS (SELECT 1 FROM sqlite_master t WHERE t.type='trigger' AND t.tbl_name=m.name
                          AND t.name=m.name||'_no_update')
          AND NOT EXISTS (SELECT 1 FROM sqlite_master t WHERE t.type='trigger' AND t.tbl_name=m.name
                          AND t.name=m.name||'_no_delete') ORDER BY name)")" \
   "bv_customer_cpit bv_order_bridge bv_order_cpit bv_product_cpit"
ck_abort_db "a loader-style insert of a reserved hub key aborts" \
   "INSERT INTO rv_customer_h VALUES ('0','2027-01-01 00:00:00','CRM.CUSTOMER');" "reserved key"
ck_abort_db "a loader-style ghost-key satellite row aborts" \
   "INSERT INTO rv_customer_hsat(customer_bk,ldts,rsrc,diff_str) VALUES ('0','2027-01-01 00:00:00','CRM.CUSTOMER','x');" "reserved key"

echo; echo "== Archive: append-only is absolute =="
ck "archive captured every delivered row" \
   "$(aq "SELECT (SELECT COUNT(*) FROM arch.hist_customer)+(SELECT COUNT(*) FROM arch.hist_product)
              +(SELECT COUNT(*) FROM arch.hist_order)+(SELECT COUNT(*) FROM arch.hist_order_line)")" \
   "$(aq 'SELECT SUM(row_count) FROM arch.loaded_files')"
for t in hist_customer hist_product hist_order hist_order_line; do
  ck_abort "UPDATE on $t aborts" "UPDATE $t SET op=op;" "append-only"
  ck_abort "DELETE on $t aborts" "DELETE FROM $t;"      "append-only"
done

echo; echo "== Rebuild after the six deliveries: the vault is disposable =="
rebuild_check "six deliveries"

echo; echo "== Idempotence: replaying the whole sequence must change nothing =="
census_0="$(census)"
feed d0_baseline.sql         B0 '2027-01-05 08:00:00'
feed d1_cust_win_day60.sql   D1 '2027-01-05 08:01:00'
feed d2_prod_full_v2.sql     D2 '2027-01-05 08:02:00'
feed d3_cust_tombstone.sql   D3 '2027-01-05 08:03:00'
feed d4_cust_recency.sql     D4 '2027-01-05 08:04:00'
feed d5_cust_yearly_full.sql D5 '2027-01-05 08:05:00'
ck "replay: zero new vault rows" "$(census)" "$census_0"
reserved_check "after the full replay"

echo; echo "== Driving key: OMS re-points O-101 from C002 to C001 =="
feed d6_repoint.sql D6 '2027-02-01 08:00:00' "$HERE/fixtures"
ck "repoint: O-101 current customer is C001" \
   "$(q "SELECT customer_bk FROM v_order_customer_current WHERE order_bk='O-101'")" "C001"
ck "repoint: exactly ONE current pairing for O-101" \
   "$(q "SELECT COUNT(*) FROM v_order_customer_eff_history WHERE order_bk='O-101' AND iscurrent=1")" "1"
ck "repoint: old pairing end-dated by LEAD, not updated" \
   "$(q "SELECT end_date FROM v_order_customer_eff_history WHERE order_bk='O-101' AND customer_bk='C002'")" "2027-02-01 08:00:00"
ck "repoint: link table keeps BOTH pairs (insert-only history)" \
   "$(q "SELECT COUNT(*) FROM rv_order_customer_l WHERE order_bk='O-101'")" "2"
ck "repoint: placed_by resolves to Alice Smith" \
   "$(q "SELECT placed_by FROM fact_order WHERE order_ref='O-101'")" "Alice Smith"
ck "repoint: unchanged order attrs -> no new sat row" \
   "$(q "SELECT COUNT(*) FROM rv_order_hsat WHERE order_bk='O-101'")" "1"
ck "repoint: CPIT effectivity pointer is C001, opened by D6" \
   "$(q "SELECT eff_customer_bk||'@'||eff_ldts FROM bv_order_cpit WHERE order_bk='O-101'")" "C001@2027-02-01 08:00:00"
ck "repoint: bridge carries O-101's line under C001 only" \
   "$(q "SELECT group_concat(product_bk||'>'||customer_bk) FROM bv_order_bridge WHERE order_bk='O-101'")" "SKU-2>C001"
cpit_check "after D6"

echo; echo "== True loader idempotence: same content, NEW file_id, loaders RUN, write nothing =="
# The earlier replay block proves the skip guard (same file_id -> loaders
# never run). This proves the loaders themselves: D6's content re-asserts
# the current state, so every delta -- hub, sat, sts, link, effsat -- must
# come up empty. This is the test that catches an effsat that re-opens an
# already-current pairing.
before_d6r="$(census)"
feed d6_repoint.sql D6R '2027-02-15 08:00:00' "$HERE/fixtures"
ck "re-asserted current state writes zero vault rows" "$(census)" "$before_d6r"

echo; echo "== Rebuild after D6/D6R, then the soft-rule test on the rebuilt vault =="
rebuild_check "after D6R"

echo; echo "== D7: an order with no customer, and a customer with no satellite row =="
feed d7_null_customer.sql D7 '2027-03-01 08:00:00' "$HERE/fixtures"
ck "null customer_ref: O-102 linked to the required-null key '-1'" \
   "$(q "SELECT group_concat(customer_bk) FROM rv_order_customer_l WHERE order_bk='O-102'")" "-1"
ck "null customer_ref: O-102's current pairing is '-1'" \
   "$(q "SELECT customer_bk FROM v_order_customer_current WHERE order_bk='O-102'")" "-1"
ck "null customer_ref: O-102 is in the mart, placed by nobody" \
   "$(q "SELECT order_ref||'/'||COALESCE(placed_by,'<none>') FROM fact_order WHERE order_ref='O-102'")" "O-102/<none>"
ck "null customer_ref: no '-1' row in dim_customer" \
   "$(q "SELECT COUNT(*) FROM dim_customer WHERE customer_ref='-1'")" "0"
ck "null customer_ref: bridge carries O-102's line under '-1'" \
   "$(q "SELECT product_bk||'>'||customer_bk FROM bv_order_bridge WHERE order_bk='O-102'")" "SKU-1>-1"
ck "no satellite row: C900 (a link end only) has a CPIT row on the ghost" \
   "$(q "SELECT hsat_bk||'@'||hsat_ldts||' '||sts_bk||'@'||sts_ldts FROM bv_customer_cpit WHERE customer_bk='C900'")" \
   "0@$GHOST_TS 0@$GHOST_TS"
ck "no satellite row: C900 stays out of dim_customer" \
   "$(q "SELECT COUNT(*) FROM dim_customer WHERE customer_ref='C900'")" "0"
cpit_check "after D7"
reserved_check "after D7"
for vk in $MART_KEYS; do
  ck "no reserved key in ${vk%%:*}" \
     "$(q "SELECT COUNT(*) FROM ${vk%%:*} WHERE ${vk#*:} IN $RES")" "0"
done
rebuild_check "after D7"

echo; echo "== Soft rule change: retroactive without any reload =="
q "UPDATE dv_load_params SET batch_ts=batch_ts" >/dev/null   # no-op; vault untouched below
ck "raw 'P' still in the vault"          "$(q "SELECT status FROM rv_order_hsat WHERE order_bk='O-100'")" "P"
ck "mart derives PENDING from it today"  "$(q "SELECT status FROM fact_order WHERE order_ref='O-100'")" "PENDING"
ck "the decode is a view (bv_order_status_bsat), not a stored table" \
   "$(q "SELECT type FROM sqlite_master WHERE name='bv_order_status_bsat'")" "view"
ck "the mart holds no decode of its own" \
   "$(q "SELECT COUNT(*) FROM sqlite_master WHERE type='view' AND name IN ('dim_customer','dim_product','fact_order','v_order_status_history')
          AND (sql LIKE '%PENDING%' OR sql LIKE '%CASE%')")" "0"
census_r="$(census)"; files_r="$(aq 'SELECT COUNT(*) FROM arch.loaded_files')"
q "INSERT INTO ref_order_status(code,label,ldts,rsrc) VALUES ('P','AWAITING SHIPMENT','2027-04-01 00:00:00','OPS.RULES')" >/dev/null
ck "new reference row: O-100 reads AWAITING SHIPMENT in the mart" \
   "$(q "SELECT status FROM fact_order WHERE order_ref='O-100'")" "AWAITING SHIPMENT"
ck "new reference row: every historical 'P' row is relabelled" \
   "$(q "SELECT COUNT(*) FROM v_order_status_history WHERE raw_status='P' AND status<>'AWAITING SHIPMENT'")/$(q "SELECT COUNT(*) > 0 FROM v_order_status_history WHERE raw_status='P'")" "0/1"
ck "new reference row: other codes keep their labels" \
   "$(q "SELECT status FROM fact_order WHERE order_ref='O-103'")" "SHIPPED"
ck "new reference row: no reload (vault rows and deliveries unchanged)" \
   "$(census)/$(aq 'SELECT COUNT(*) FROM arch.loaded_files')" "$census_r/$files_r"
ck "new reference row: the old label stays in the reference history" \
   "$(q "SELECT group_concat(label,'>') FROM (SELECT label FROM ref_order_status WHERE code='P' ORDER BY ldts)")" "PENDING>AWAITING SHIPMENT"

echo; echo "== A delivery naming a reserved value as a business key is refused =="
# Own database pair: the refused delivery stays STARTED, which must never
# reach the main archive.
SAVE_DB="$DB"; SAVE_ARCHIVE_DB="$ARCHIVE_DB"
export DB="$LOGDIR/reserved.db" ARCHIVE_DB="$LOGDIR/reserved_archive.db"
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null 2>&1
cat > "$LOGDIR/reserved.sql" <<'SQL'
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('0','Zero Person','zero@x.com','2026-01-01','2027-05-01','UPSERT','INCREMENTAL');
SQL
rc=0; BATCH_TS='2027-05-01 08:00:00' "$PROJ/scripts/load_feed.sh" "$LOGDIR/reserved.sql" RZ \
  >"$LOGDIR/reserved.log" 2>&1 || rc=$?
ck "customer_id '0' is refused before any loader runs" \
   "$([ "$rc" -ne 0 ] && grep -q 'reserved key value' "$LOGDIR/reserved.log" && echo refused || echo "accepted (exit $rc)")" "refused"
reserved_check "after the refused delivery"
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
printf "  RESULT: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "====================================================================="
rm -f "$DB" "$ARCHIVE_DB"
[ "$FAIL" -eq 0 ] || exit 1
