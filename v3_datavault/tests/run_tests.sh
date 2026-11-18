#!/usr/bin/env bash
# =====================================================================
# Data Vault 2.0 test suite.
#
# PART 1, CORE: the fourteen sections every one of the ten suites runs,
# in the same order and with the same labels (tests/core_spec.tsv at the
# repo root). Each model supplies its own SQL; the nine question
# answers live in tests/answers/Q<n>.sql.
# PART 2, MODEL: what the vault shows on its own -- hub keys, whole-row
# satellites and status tracking, driving-key effectivity, reserved
# ghost and null keys, the CPIT and bridge tables, the insert-only raw
# vault, and soft rules decoded on read from a reference table.
#   make test   (or)   ./tests/run_tests.sh
# =====================================================================
# No `set -e`: every assertion must run so one failure doesn't hide the rest.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/.." && pwd)"
: "${SQLITE:=sqlite3}"
export SQLITE
export DB="${TESTDB:-$(mktemp -u 2>/dev/null || echo /tmp/dv_test).db}"
export ARCHIVE_DB="${DB%.db}_archive.db"
FEED_N=0; SKIPPED=0
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

# chk: a model assertion. In PART 1 it is evaluated now and reported later
# in MODEL section $SEC; in PART 2 ($SEC empty) it is reported at once.
SEC=""
chk(){ if [ -n "$SEC" ]; then later "$SEC" "$@"; else own "$@"; fi; }
archive_state(){ aq "SELECT (SELECT COUNT(*) FROM arch.loaded_files)||'/'||(SELECT COUNT(*) FROM arch.hist_customer)
                      ||'/'||(SELECT COUNT(*) FROM arch.hist_product)||'/'||(SELECT COUNT(*) FROM arch.hist_order)
                      ||'/'||(SELECT COUNT(*) FROM arch.hist_order_line)"; }

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
# RB_OK ends as "ok", or names every check that failed (C11.1 reads it).
rb_ck(){ [ "$2" = "$3" ] || RB_OK="${RB_OK#ok}[$1]"; chk "$@"; }
rebuild_check(){ local label="$1" t tables want rc=0 snapdir="$LOGDIR/snap-$FEED_N"; RB_OK=ok
  mkdir -p "$snapdir"; tables="$(vault_tables)"; extra="$(extra_objects)"
  for t in $tables $extra; do dump "$t" > "$snapdir/$t"; done
  rm -f "$DB"
  make -s -C "$PROJ" rebuild >"$LOGDIR/rebuild-$FEED_N.log" 2>&1 || rc=$?
  rb_ck "[$label] make rebuild exits 0" "$rc" "0"
  rb_ck "[$label] rebuilt vault has the same rv_*/bv_* tables" "$(vault_tables)" "$tables"
  for t in $tables; do
    # An empty or errored snapshot can never match: equal errors are not equal tables.
    want="$(cat "$snapdir/$t")"
    case "$want" in ''|*'<SQL-ERROR>'*) want="<no valid snapshot of $t>";; esac
    rb_ck "[$label] $t reproduced row for row ($(grep -c "" "$snapdir/$t") rows)" \
       "$(dump "$t")" "$want"
  done
  # The reference table and the business vault's views (the computed
  # status satellite) are rebuilt too; snapshots were taken above.
  for t in $extra; do
    want="$(cat "$snapdir/$t")"
    case "$want" in ''|*'<SQL-ERROR>'*) want="<no valid snapshot of $t>";; esac
    rb_ck "[$label] $t reproduced row for row ($(grep -c "" "$snapdir/$t") rows)" \
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
      chk "[$label] $t holds exactly its reserved rows" \
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
    chk "[$label] bv_${e}_cpit: exactly one row per real hub key" \
       "$(q "SELECT (SELECT COUNT(*) FROM bv_${e}_cpit) = (SELECT COUNT(*) FROM rv_${e}_h WHERE $k NOT IN $RES)
                AND NOT EXISTS (SELECT $k FROM rv_${e}_h WHERE $k NOT IN $RES
                                EXCEPT SELECT $k FROM bv_${e}_cpit)")" "1"
    chk "[$label] bv_${e}_cpit: no NULL pointer" \
       "$(q "SELECT COUNT(*) FROM bv_${e}_cpit p WHERE $(q "SELECT group_concat('p.'||name||' IS NULL',' OR ')
              FROM pragma_table_info('bv_${e}_cpit')")")" "0"
    chk "[$label] bv_${e}_cpit: hsat pointers at the newest row, or the ghost" "$(ptr_bad "$e" "rv_${e}_hsat" hsat)" "0"
    chk "[$label] bv_${e}_cpit: sts pointers at the newest row, or the ghost"  "$(ptr_bad "$e" "rv_${e}_sts"  sts)"  "0"
  done
  chk "[$label] bv_order_cpit: effectivity pointer at the current pairing, or the ghost" \
     "$(q "SELECT COUNT(*) FROM bv_order_cpit p WHERE NOT (
             (p.eff_customer_bk, p.eff_ldts) IN
               (SELECT customer_bk, ldts FROM bv_order_customer_l_effsat e WHERE e.order_bk = p.order_bk
                ORDER BY start_date DESC, ldts DESC LIMIT 1)
          OR (p.eff_customer_bk = '0' AND p.eff_ldts = '$GHOST_TS'
              AND NOT EXISTS (SELECT 1 FROM bv_order_customer_l_effsat e WHERE e.order_bk = p.order_bk)))")" "0"
  chk "[$label] bv_order_bridge: one row per order line" \
     "$(q "SELECT (SELECT COUNT(*) FROM bv_order_bridge) = (SELECT COUNT(*) FROM rv_order_product_l)
              AND NOT EXISTS (SELECT order_bk, product_bk FROM rv_order_product_l
                              EXCEPT SELECT order_bk, product_bk FROM bv_order_bridge)")" "1"
  chk "[$label] bv_order_bridge: each line carries its order's current customer, or '0'" \
     "$(q "SELECT COUNT(*) FROM bv_order_bridge b WHERE b.customer_bk <>
             COALESCE((SELECT customer_bk FROM v_order_customer_current c WHERE c.order_bk = b.order_bk), '0')")" "0"; }
