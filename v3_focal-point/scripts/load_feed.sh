#!/usr/bin/env bash
# ---------------------------------------------------------------------
# DELIVERY DRIVER -- ingest ONE delivery file, safely.
#   usage: load_feed.sh <delivery.sql> <file_id>
#
# CAPTURE THE RAW INPUT, THEN APPLY IT. In that order, always. A delivery
# that crashes half-way through the loaders is still archived, so the
# retry replays byte-identical input instead of whatever the extractor
# happens to be emitting by then. This is the property that makes the
# derived warehouse disposable.
#
#   * load control: a file_id already COMPLETE is skipped, so an
#     overwritten/re-sent file is never ingested twice. Identity is the
#     delivery id, not the filename -- the extractor reuses filenames.
#   * the delivery is only marked COMPLETE after every loader succeeds;
#     a half-applied delivery stays retryable rather than being skipped
#     as "done".
#   * archiving is idempotent: INSERT OR IGNORE, which (unlike OR REPLACE)
#     does not fire the archive's append-only delete trigger.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
FILE="${1:?usage: load_feed.sh <delivery.sql> <file_id>}"
FILE_ID="${2:?usage: load_feed.sh <delivery.sql> <file_id>}"
q_file_id="$(sql_quote "$FILE_ID")"
q_bts="$(sql_quote "$BATCH_TS")"

echo "############################################################"
echo "# DELIVERY: $FILE   id=$FILE_ID   (ts=$BATCH_TS)"
echo "############################################################"

# Stage BEFORE deciding whether to skip. A file_id names a delivery's
# CONTENT, so the only way to know a re-sent file really is the same
# delivery is to look at it. Skipping on the id alone would let an
# extractor silently overwrite a delivery's contents and have the change
# ignored -- the archive would then no longer describe what was applied.
sql_run "DELETE FROM source_landing_stage;"
sql_file "$FILE"
rc="$(sql_int "$(sql_scalar "SELECT COUNT(*) FROM source_landing_stage;")")"

prev_status="$(asql_scalar "SELECT status FROM arch.loaded_files WHERE file_id='$q_file_id';")"
if [ -n "$prev_status" ]; then
  # Exact comparison, order included: seq_nbr drives the dedup tiebreak, so
  # the same rows in a different order are a different delivery. Skipped when
  # nothing was archived yet (a crash before the archive write).
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
      echo "       ($drift row(s) differ; staged $rc row(s))." >&2
      echo "       A file_id identifies a delivery's CONTENT, not a filename." >&2
      echo "       Issue a new file_id for new content." >&2
      exit 1; }
  fi

  if [ "$prev_status" = "COMPLETE" ]; then
    echo "==> SKIP duplicate delivery '$FILE_ID' (already COMPLETE in loaded_files)"; exit 0
  fi
  echo "==> RETRY of delivery '$FILE_ID' (previously STARTED, never COMPLETE)"
else
  # Claim a load_seq on first sight of this file_id. It is never reallocated:
  # rebuild.sh replays in this order, and the surrogate keys depend on it.
  asql_run "INSERT INTO arch.loaded_files(file_id, load_seq, batch_ts, status, row_count)
            VALUES('$q_file_id',
                   COALESCE((SELECT MAX(load_seq) FROM arch.loaded_files),0)+1,
                   '$q_bts','STARTED',$rc);"
fi

# ---- capture the raw delivery, verbatim and pre-dedup ----------------
# seq_nbr is the staged rowid: replay restores stage in this order because
# the dedup tiebreak reads it. load_seq/batch_ts are denormalised so the
# archive can replay without consulting focal.db at all.
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

# ---- now apply it ----------------------------------------------------
"$(dirname "$0")/apply_delivery.sh"

# Mark COMPLETE only after every loader has succeeded. If one crashes,
# set -e aborts before this update, so the delivery stays STARTED and the
# retry re-applies it instead of skipping it forever.
asql_run "UPDATE arch.loaded_files SET status='COMPLETE' WHERE file_id='$q_file_id';"
echo "==> Delivery complete."
