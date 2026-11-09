#!/usr/bin/env bash
# ---------------------------------------------------------------------
# CORE LOADER -- ONE generic delta engine for every core table, driven by
# the core_table registry. Nothing here names an entity. (The same engine
# as ../v3_hook/scripts/load_frames.sh, pointed at natural-key tables.)
#
# Per core table (in load_order), against its latest row per subject:
#   1. UPSERT  -> write a row if the subject is new, was deleted, or its
#                 diff_str changed.  INSERT for new/re-appeared, UPDATE
#                 otherwise. An unchanged subject (NOCHANGE) writes nothing.
#   2. DELETE  -> a tombstone writes a DELETE row (basis TOMBSTONE) for a
#                 live subject. Always honoured.
#   3. ABSENCE -> under a FULL delivery ONLY, every live subject missing
#                 from the delivery gets a DELETE row (basis FULL_ABSENCE).
#
# The core is delta-compressed, so absence cannot be re-derived later from
# it (unlike OBT's log): the delete must be written now.
# No UPDATE, no DELETE statement anywhere -- the triggers would refuse it.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"

params="$(sql_scalar "SELECT batch_ts||'|'||file_id FROM load_params;")"
[ -n "$params" ] || { echo "FATAL: load_params is empty" >&2; exit 1; }
echo "==> Loading core (batch_ts=${params%%|*}, record_source=${params#*|})"

META="'change_type','delete_basis','diff_str','load_ts','record_source'"

prefix() {  # prefix "a,b,c" s  ->  s.a,s.b,s.c
  local IFS=,; local -a parts; read -ra parts <<< "$1"
  local out="" c; for c in "${parts[@]}"; do out="${out:+$out,}$2.$c"; done
  printf '%s' "$out"; }
join_on() { # join_on "a,b" l s  ->  l.a = s.a AND l.b = s.b
  local IFS=,; local -a parts; read -ra parts <<< "$1"
  local out="" c; for c in "${parts[@]}"; do out="${out:+$out AND }$2.$c = $3.$c"; done
  printf '%s' "$out"; }

registry="$(sql_scalar "SELECT core_table||'|'||stage_table||'|'||stage_view||'|'||table_key
                        FROM core_table ORDER BY load_order;")"

OLDIFS="$IFS"; IFS=$'\n'
for line in $registry; do
  IFS="$OLDIFS"
  IFS='|' read -r tbl stg view fkey <<< "$line"
  [ "$(feed_rows "$stg")" -gt 0 ] || { IFS=$'\n'; continue; }
  mode="$(feed_mode "$stg")"

  # Payload = every core column that is not load metadata. The stage L2
  # view supplies each one under the same name -- that contract is the
  # whole mapping. A DELETE row carries only the key; the rest is NULL.
  cols="$(sql_scalar "SELECT group_concat(name, ',') FROM
            (SELECT name FROM pragma_table_info('$tbl')
             WHERE name NOT IN ($META) ORDER BY cid);")"
  delcols="$fkey"
  k1="${fkey%%,*}"
  latest="WITH l AS (SELECT * FROM (SELECT f.*, ROW_NUMBER() OVER
             (PARTITION BY $fkey ORDER BY load_ts DESC) AS rn FROM $tbl f) WHERE rn = 1)"

  before="$(sql_scalar "SELECT COUNT(*) FROM $tbl;")"

  sql_run "
    $latest
    INSERT INTO $tbl ($cols, change_type, delete_basis, diff_str, load_ts, record_source)
    SELECT $(prefix "$cols" s),
           CASE WHEN l.$k1 IS NULL OR l.change_type = 'DELETE' THEN 'INSERT' ELSE 'UPDATE' END,
           NULL, s.diff_str, p.batch_ts, p.file_id
    FROM $view s CROSS JOIN load_params p
    LEFT JOIN l ON $(join_on "$fkey" l s)
    WHERE s.op = 'UPSERT'
      AND (l.$k1 IS NULL OR l.change_type = 'DELETE' OR l.diff_str <> s.diff_str);"

  sql_run "
    $latest
    INSERT INTO $tbl ($delcols, extract_dt, change_type, delete_basis, diff_str, load_ts, record_source)
    SELECT $(prefix "$delcols" s), s.extract_dt, 'DELETE', 'TOMBSTONE', '<DELETED>',
           p.batch_ts, p.file_id
    FROM $view s CROSS JOIN load_params p
    JOIN l ON $(join_on "$fkey" l s)
    WHERE s.op = 'DELETE' AND l.change_type <> 'DELETE';"

  if [ "$mode" = "FULL" ]; then
    sql_run "
      $latest
      INSERT INTO $tbl ($delcols, extract_dt, change_type, delete_basis, diff_str, load_ts, record_source)
      SELECT $(prefix "$delcols" l), NULL, 'DELETE', 'FULL_ABSENCE', '<DELETED>',
             p.batch_ts, p.file_id
      FROM l CROSS JOIN load_params p
      WHERE l.change_type <> 'DELETE'
        AND NOT EXISTS (SELECT 1 FROM $view s WHERE $(join_on "$fkey" l s));"
  fi

  after="$(sql_scalar "SELECT COUNT(*) FROM $tbl;")"
  printf "    %-16s [%-11s]: %s row(s) written\n" "$tbl" "$mode" "$((after - before))"
  IFS=$'\n'
done
IFS="$OLDIFS"