# Every info-mart and audit view, with its key column(s).
MART_KEYS="dim_customer:customer_ref dim_product:sku fact_order:order_ref
  v_customer_hsat_current:customer_bk v_product_hsat_current:product_bk v_order_hsat_current:order_bk
  v_customer_sts_current:customer_bk v_product_sts_current:product_bk v_order_sts_current:order_bk
  v_order_status_history:order_ref v_status_history:business_key"
# UPDATE / DELETE against the vault database must abort.
ck_abort_db(){ local out; out="$("$SQLITE" "$DB" "$2" 2>&1)"
      case "$out" in *"$3"*) out=refused;; esac; chk "$1" "$out" "refused"; }


# Run one delivery; abort the suite if a loader crashes (past that point
# every assertion measures a half-loaded database, not the code). Its
# manifest and stage checks are model assertions: M01 in PART 1, reported
# at once in PART 2.
FEED_SEC=M01
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
  SEC="$FEED_SEC" chk "[$file_id] manifest: recorded exactly once" \
     "$(aq "SELECT COUNT(*) FROM arch.loaded_files WHERE file_id='$file_id'")" "1"
  [ "$SKIPPED" -eq 0 ] && SEC="$FEED_SEC" chk "[$file_id] manifest: COMPLETE after all loaders" \
     "$(aq "SELECT status FROM arch.loaded_files WHERE file_id='$file_id'")" "COMPLETE"
  # Standing invariant: a delivery that returned success left the stage
  # blank. Residue after exit 0 would mean either the success-clear was
  # lost, or a failure was misreported as success.
  SEC="$FEED_SEC" chk "[$file_id] stage blank after delivery" \
     "$(q "SELECT (SELECT COUNT(*) FROM stg_customer_l1)+(SELECT COUNT(*) FROM stg_product_l1)
                +(SELECT COUNT(*) FROM stg_order_l1)+(SELECT COUNT(*) FROM stg_order_line_l1)")" "0"
  return 0; }

