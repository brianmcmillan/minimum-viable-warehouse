#!/usr/bin/env bash
# =====================================================================
# Focal Point test suite (incremental-aware variant).
#
# PART 1, CORE: the fourteen sections every one of the ten suites runs,
# in the same order and with the same labels (tests/core_spec.tsv at the
# repo root). Each model supplies its own SQL; the nine question
# answers live in tests/answers/Q<n>.sql.
# PART 2, MODEL: what Focal shows on its own -- load control and loader
# scope after every delivery, narrow versioning, the existence contexts,
# the driving-key re-point gap, the wide -> narrow transform, and the
# raw-layer guarantees that used to live in tests/test_archive.sh.
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
FEED_N=0; SKIPPED=0
LOGDIR="$(mktemp -d)"; trap 'rm -rf "$LOGDIR"' EXIT
WORK="$LOGDIR/work"; mkdir -p "$WORK"

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

# Per-delivery checks are model assertions: reported in M01 for the PART 1
# deliveries, at once for PART 2 ones (FEED_SEC empty).
FEED_SEC=M01
fchk(){ if [ -n "$FEED_SEC" ]; then later "$FEED_SEC" "$@"; else own "$@"; fi; }
archive_state(){ aq "SELECT (SELECT COUNT(*) FROM arch.loaded_files)||'/'||(SELECT COUNT(*) FROM arch.hist_customer)
                      ||'/'||(SELECT COUNT(*) FROM arch.hist_product)||'/'||(SELECT COUNT(*) FROM arch.hist_order)
                      ||'/'||(SELECT COUNT(*) FROM arch.hist_order_line)"; }
ckey(){ q "SELECT customer_key FROM customer_idfr WHERE customer_idfr='$1'"; }
# Existence history of one customer (CUSTOMER_EXISTENCE, type_key 19), oldest first.
exist_hist(){ q "SELECT group_concat(val_str||'/'||row_st,'>') FROM (SELECT val_str, row_st FROM customer_desc
                 WHERE type_key=19 AND customer_key=$(ckey "$1") ORDER BY eff_tmstp, ver_tmstp)"; }
exist_rows(){ q "SELECT (SELECT COUNT(*) FROM customer_desc WHERE type_key=19)
                      +(SELECT COUNT(*) FROM product_desc WHERE type_key=29)
                      +(SELECT COUNT(*) FROM order_desc WHERE type_key=39)"; }
# The end state every model prints: current customers as ref(email).
end_state(){ q "SELECT group_concat(customer_ref||'('||COALESCE(email,'null')||')',' ')
                FROM (SELECT * FROM v_customer ORDER BY customer_ref)"; }
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
  fchk "[$file_id] loaded_files: recorded exactly once" \
     "$(aq "SELECT COUNT(*) FROM arch.loaded_files WHERE file_id='$file_id'")" "1"
  if [ "$SKIPPED" -eq 1 ]; then
    fchk "[$file_id] loaded_files: skipped delivery ran no loader" \
       "$(q "SELECT COUNT(*) FROM meta_procinst WHERE batch_ts='$ts'")" "0"
    return
  fi
  fchk "[$file_id] loaded_files: marked COMPLETE after every loader" \
     "$(aq "SELECT status FROM arch.loaded_files WHERE file_id='$file_id'")" "COMPLETE"
  fchk "[$file_id] loaded_files: row_count matches rows delivered" \
     "$(aq "SELECT row_count FROM arch.loaded_files WHERE file_id='$file_id'")" \
     "$(wide_rows)"
  fchk "[$file_id] archive: raw rows captured verbatim" \
     "$(hist_rows "$file_id")" \
     "$(wide_rows)"

  # No loader touched a feed this delivery did not carry.
  fchk "[$file_id] scope: no loader ran outside the delivery's feeds" \
     "$(q "WITH d AS (SELECT DISTINCT source_system||'.'||source_entity f FROM source_landing_stage)
           SELECT COUNT(*) FROM meta_procinst p
           WHERE p.batch_ts='$ts' AND NOT EXISTS (SELECT 1 FROM d WHERE $FEED_MATCH)")" "0"

  # Every feed the delivery carried ran each loader it is mapped to.
  fchk "[$file_id] scope: every delivered feed ran its mapped loaders" \
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
    printf "\n  %d passed, %d failed before the abort.\n" \
      $((CORE_PASS+OWN_PASS)) $((CORE_FAIL+OWN_FAIL)); exit 1
  fi
  if grep -q 'SKIP duplicate' "$log"; then SKIPPED=1; else SKIPPED=0; fi
  ck_load_control "$file_id" "$ts"; }

# ---- raw-layer helpers (formerly tests/test_archive.sh) ----------------
ta_feed(){  BATCH_TS="$3" "$PROJ/scripts/load_feed.sh" "$PROJ/source/$1" "$2" >/dev/null 2>&1; }
ta_feedf(){ BATCH_TS="$3" "$PROJ/scripts/load_feed.sh" "$1" "$2" >/dev/null 2>&1; }
# Every surrogate key, as idfr=key per entity.
all_keys(){ q "SELECT group_concat(k,',') FROM (
    SELECT 'c:'||customer_idfr||'='||customer_key k FROM customer_idfr
    UNION ALL SELECT 'p:'||product_idfr||'='||product_key FROM product_idfr
    UNION ALL SELECT 'o:'||order_idfr||'='||order_key FROM order_idfr ORDER BY 1)"; }
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

ta_demo(){ rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null 2>&1
  ta_feed d0_baseline.sql        B0 '2026-02-05 08:00:00'
  ta_feed d1_cust_win_day60.sql  D1 '2026-03-02 08:00:00'
  ta_feed d2_prod_full_v2.sql    D2 '2026-03-02 09:00:00'
  ta_feed d3_cust_tombstone.sql  D3 '2026-03-16 08:00:00'
  ta_feed d4_cust_recency.sql    D4 '2026-04-02 08:00:00'
  ta_feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'; }


banner "1: CORE  (the same fourteen sections, in this order, in all ten suites)"

core_section C01
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null
core C01.1 "$(census)|$(archive_state)" \
  "customer_idfr=0 customer_focal=0 customer_desc=0 product_idfr=0 product_focal=0 product_desc=0 order_idfr=0 order_focal=0 order_desc=0 order_customer_x=0 order_product_x=0|0/0/0/0/0"

core_section C02
feed d0_baseline.sql B0 '2026-02-05 08:00:00'
core C02.1 "$(q "SELECT (SELECT COUNT(*) FROM v_customer)||'/'||(SELECT COUNT(*) FROM v_product)
                ||'/'||(SELECT COUNT(*) FROM v_order)||'/'||(SELECT COUNT(*) FROM order_product_x WHERE type_key=91 AND row_st='Y')")" "2/3/2/3"
core C02.2 "$(ans 5)" "PENDING"
core C02.3 "$(ans 6)" "48.99"
later M02 "baseline: 2 customers"          "$(q 'SELECT COUNT(*) FROM customer_focal')" "2"
later M02 "baseline: 3 products"           "$(q 'SELECT COUNT(*) FROM product_focal')" "3"
later M02 "baseline: C001 email v1"        "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@example.com"

core_section C03
feed d1_cust_win_day60.sql D1 '2026-03-02 08:00:00'
core C03.1 "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@newmail.com"
core C03.2 "$(q "SELECT row_st FROM customer_desc WHERE customer_key=$(ckey C002) AND type_key=11 ORDER BY eff_tmstp DESC,ver_tmstp DESC LIMIT 1")" "Y"
core C03.3 "$(q "SELECT COUNT(*) FROM customer_desc WHERE customer_key=$(ckey C002) AND type_key=11")" "1"
core C03.4 "$(q "SELECT (SELECT COUNT(*) FROM customer_desc WHERE customer_key=$(ckey C001) AND type_key=10)||'/'||
                       (SELECT COUNT(*) FROM customer_desc WHERE customer_key=$(ckey C001) AND type_key=12)")" "1/1"
later M02 "INCREMENTAL: C002 email unchanged" "$(q "SELECT email FROM v_customer WHERE customer_ref='C002'")" "bob@example.com"
later M02 "INCREMENTAL: still 2 customers"    "$(q 'SELECT COUNT(*) FROM customer_focal')" "2"
later M04 "existence: D1's window writes no existence row for absent C002 (ACTIVE once)" "$(exist_hist C002)" "ACTIVE/Y"

core_section C04
sku2_rows="$(q "SELECT COUNT(*) FROM product_desc WHERE product_key=(SELECT product_key FROM product_idfr WHERE product_idfr='SKU-2')")"
feed d2_prod_full_v2.sql D2 '2026-03-02 09:00:00'
sku3="$(q "SELECT product_key FROM product_idfr WHERE product_idfr='SKU-3'")"
core C04.1 "$(q "SELECT price FROM v_product WHERE sku='SKU-1'")" "8.99"
core C04.2 "$(q "SELECT row_st FROM product_desc WHERE product_key=$sku3 AND type_key=20 ORDER BY eff_tmstp DESC,ver_tmstp DESC LIMIT 1")" "N"
core C04.3 "$(q "SELECT COUNT(*) FROM product_desc WHERE product_key=(SELECT product_key FROM product_idfr WHERE product_idfr='SKU-2')")" "$sku2_rows"
core C04.4 "$(ans 4)" "9.99>8.99"
later M02 "FULL: SKU-3 key still exists" "$(q "SELECT COUNT(*) FROM product_focal WHERE product_key=$sku3")" "1"

core_section C05
feed d3_cust_tombstone.sql D3 '2026-03-16 08:00:00'
core C05.1 "$(q "SELECT row_st FROM customer_desc WHERE customer_key=$(ckey C002) AND type_key=11 ORDER BY eff_tmstp DESC,ver_tmstp DESC LIMIT 1")" "N"
core C05.2 "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "0"
core C05.3 "$(q "SELECT COALESCE(placed_by,'<none>') FROM v_order WHERE order_ref='O-101'")" "<none>"
core C05.4 "$(q "SELECT (SELECT val_str FROM customer_desc WHERE customer_key=$(ckey C002) AND type_key=10 AND row_st='Y'
                         ORDER BY eff_tmstp DESC LIMIT 1)||'/'||
                       (SELECT val_str FROM customer_desc WHERE customer_key=$(ckey C002) AND type_key=11 AND row_st='Y'
                         ORDER BY eff_tmstp DESC LIMIT 1)")" "Bob Jones/bob@example.com"
core C05.5 "$(ans 7)" "Bob Jones"

core_section C06
feed d4_cust_recency.sql D4 '2026-04-02 08:00:00'
core C06.1 "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C003'")" "1"
core C06.2 "$(q "SELECT email FROM v_customer WHERE customer_ref='C003'")" "new@x.com"

core_section C07
before="$(census)"; before_arch="$(archive_state)"
feed d1_cust_win_day60.sql D1 '2026-04-10 08:00:00'
core C07.1 "$SKIPPED" "1"
core C07.2 "$(census)" "$before"
core C07.3 "$(archive_state)" "$before_arch"
later M05 "dup file: D1 recorded once"            "$(aq "SELECT COUNT(*) FROM arch.loaded_files WHERE file_id='D1'")" "1"
later M05 "dup file: D1 archived once"            "$(hist_rows D1)" \
                                                  "$(aq "SELECT row_count FROM arch.loaded_files WHERE file_id='D1'")"
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
# D4's content under a NEW file_id writes no existence row (M04).
exist_before="$(exist_rows)"
feed d4_cust_recency.sql D4R '2026-04-05 08:00:00'
later M04 "existence: re-delivered ACTIVE C003 writes nothing (NOCHANGE)" "$(exist_rows)" "$exist_before"
later M04 "existence: C003 is still ACTIVE once" "$(exist_hist C003)" "ACTIVE/Y"

core_section C08
feed d5_cust_yearly_full.sql D5 '2026-12-31 08:00:00'
core C08.1 "$(q "SELECT row_st FROM customer_desc WHERE customer_key=$(ckey C003) AND type_key=11 ORDER BY eff_tmstp DESC,ver_tmstp DESC LIMIT 1")" "N"
core C08.2 "$(ans 1)" "C001"
core C08.3 "$(ans 2)" "C002,C003"
core C08.4 "$(ans 3)" "alice@example.com>alice@newmail.com"
later M02 "reconcile: C001 survives" "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@newmail.com"
later M04 "end state: v_customer lists C001 only, as every model prints it" "$(end_state)" "C001(alice@newmail.com)"
later M04 "v_customer_status: C002 and C003 DELETED, C001 ACTIVE" \
   "$(q "SELECT group_concat(customer_ref||'='||existence,' ') FROM (SELECT * FROM v_customer_status ORDER BY customer_ref)")" \
   "C001=ACTIVE C002=DELETED C003=DELETED"
later M04 "v_customer_status: C002's DELETED dates from the D3 tombstone" \
   "$(q "SELECT eff_tmstp FROM v_customer_status WHERE customer_ref='C002'")" "2026-03-16 08:00:00"
later M04 "SKU-3 absent from v_product" "$(q "SELECT COUNT(*) FROM v_product WHERE sku='SKU-3'")" "0"
later M04 "SKU-3 DELETED in v_product_status (FULL absence, D2)" \
   "$(q "SELECT existence||'@'||eff_tmstp FROM v_product_status WHERE sku='SKU-3'")" "DELETED@2026-03-02 09:00:00"
later M04 "existence history: C002 ACTIVE then DELETED, both current-style 'Y' facts" "$(exist_hist C002)" "ACTIVE/Y>DELETED/Y"
later M04 "C002's email history is still in customer_desc" \
   "$(q "SELECT group_concat(COALESCE(val_str,'')||'/'||row_st,'>') FROM (SELECT val_str,row_st FROM customer_desc
         WHERE type_key=11 AND customer_key=$(ckey C002) ORDER BY eff_tmstp, ver_tmstp)")" "bob@example.com/Y>bob@example.com/N"
later M04 "v_all_facts still lists the DELETED existence fact" \
   "$(q "SELECT val_str FROM v_all_facts WHERE entity_id='CUSTOMER' AND entity_key=$(ckey C002) AND context_name='CUSTOMER_EXISTENCE'")" "DELETED"
later M03 "C002 survived the incremental window, only died to a tombstone" \
   "$(q "SELECT COUNT(*) FROM customer_desc WHERE customer_key=$(ckey C002) AND type_key=11 AND row_st='N'")" "1"

core_section C09
# First the whole sequence re-sent under the SAME ids: load control skips
# every delivery (M05). Then D5's content under a NEW id: every loader
# runs and every delta must come up empty (the core check).
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
later M05 "replay: zero new data rows"     "$(census)" "$census_0"
later M05 "replay: zero new loaded_files"  "$(aq 'SELECT COUNT(*) FROM arch.loaded_files')" "$files_0"
later M05 "replay: zero new archived rows" "$(hist_rows)" "$arch_0"
later M05 "replay: zero new pipeline runs" "$(q 'SELECT COUNT(*) FROM meta_procinst')" "$inst_0"
before_d5r="$(census)"
feed d5_cust_yearly_full.sql D5R '2027-02-15 08:00:00'
core C09.1 "$(census)" "$before_d5r"

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

core_section C11
# Keys, descriptors and links, surrogate keys included (snap); lineage
# columns are reassigned by definition and left out.
ingested_main="$(snap)|$(all_keys)"
rm -f "$DB"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
core C11.1 "$(snap)|$(all_keys)" "$ingested_main"

core_section C12
# Focal applies the rule at ingest (meta_value_map), so a changed label
# reaches past orders by editing the seed and rebuilding from the raw
# values in the archive. Exercised in a throwaway copy of the project.
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
  echo "$before_status|$("$SQLITE" "$DB" < "$HERE/answers/Q9.sql")" > "$WORK/rule.txt"
)
core C12.1 "$(cat "$WORK/rule.txt")" "PENDING|O-100=PLACED,O-101=PLACED"
rm -rf "$WORK/proj"

core_section C13
# OMS corrects O-101 from C002 to C001. Every sibling handles this; Focal's
# load_rel.sh only knows NEW / tombstone-DEL / FULL-absence-DEL, so the new
# pair is inserted and the old one stays active (M06 asserts the defect).
BATCH_TS='2027-03-01 08:00:00' "$PROJ/scripts/load_feed.sh" \
  "$HERE/fixtures/d7_repoint.sql" D7 >"$LOGDIR/d7.log" 2>&1 \
  || { echo "  ABORT: repoint fixture crashed the loader"; sed 's/^/  | /' "$LOGDIR/d7.log"; exit 1; }
okey="$(q "SELECT order_key FROM order_idfr WHERE order_idfr='O-101'")"
core_gap C13.1 "$(ans 8)" "Alice Smith" \
  "known driving-key gap: load_rel.sh leaves O-101 paired with both C001 and C002 (fix in M06)"
core C13.2 "$(q "SELECT group_concat(i.customer_idfr) FROM order_customer_x x
                 JOIN customer_idfr i ON i.customer_key = x.customer_key
                 WHERE x.order_key=$okey AND x.type_key=90 AND i.customer_idfr<>'C001'")" "C002"
later M06 "defect today: O-101 has BOTH pairings active (one order, two customers)" \
    "$(q "SELECT COUNT(*) FROM order_customer_x WHERE order_key=$okey AND type_key=90 AND row_st='Y'")" "2"
# NOTE deliberately NOT asserted: v_order.placed_by. Under the defect it
# is UNDEFINED -- the view picks one of the two active pairings with
# LIMIT 1 and no ORDER BY, so any expected value can pass by planner
# accident. Q8 lists every active pairing instead.

core_section C14
core C14.1 "$(end_state)" "C001(alice@newmail.com)"

banner "2: MODEL  (what Focal shows on its own)"
FEED_SEC=""

own_section M01 "Load control and loader scope after every delivery"
replay M01
own_section M02 "Keys and delivery values beyond the core"
replay M02
own_section M03 "Absence deletes under FULL, never under INCREMENTAL"
replay M03
own_section M04 "Existence contexts: deleted entities are absent, not empty rows"
replay M04
own_section M05 "Load control: duplicates and same-id replays are skipped"
replay M05
own_section M06 "Known gap: driving-key re-point (fixture d7_repoint.sql)"
replay M06
if [ "$CORE_GAP" -gt 0 ]; then
  echo "  ---------------------------------------------------------------"
  echo "  SUGGESTED FIX for core GAP C13.1 (see FOCALPOINT.md 'Known gap'):"
  echo "    1. Declare the driving side per relationship, e.g. add a"
  echo "       driving_role column to meta_relationship ('SOURCE' for"
  echo "       PLACED_BY: an order has one customer at a time; NULL for"
  echo "       CONTAINS: order lines are additive pairs)."
  echo "    2. In load_rel.sh, add a del_repoint CTE next to del_tomb:"
  echo "       close (flag='DEL') every ACTIVE target pair whose driving"
  echo "       key appears in src with a DIFFERENT counterpart, gated on"
  echo "       driving_role. new_delta already inserts the new pair."
  echo "    3. Make C13.1 a core() check, drop the M06 defect assertion,"
  echo "       and re-run the suite's mutation checks."
  echo "  ---------------------------------------------------------------"
fi

own_section M07 "Existence: a key delivered again after its delete is restored (d8_restore.sql)"
# C002 was tombstoned in D3. Not asserted here: v_order.placed_by for
# O-101 -- the re-point gap above leaves it undefined.
BATCH_TS='2027-04-01 08:00:00' "$PROJ/scripts/load_feed.sh" \
  "$HERE/fixtures/d8_restore.sql" D8 >"$LOGDIR/d8.log" 2>&1 \
  || { echo "  ABORT: restore fixture crashed the loader"; sed 's/^/  | /' "$LOGDIR/d8.log"; exit 1; }
own "restore: C002 existence reopens (ACTIVE > DELETED > ACTIVE)" "$(exist_hist C002)" "ACTIVE/Y>DELETED/Y>ACTIVE/Y"
own "restore: C002 ACTIVE in v_customer_status since D8" \
   "$(q "SELECT existence||'@'||eff_tmstp FROM v_customer_status WHERE customer_ref='C002'")" "ACTIVE@2027-04-01 08:00:00"
own "restore: every C002 attribute reopened with a new 'Y' version" \
   "$(q "SELECT group_concat(type_key||':'||row_st||':'||eff_tmstp,' ') FROM (SELECT * FROM customer_desc
         WHERE customer_key=$(ckey C002) AND type_key IN (10,11,12) AND eff_tmstp='2027-04-01 08:00:00' ORDER BY type_key)")" \
   "10:Y:2027-04-01 08:00:00 11:Y:2027-04-01 08:00:00 12:Y:2027-04-01 08:00:00"
own "restore: C002 back in v_customer with its new values" \
   "$(q "SELECT customer_name||'|'||email||'|'||signup_date FROM v_customer WHERE customer_ref='C002'")" \
   "Bob Jones|bob@restored.com|2026-01-06"
own "restore: end state now C001 and C002" "$(end_state)" "C001(alice@newmail.com) C002(bob@restored.com)"


own_section M08 "Level 1: the wide -> narrow transform (stage_narrow.sh)"
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

own_section M09 "Level 2: the narrow loaders, fed narrow rows directly"
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


# ---- the raw-layer guarantees (formerly tests/test_archive.sh) -------
# Own database pair: these sections rebuild, clean and re-demo freely.
SAVE_DB="$DB"; SAVE_ARCHIVE_DB="$ARCHIVE_DB"
export DB="$LOGDIR/ta.db" ARCHIVE_DB="$LOGDIR/ta_archive.db"
own_section M10 "The archive captured every delivery, verbatim"
ta_demo
src_rows=$(grep -hc "^('" "$PROJ"/source/d*.sql | paste -sd+ - | bc)
own "archive holds every staged row from every source file" \
   "$(hist_rows)" "$src_rows"
own "6 deliveries recorded, all COMPLETE" \
   "$(aq "SELECT COUNT(*) FROM arch.loaded_files WHERE status='COMPLETE'")" "6"
own "load_seq is dense and in ingest order" \
   "$(aq "SELECT group_concat(file_id,',') FROM (SELECT file_id FROM arch.loaded_files ORDER BY load_seq)")" \
   "B0,D1,D2,D3,D4,D5"
own "raw value survives ingest-time translation ('P', not 'PENDING')" \
   "$(aq "SELECT DISTINCT status FROM arch.hist_order WHERE order_ref='O-100'")" "P"

seq_before="$(aq "SELECT load_seq FROM arch.loaded_files WHERE file_id='D1'")"
rows_before="$(hist_rows)"
ta_feed d1_cust_win_day60.sql D1 '2027-01-01 08:00:00'
own "re-sending D1 archives zero new rows" \
   "$(hist_rows)" "$rows_before"
own "re-sending D1 leaves load_seq unchanged" \
   "$(aq "SELECT load_seq FROM arch.loaded_files WHERE file_id='D1'")" "$seq_before"

# A file_id names a delivery's CONTENT. Reusing it for different content is
# the one hazard idempotent (INSERT OR IGNORE) archiving cannot detect itself.
# Wide, like every delivery: D1's id, different customers and a different
# row count (D1 carries one row).
cat > "$WORK/tamper.sql" <<'SQL'
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C009','Tam Per','t@x.com','2027-01-01','2027-01-01','UPSERT','INCREMENTAL'),
('C010','Tam Per','u@x.com','2027-01-01','2027-01-01','UPSERT','INCREMENTAL');
SQL
out="$(BATCH_TS='2027-01-01 09:00:00' "$PROJ/scripts/load_feed.sh" "$WORK/tamper.sql" D1 2>&1)"; rc=$?
own "reused file_id with different content is REJECTED" \
   "$([ "$rc" -ne 0 ] && echo rejected || echo accepted)" "rejected"
own "  ...and says why" "$(printf '%s' "$out" | grep -c 'identifies a delivery' )" "1"

own_section M11 "Append-only is absolute (no unlock path exists)"
for t in hist_customer hist_product hist_order hist_order_line; do
  own_abort "UPDATE on $t aborts" "UPDATE $t SET op=op;" "append-only"
  own_abort "DELETE on $t aborts" "DELETE FROM $t;"      "append-only"
done
own "archive intact after both attempts" \
   "$(hist_rows)" "$rows_before"

own_section M12 "Rebuild reproduces the warehouse exactly (keys included)"
# INGESTED is the ground truth: what the loaders built from the delivery
# files themselves. Every rebuild below is compared against THAT, never
# against a previous rebuild -- a deterministically-wrong replay would
# agree with itself and sail through.
ta_demo
ingested="$(snap)"
ingested_keys="$(q "SELECT group_concat(customer_idfr||'='||customer_key,',')
                    FROM (SELECT * FROM customer_idfr ORDER BY customer_idfr)")"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
own "rebuild: warehouse is identical, surrogate keys and all" "$(snap)" "$ingested"
# Smoke check, NOT a regression test for the inst_key gate that load_keys.sh
# drops. Under genesis replay *_idfr starts empty, so that gate matches and
# _focal populates either way -- reinstating it does not fail this suite.
# It only bites where something seeds *_idfr before replaying, which nothing
# here does. Removing it is hardening; do not claim coverage we do not have.
own "rebuild: focal rows repopulated" \
   "$(q 'SELECT COUNT(*) FROM customer_focal')" "3"
own "rebuild: lineage regenerated, not carried over" \
   "$(q "SELECT CASE WHEN COUNT(*)>0 THEN 'yes' ELSE 'no' END FROM meta_procinst")" "yes"

own_section M13 "Keys are DERIVED, not preserved: clean + rebuild"
rm -f "$DB"                       # exactly what `make clean` does to build/
own "focal.db really is gone" "$([ -f "$DB" ] && echo present || echo gone)" "gone"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1 || echo "  (rebuild exited $?)"
own "clean+rebuild: same keys as INGEST, from the archive alone" \
   "$(q "SELECT group_concat(customer_idfr||'='||customer_key,',')
         FROM (SELECT * FROM customer_idfr ORDER BY customer_idfr)")" \
   "$ingested_keys"
own "clean+rebuild: warehouse identical to INGEST" "$(snap)" "$ingested"

own_section M14 "Replay order is load-bearing"
own "rebuild.sh replays ORDER BY load_seq" \
   "$(grep -c 'ORDER BY load_seq' "$PROJ/scripts/rebuild.sh")" "1"
own "load_keys.sh iterates feeds deterministically" \
   "$(grep -c 'ORDER BY m.entity_id' "$PROJ/scripts/load_keys.sh")" "1"
# The hazard the ORDER BY prevents: keys follow arrival order.
rm -f "$DB" "$ARCHIVE_DB"; "$PROJ/scripts/init_db.sh" >/dev/null 2>&1
ta_feed d4_cust_recency.sql D4 '2026-01-01 00:00:00'
ta_feed d0_baseline.sql     B0 '2026-02-05 08:00:00'
own "out-of-order replay WOULD misassign keys (C003 -> 1001, not 1003)" \
   "$(q "SELECT customer_key FROM customer_idfr WHERE customer_idfr='C003'")" "1001"

own_section M15 "Recency dedup survives replay (stage restored in seq_nbr order)"
ta_demo
# (a) recency by extract_ts -- settled before rowid is ever consulted.
own "ingest: newest email by extract_ts wins" "$(email C003)" "new@x.com"
# (b) the tiebreak that actually depends on physical row order: two values,
#     one extract_ts. Only the last row in the file may win. This is the case
#     seq_nbr exists for, and d4 cannot cover it.
ta_feedf "$HERE/fixtures/d6_tiebreak_wide.sql" D6 '2027-02-01 08:00:00'
own "ingest: equal extract_ts -> last row in the file wins" "$(email C004)" "last@x.com"
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1
own "after rebuild: extract_ts recency preserved"  "$(email C003)" "new@x.com"
own "after rebuild: rowid tiebreak preserved"      "$(email C004)" "last@x.com"

own_section M16 "Delete semantics survive replay, not just row counts"
ta_demo
"$PROJ/scripts/rebuild.sh" >/dev/null 2>&1
own "replay: SKU-3 still deleted by FULL absence" \
   "$(q "SELECT row_st FROM product_desc WHERE product_key=(SELECT product_key FROM product_idfr WHERE product_idfr='SKU-3')
         AND type_key=20 ORDER BY eff_tmstp DESC, ver_tmstp DESC LIMIT 1")" "N"
own "replay: C002 still deleted by tombstone" \
   "$(q "SELECT COUNT(*) FROM v_customer WHERE customer_ref='C002'")" "0"
own "replay: C003 still reconciled away by the yearly FULL" \
   "$(q "SELECT row_st FROM customer_desc WHERE customer_key=(SELECT customer_key FROM customer_idfr WHERE customer_idfr='C003')
         AND type_key=11 ORDER BY eff_tmstp DESC, ver_tmstp DESC LIMIT 1")" "N"
own "replay: C001 survives with its updated email" \
   "$(q "SELECT email FROM v_customer WHERE customer_ref='C001'")" "alice@newmail.com"
own "replay: existence is reproduced (C001 ACTIVE, C002 and C003 DELETED)" \
   "$(q "SELECT group_concat(customer_ref||'='||existence||'@'||eff_tmstp,' ') FROM (SELECT * FROM v_customer_status ORDER BY customer_ref)")" \
   "C001=ACTIVE@2026-02-05 08:00:00 C002=DELETED@2026-03-16 08:00:00 C003=DELETED@2026-12-31 08:00:00"

own_section M17 "archive-status reports and deletes nothing"
rows="$(hist_rows)"
out="$("$PROJ/scripts/archive_status.sh" 2>&1)"; rc=$?
own "archive_status.sh exits 0" "$rc" "0"
own "  ...reports the per-feed breakdown" "$(printf '%s' "$out" | grep -c 'rows_per_delivery')" "1"
own "  ...and deleted nothing" "$(hist_rows)" "$rows"

own_section M18 "demo is repeatable (fresh archive each time)"
ta_demo; census_1="$(snap)"
ta_demo; own "second demo yields the same warehouse" "$(snap)" "$census_1"

own_section M19 "The archive is wide: no narrow table"
ta_demo
own "archive tables are exactly the shared wide layout" \
   "$(aq "SELECT group_concat(name,',') FROM (SELECT name FROM arch.sqlite_master WHERE type='table' ORDER BY name)")" \
   "hist_customer,hist_order,hist_order_line,hist_product,loaded_files"
own "no archived table has a key/value (attribute_name) column" \
   "$(aq "SELECT COUNT(*) FROM arch.sqlite_master m, pragma_table_info(m.name, 'arch') c
          WHERE m.type='table' AND c.name='attribute_name'")" "0"

own_section M20 "make rebuild reproduces every surrogate key"
# Every existence version (type_keys 19/29/39): key, eff_tmstp, value, row_st.
ta_exist_rows(){ q "SELECT group_concat(r,' ') FROM (
    SELECT 'c'||customer_key||'/'||eff_tmstp||'/'||val_str||'/'||row_st r FROM customer_desc WHERE type_key=19
    UNION ALL SELECT 'p'||product_key||'/'||eff_tmstp||'/'||val_str||'/'||row_st FROM product_desc WHERE type_key=29
    UNION ALL SELECT 'o'||order_key||'/'||eff_tmstp||'/'||val_str||'/'||row_st FROM order_desc WHERE type_key=39
    ORDER BY 1)"; }
ingested_all="$(all_keys)"; ingested="$(snap)"; ingested_exist="$(ta_exist_rows)"
rm -f "$DB"
make -s -C "$PROJ" rebuild >/dev/null 2>&1; rc=$?
own "make rebuild exits 0" "$rc" "0"
own "make rebuild: every surrogate key (customer, product, order) as ingested" "$(all_keys)" "$ingested_all"
own "make rebuild: warehouse identical to INGEST" "$(snap)" "$ingested"
own "make rebuild: every existence row as ingested (11 rows: 5 customer, 4 product, 2 order)" \
   "$(ta_exist_rows)|$(q "SELECT COUNT(*) FROM customer_desc WHERE type_key=19")+$(q "SELECT COUNT(*) FROM product_desc WHERE type_key=29")+$(q "SELECT COUNT(*) FROM order_desc WHERE type_key=39")" \
   "$ingested_exist|5+4+2"

own_section M21 "Unpivoted D0..D5 build the same warehouse as the old narrow files"
# The old narrow deliveries (tests/fixtures/narrow) go straight into the
# narrow stage and through apply_delivery.sh -- level 2, no archive -- in a
# scratch database created after every rebuild assertion above. Stage row
# counts differ (D4: 8 unpivoted vs 5 narrow); the loaded result may not.
wide_snap="$(snap)"; wide_keys="$(all_keys)"
SAVE_DB="$DB"; SAVE_ARCHIVE_DB="$ARCHIVE_DB"
export DB="$WORK/narrow_ref.db" ARCHIVE_DB="$WORK/narrow_ref_archive.db"
"$PROJ/scripts/init_db.sh" >/dev/null 2>&1
for d in "d0_baseline B0 2026-02-05 08:00:00" "d1_cust_win_day60 D1 2026-03-02 08:00:00" \
         "d2_prod_full_v2 D2 2026-03-02 09:00:00" "d3_cust_tombstone D3 2026-03-16 08:00:00" \
         "d4_cust_recency D4 2026-04-02 08:00:00" "d5_cust_yearly_full D5 2026-12-31 08:00:00"; do
  set -- $d
  "$SQLITE" "$DB" "DELETE FROM source_landing_stage;"; "$SQLITE" "$DB" < "$HERE/fixtures/narrow/$1.sql"
  BATCH_TS="$3 $4" "$PROJ/scripts/apply_delivery.sh" >/dev/null 2>&1
done
own "same surrogate keys from the old narrow files" "$(all_keys)" "$wide_keys"
own "same derived tables (keys, descriptors, links) from the old narrow files" "$(snap)" "$wide_snap"
export DB="$SAVE_DB" ARCHIVE_DB="$SAVE_ARCHIVE_DB"


export DB="$SAVE_DB" ARCHIVE_DB="$SAVE_ARCHIVE_DB"

own_section M22 "Load control: a file_id names CONTENT (same block in all ten suites)"
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
