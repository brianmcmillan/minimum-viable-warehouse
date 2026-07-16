#!/usr/bin/env bash
# ---------------------------------------------------------------------
# DELIVERY DRIVER -- ingest ONE delivery file, safely.
#   usage: load_feed.sh <delivery.sql> <file_id>
#
# The Focal archive discipline, unchanged: capture raw, then apply.
#   * skip only if the file_id is COMPLETE; COMPLETE only after every
#     loader succeeds, so a half-applied delivery stays retryable.
#   * the delivery is archived verbatim (pre-dedup) BEFORE any loader
#     runs; content re-sent under a used file_id must match what was
#     archived, row for row and in order.
#   * success clears the stage; a crash leaves it as forensics.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
FILE="${1:?usage: load_feed.sh <delivery.sql> <file_id>}"
FILE_ID="${2:?usage: load_feed.sh <delivery.sql> <file_id>}"
q_file_id="$(sql_quote "$FILE_ID")"
q_bts="$(sql_quote "$BATCH_TS")"

echo "############################################################"
echo "# DELIVERY: $FILE   id=$FILE_ID   (ts=$BATCH_TS)"
echo "############################################################"

# Stage BEFORE deciding whether to skip: a file_id names a delivery's
# CONTENT, and the only way to know a re-sent file is the same delivery
# is to look at it.
sql_run "DELETE FROM source_landing_stage;"
sql_file "$FILE"
rc="$(sql_int "$(sql_scalar "SELECT COUNT(*) FROM source_landing_stage;")")"

prev_status="$(asql_scalar "SELECT status FROM arch.loaded_files WHERE file_id='$q_file_id';")"
if [ -n "$prev_status" ]; then
  if [ "$(asql_scalar "SELECT COUNT(*) FROM arch.source_landing_history
                       WHERE file_id='$q_file_id';")" -gt 0 ]; then
    drift="$(sql_int "$(asql_scalar "
      WITH staged AS (
        SELECT rowid AS n, source_system,source_entity,business_key,attribute_name,
               value_str,value_num,value_ts,extract_ts,op,load_mode
        FROM source_landing_stage),
      archived AS (
        SELECT seq_nbr AS n, source_system,source_entity,business_key,attribute_name,
               value_str,value_num,value_ts,extract_ts,op,load_mode
        FROM arch.source_landing_history WHERE file_id='$q_file_id')
      SELECT (SELECT COUNT(*) FROM (SELECT * FROM staged EXCEPT SELECT * FROM archived))
           + (SELECT COUNT(*) FROM (SELECT * FROM archived EXCEPT SELECT * FROM staged));")")"
    [ "$drift" -eq 0 ] || {
      echo "FATAL: '$FILE' differs from the delivery already archived as '$FILE_ID'" >&2
      echo "       ($drift row(s) differ). A file_id identifies CONTENT; issue a new one." >&2
      exit 1; }
  fi
  if [ "$prev_status" = "COMPLETE" ]; then
    sql_run "DELETE FROM source_landing_stage;"
    echo "==> SKIP duplicate delivery '$FILE_ID' (already COMPLETE in loaded_files)"; exit 0
  fi
  echo "==> RETRY of delivery '$FILE_ID' (previously STARTED, never COMPLETE)"
else
  asql_run "INSERT INTO arch.loaded_files(file_id, load_seq, batch_ts, status, row_count)
            VALUES('$q_file_id',
                   COALESCE((SELECT MAX(load_seq) FROM arch.loaded_files),0)+1,
                   '$q_bts','STARTED',$rc);"
fi

asql_run "
  INSERT OR IGNORE INTO arch.source_landing_history(
      file_id, load_seq, batch_ts, seq_nbr,
      source_system, source_entity, business_key, attribute_name,
      value_str, value_num, value_ts, extract_ts, op, load_mode)
  SELECT '$q_file_id',
         (SELECT load_seq FROM arch.loaded_files WHERE file_id='$q_file_id'),
         (SELECT batch_ts FROM arch.loaded_files WHERE file_id='$q_file_id'),
         s.rowid,
         s.source_system, s.source_entity, s.business_key, s.attribute_name,
         s.value_str, s.value_num, s.value_ts, s.extract_ts, s.op, s.load_mode
  FROM source_landing_stage s;"

arc="$(sql_int "$(asql_scalar "SELECT COUNT(*) FROM arch.source_landing_history
                               WHERE file_id='$q_file_id';")")"
[ "$arc" = "$rc" ] || {
  echo "FATAL: archived $arc row(s) but staged $rc for '$FILE_ID'." >&2; exit 1; }
echo "==> Archived $arc raw row(s) for delivery '$FILE_ID'"

"$(dirname "$0")/apply_delivery.sh"

asql_run "UPDATE arch.loaded_files SET status='COMPLETE' WHERE file_id='$q_file_id';"

# Success clears the workbench; a crashed delivery keeps its staged rows.
sql_run "DELETE FROM source_landing_stage;"
echo "==> Delivery complete."