sts(){ q "SELECT sts FROM v_customer_sts_current WHERE customer_bk='$1'"; }

banner "1: CORE  (the same fourteen sections, in this order, in all ten suites)"

core_section C01
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null
# Nothing delivered yet. The reserved rows and the reference table are
# written at init; census() leaves them out (M05 checks them).
core C01.1 "$(census)|$(archive_state)" \
  "cust_h=0 cust_hsat=0 cust_sts=0 prod_h=0 prod_hsat=0 prod_sts=0 ord_h=0 ord_hsat=0 ord_sts=0 oc_l=0 op_l=0 oc_eff=0|0/0/0/0/0"
SEC=M05 reserved_check "init"

core_section C02
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
core C02.1 "$(q "SELECT (SELECT COUNT(*) FROM dim_customer)||'/'||(SELECT COUNT(*) FROM dim_product)
                ||'/'||(SELECT COUNT(*) FROM fact_order)||'/'||(SELECT COUNT(*) FROM rv_order_product_l)")" "2/3/2/3"
core C02.2 "$(ans 5)" "PENDING"
core C02.3 "$(ans 6)" "48.99"
SEC=M03
chk "baseline: 2 customer keys"   "$(q "SELECT COUNT(*) FROM rv_customer_h WHERE customer_bk NOT IN ('0','-1','-2')")" "2"
chk "baseline: 3 product keys"    "$(q "SELECT COUNT(*) FROM rv_product_h WHERE product_bk NOT IN ('0','-1','-2')")" "3"
chk "baseline: 2 order keys"      "$(q "SELECT COUNT(*) FROM rv_order_h WHERE order_bk NOT IN ('0','-1','-2')")" "2"
SEC=M02 chk "baseline: C001 email v1"     "$(q "SELECT email FROM dim_customer WHERE customer_ref='C001'")" "alice@example.com"
SEC=M04 chk "baseline: 2 current order->customer pairings" \
   "$(q 'SELECT COUNT(*) FROM v_order_customer_current')" "2"
SEC=M11 chk "RAW: vault stores source code 'P', mart translates" \
   "$(q "SELECT (SELECT status FROM rv_order_hsat WHERE order_bk='O-100')||'/'||
              (SELECT status FROM fact_order WHERE order_ref='O-100')")" "P/PENDING"

core_section C03
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
core C03.1 "$(q "SELECT email FROM dim_customer WHERE customer_ref='C001'")" "alice@newmail.com"
core C03.2 "$(sts C002)" "I"
core C03.3 "$(q "SELECT COUNT(*) FROM rv_customer_hsat WHERE customer_bk='C002'")" "1"
core C03.4 "$(q "SELECT COUNT(DISTINCT full_name)||'/'||COUNT(DISTINCT signup_date) FROM rv_customer_hsat WHERE customer_bk='C001'")" "1/1"
SEC=M02 chk "INCREMENTAL: C002 email unchanged" "$(q "SELECT email FROM dim_customer WHERE customer_ref='C002'")" "bob@example.com"
SEC=M03 chk "grain: C001 change = ONE whole-row sat version (2 total)" \
   "$(q "SELECT COUNT(*) FROM rv_customer_hsat WHERE customer_bk='C001'")" "2"

core_section C04
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
core C04.1 "$(q "SELECT price FROM dim_product WHERE sku='SKU-1'")" "8.99"
core C04.2 "$(q "SELECT COUNT(*) FROM dim_product WHERE sku='SKU-3'")" "0"
core C04.3 "$(q "SELECT COUNT(*) FROM rv_product_hsat WHERE product_bk='SKU-2'")" "1"
core C04.4 "$(ans 4)" "9.99>8.99"
SEC=M03
chk "FULL: SKU-3 deleted on absence (sts='D')" \
   "$(q "SELECT sts FROM v_product_sts_current WHERE product_bk='SKU-3'")" "D"
chk "FULL: SKU-3 hub key remains (insert-only)" \
   "$(q "SELECT COUNT(*) FROM rv_product_h WHERE product_bk='SKU-3'")" "1"
chk "FULL: SKU-3 history remains in its satellite" \
   "$(q "SELECT COUNT(*) FROM rv_product_hsat WHERE product_bk='SKU-3'")" "1"
SEC=""

core_section C05
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
core C05.1 "$(sts C002)" "D"
core C05.2 "$(q "SELECT COALESCE((SELECT email FROM dim_customer WHERE customer_ref='C002'),'<none>')")" "<none>"
core C05.3 "$(q "SELECT COALESCE((SELECT placed_by FROM fact_order WHERE order_ref='O-101'),'<none>')")" "<none>"
core C05.4 "$(q "SELECT full_name||'/'||email_addr FROM rv_customer_hsat WHERE customer_bk='C002'")" "Bob Jones/bob@example.com"
core C05.5 "$(ans 7)" "Bob Jones"
SEC=M06 chk "CPIT: deleted C002 keeps its row, its sts pointer names the 'D' row" \
   "$(q "SELECT st.sts||'@'||st.ldts FROM bv_customer_cpit p
          JOIN rv_customer_sts st ON st.customer_bk = p.sts_bk AND st.ldts = p.sts_ldts
         WHERE p.customer_bk='C002'")" "D@2026-03-16 08:00:00"

core_section C06
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
core C06.1 "$(q "SELECT COUNT(*) FROM dim_customer WHERE customer_ref='C003'")" "1"
core C06.2 "$(q "SELECT email FROM dim_customer WHERE customer_ref='C003'")" "new@x.com"
SEC=M03 chk "recency: one delivery -> one sat row" "$(q "SELECT COUNT(*) FROM rv_customer_hsat WHERE customer_bk='C003'")" "1"

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
core C08.1 "$(sts C003)" "D"
core C08.2 "$(ans 1)" "C001"
core C08.3 "$(ans 2)" "C002,C003"
core C08.4 "$(ans 3)" "alice@example.com>alice@newmail.com"
SEC=M02 chk "reconcile: C001 survives" "$(q "SELECT email FROM dim_customer WHERE customer_ref='C001'")" "alice@newmail.com"
SEC=M03
chk "reconcile: C001 unchanged content -> NO new sat row (still 2)" \
   "$(q "SELECT COUNT(*) FROM rv_customer_hsat WHERE customer_bk='C001'")" "2"
chk "C002 presence timeline is exactly I -> D (2 assertions)" \
   "$(q "SELECT group_concat(sts,'') FROM (SELECT sts FROM rv_customer_sts WHERE customer_bk='C002' ORDER BY ldts)")" "ID"
SEC=M06 cpit_check "after D5"
SEC=""

core_section C09
before_r="$(census)"
feed d5_cust_yearly_full.sql D5R '2027-01-10 08:00:00'
core C09.1 "$(census)" "$before_r"
# The whole sequence re-sent under the SAME ids: load control skips every
# delivery (M09). The C09 check above is the one that runs the loaders.
census_0="$(census)"
feed d0_baseline.sql         B0 '2027-01-05 08:00:00'
feed d1_cust_win_day60.sql   D1 '2027-01-05 08:01:00'
feed d2_prod_full_v2.sql     D2 '2027-01-05 08:02:00'
feed d3_cust_tombstone.sql   D3 '2027-01-05 08:03:00'
feed d4_cust_recency.sql     D4 '2027-01-05 08:04:00'
feed d5_cust_yearly_full.sql D5 '2027-01-05 08:05:00'
SEC=M09 chk "replay: zero new vault rows" "$(census)" "$census_0"
SEC=M05 reserved_check "after the full replay"

core_section C10
core C10.1 "$(aq "SELECT (SELECT COUNT(*) FROM arch.hist_customer)+(SELECT COUNT(*) FROM arch.hist_product)
              +(SELECT COUNT(*) FROM arch.hist_order)+(SELECT COUNT(*) FROM arch.hist_order_line)")" \
           "$(aq 'SELECT SUM(row_count) FROM arch.loaded_files')"
core C10.2 "$(for t in hist_customer hist_product hist_order hist_order_line; do
                printf '%s ' "$(refused "UPDATE $t SET op=op;" "append-only")"; done)" \
           "refused refused refused refused "
core C10.3 "$(for t in hist_customer hist_product hist_order hist_order_line; do
                printf '%s ' "$(refused "DELETE FROM $t;" "append-only")"; done)" \
           "refused refused refused refused "
SEC=M07
for t in $(q "SELECT name FROM sqlite_master WHERE type='table'
              AND (name LIKE 'rv\_%' ESCAPE '\' OR name LIKE 'ref\_%' ESCAPE '\'
                   OR name = 'bv_order_customer_l_effsat') ORDER BY name"); do
  ck_abort_db "UPDATE on $t aborts" "UPDATE $t SET ldts=ldts;" "insert-only"
  ck_abort_db "DELETE on $t aborts" "DELETE FROM $t;"          "insert-only"
done
chk "only the bv_ query-assist tables can be rewritten" \
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
SEC=""

core_section C11
# Every rv_*/bv_* table, the reference table and the bv_ views, row for
# row; the per-table detail is reported in M08.
SEC=M08 rebuild_check "six deliveries"
core C11.1 "$RB_OK" "ok"

core_section C12
# The decode is a view over the latest ref_order_status row per code, so a
# new reference row relabels history with no reload. Tried on a copy of
# the vault: a reference row in the main vault would not survive the
# rebuilds still to come (M11 repeats the scenario after the last one).
cp "$DB" "$LOGDIR/rule.db"
"$SQLITE" "$LOGDIR/rule.db" "INSERT INTO ref_order_status(code,label,ldts,rsrc)
                             VALUES ('P','PLACED','2027-01-20 00:00:00','OPS.RULES');"
core C12.1 "$(DB="$LOGDIR/rule.db" ans 9)" "O-100=PLACED,O-101=PLACED"

core_section C13
feed d6_repoint.sql D6 '2027-02-01 08:00:00' "$HERE/fixtures"
core C13.1 "$(ans 8)" "Alice Smith"
core C13.2 "$(q "SELECT customer_bk FROM v_order_customer_eff_history WHERE order_bk='O-101' AND iscurrent=0")" "C002"
SEC=M04
chk "repoint: O-101 current customer is C001" \
   "$(q "SELECT customer_bk FROM v_order_customer_current WHERE order_bk='O-101'")" "C001"
chk "repoint: exactly ONE current pairing for O-101" \
   "$(q "SELECT COUNT(*) FROM v_order_customer_eff_history WHERE order_bk='O-101' AND iscurrent=1")" "1"
chk "repoint: old pairing end-dated by LEAD, not updated" \
   "$(q "SELECT end_date FROM v_order_customer_eff_history WHERE order_bk='O-101' AND customer_bk='C002'")" "2027-02-01 08:00:00"
chk "repoint: link table keeps BOTH pairs (insert-only history)" \
   "$(q "SELECT COUNT(*) FROM rv_order_customer_l WHERE order_bk='O-101'")" "2"
chk "repoint: unchanged order attrs -> no new sat row" \
   "$(q "SELECT COUNT(*) FROM rv_order_hsat WHERE order_bk='O-101'")" "1"
SEC=M06
chk "repoint: CPIT effectivity pointer is C001, opened by D6" \
   "$(q "SELECT eff_customer_bk||'@'||eff_ldts FROM bv_order_cpit WHERE order_bk='O-101'")" "C001@2027-02-01 08:00:00"
chk "repoint: bridge carries O-101's line under C001 only" \
   "$(q "SELECT group_concat(product_bk||'>'||customer_bk) FROM bv_order_bridge WHERE order_bk='O-101'")" "SKU-2>C001"
cpit_check "after D6"
# D6's content under a NEW id: every loader runs and writes nothing. This
# is the check that catches an effsat re-opening an already-current pairing.
before_d6r="$(census)"
feed d6_repoint.sql D6R '2027-02-15 08:00:00' "$HERE/fixtures"
SEC=M04 chk "re-asserted current state writes zero vault rows" "$(census)" "$before_d6r"
SEC=M08 rebuild_check "after D6R"
SEC=""

core_section C14
core C14.1 "$(q "SELECT group_concat(customer_ref||'('||COALESCE(email,'null')||')',' ')
                 FROM (SELECT * FROM dim_customer ORDER BY customer_ref)")" "C001(alice@newmail.com)"

banner "2: MODEL  (what the Data Vault shows on its own)"
SEC=""; FEED_SEC=""

own_section M01 "Manifest and stage after every delivery"
replay M01
own_section M02 "Delivery values beyond the core"
replay M02
own_section M03 "Hub keys, whole-row satellites and status tracking"
replay M03
own_section M04 "Driving-key effectivity"
replay M04
own_section M05 "Reserved keys: written at init, never by a loader"
replay M05
own_section M06 "Query assistance: CPIT and bridge"
replay M06
own_section M07 "Raw vault: insert-only, enforced"
replay M07
own_section M08 "Rebuild, table by table"
replay M08
own_section M09 "The whole sequence re-sent under the same ids is skipped"
replay M09

own_section M10 "D7: an order with no customer, and a customer with no satellite row"
feed d7_null_customer.sql D7 '2027-03-01 08:00:00' "$HERE/fixtures"
own "null customer_ref: O-102 linked to the required-null key '-1'" \
   "$(q "SELECT group_concat(customer_bk) FROM rv_order_customer_l WHERE order_bk='O-102'")" "-1"
own "null customer_ref: O-102's current pairing is '-1'" \
   "$(q "SELECT customer_bk FROM v_order_customer_current WHERE order_bk='O-102'")" "-1"
own "null customer_ref: O-102 is in the mart, placed by nobody" \
   "$(q "SELECT order_ref||'/'||COALESCE(placed_by,'<none>') FROM fact_order WHERE order_ref='O-102'")" "O-102/<none>"
own "null customer_ref: no '-1' row in dim_customer" \
   "$(q "SELECT COUNT(*) FROM dim_customer WHERE customer_ref='-1'")" "0"
own "null customer_ref: bridge carries O-102's line under '-1'" \
   "$(q "SELECT product_bk||'>'||customer_bk FROM bv_order_bridge WHERE order_bk='O-102'")" "SKU-1>-1"
own "no satellite row: C900 (a link end only) has a CPIT row on the ghost" \
   "$(q "SELECT hsat_bk||'@'||hsat_ldts||' '||sts_bk||'@'||sts_ldts FROM bv_customer_cpit WHERE customer_bk='C900'")" \
   "0@$GHOST_TS 0@$GHOST_TS"
own "no satellite row: C900 stays out of dim_customer" \
   "$(q "SELECT COUNT(*) FROM dim_customer WHERE customer_ref='C900'")" "0"
cpit_check "after D7"
reserved_check "after D7"
for vk in $MART_KEYS; do
  own "no reserved key in ${vk%%:*}" \
     "$(q "SELECT COUNT(*) FROM ${vk%%:*} WHERE ${vk#*:} IN $RES")" "0"
done
rebuild_check "after D7"

own_section M11 "Soft rule change: retroactive without any reload"
replay M11
own "raw 'P' still in the vault"          "$(q "SELECT status FROM rv_order_hsat WHERE order_bk='O-100'")" "P"
own "mart derives PENDING from it today"  "$(q "SELECT status FROM fact_order WHERE order_ref='O-100'")" "PENDING"
own "the decode is a view (bv_order_status_bsat), not a stored table" \
   "$(q "SELECT type FROM sqlite_master WHERE name='bv_order_status_bsat'")" "view"
own "the mart holds no decode of its own" \
   "$(q "SELECT COUNT(*) FROM sqlite_master WHERE type='view' AND name IN ('dim_customer','dim_product','fact_order','v_order_status_history')
          AND (sql LIKE '%PENDING%' OR sql LIKE '%CASE%')")" "0"
census_r="$(census)"; files_r="$(aq 'SELECT COUNT(*) FROM arch.loaded_files')"
q "INSERT INTO ref_order_status(code,label,ldts,rsrc) VALUES ('P','AWAITING SHIPMENT','2027-04-01 00:00:00','OPS.RULES')" >/dev/null
own "new reference row: O-100 reads AWAITING SHIPMENT in the mart" \
   "$(q "SELECT status FROM fact_order WHERE order_ref='O-100'")" "AWAITING SHIPMENT"
own "new reference row: every historical 'P' row is relabelled" \
   "$(q "SELECT COUNT(*) FROM v_order_status_history WHERE raw_status='P' AND status<>'AWAITING SHIPMENT'")/$(q "SELECT COUNT(*) > 0 FROM v_order_status_history WHERE raw_status='P'")" "0/1"
own "new reference row: other codes keep their labels" \
   "$(q "SELECT status FROM fact_order WHERE order_ref='O-103'")" "SHIPPED"
own "new reference row: no reload (vault rows and deliveries unchanged)" \
   "$(census)/$(aq 'SELECT COUNT(*) FROM arch.loaded_files')" "$census_r/$files_r"
own "new reference row: the old label stays in the reference history" \
   "$(q "SELECT group_concat(label,'>') FROM (SELECT label FROM ref_order_status WHERE code='P' ORDER BY ldts)")" "PENDING>AWAITING SHIPMENT"

own_section M12 "A delivery naming a reserved value as a business key is refused"
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
own "customer_id '0' is refused before any loader runs" \
   "$([ "$rc" -ne 0 ] && grep -q 'reserved key value' "$LOGDIR/reserved.log" && echo refused || echo "accepted (exit $rc)")" "refused"
reserved_check "after the refused delivery"
export DB="$SAVE_DB" ARCHIVE_DB="$SAVE_ARCHIVE_DB"


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

own_section M14 "Restore after delete, and the same-extract tiebreak through replay"
# Own database pair: the fixtures never reach the core scenario. Neither
# case occurs in the shared deliveries, so without this section the
# status load's restore branch, the rowid tiebreak and the replay row
# order could all be broken without a single assertion failing.
SAVE_DB="$DB"; SAVE_ARCHIVE_DB="$ARCHIVE_DB"
export DB="$LOGDIR/m14.db" ARCHIVE_DB="$LOGDIR/m14_archive.db"
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null 2>&1
m14(){ BATCH_TS="$3" "$PROJ/scripts/load_feed.sh" "$1" "$2" >/dev/null 2>&1 || echo "  (load_feed.sh $2 exited $?)"; }
m14 "$PROJ/source/d0_baseline.sql"       B0 '2026-02-05 08:00:00'
m14 "$PROJ/source/d3_cust_tombstone.sql" D3 '2026-03-16 08:00:00'
m14 "$HERE/fixtures/d8_restore.sql"      D8 '2027-04-01 08:00:00'
own "restore: C002 re-sent with its pre-delete values is live again" \
   "$(q "SELECT customer_name||'/'||email FROM dim_customer WHERE customer_ref='C002'")" "Bob Jones/bob@example.com"
own "restore: status history I > D > I, and no new satellite row" \
   "$(q "SELECT group_concat(sts,'>') FROM (SELECT sts FROM rv_customer_sts WHERE customer_bk='C002' ORDER BY ldts)")/$(q "SELECT COUNT(*) FROM rv_customer_hsat WHERE customer_bk='C002'")" "I>D>I/1"
m14 "$HERE/fixtures/d9_tiebreak_wide.sql" D9 '2027-04-02 08:00:00'
own "tiebreak: equal extract_dt -> the last row in the file wins" \
   "$(q "SELECT email FROM dim_customer WHERE customer_ref='C004'")" "last@x.com"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
own "tiebreak: still the last row after rebuild (seq_nbr order restored)" \
   "$(q "SELECT email FROM dim_customer WHERE customer_ref='C004'")" "last@x.com"
own "restore: still live after rebuild" \
   "$(q "SELECT COUNT(*) FROM dim_customer WHERE customer_ref='C002'")" "1"
export DB="$SAVE_DB" ARCHIVE_DB="$SAVE_ARCHIVE_DB"

rm -f "$DB" "$ARCHIVE_DB"
summary
