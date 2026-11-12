#!/usr/bin/env bash
# ---------------------------------------------------------------------
# LOAD METRICS: METRIC_STG -> METRIC_STG2 -> METRIC_SAMPLE. One
# transaction.
#
# METRIC_STG carries names (res_type + res_alias, metric_code,
# provider_name). METRIC_STG2 is the same rows with every name resolved
# to its surrogate: res_id through RES_ALIAS, metric_id, provider_id.
# A row that does not resolve fails the load.
#
# A sample is an OBSERVATION. The same value seen again at a later time
# is a new sample, and that is not a restatement to suppress: it is what
# the table is for. The primary key makes a re-delivered observation
# harmless. A different value for an existing key is a correction, and
# it overwrites -- the mart keeps no correction history; the archive does.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"

sql_tx "
BEGIN;
DELETE FROM load_guard;
DELETE FROM metric_stg2;

INSERT INTO metric_stg2(sequence_no, batch_no, res_id, metric_id, start_utc_ts, provider_id,
                        value_type, res_tz_code, start_lcl_ts, duration, summary_level,
                        value, value_max, value_min, value_cnt, sample_tz_code, start_ts, srcd_ts)
SELECT s.sequence_no, s.batch_no, a.res_id, m.metric_id, s.start_ts, p.provider_id,
       m.value_type, COALESCE(r.res_tz_code,'UTC'), s.start_ts, s.duration, s.summary_level,
       s.value, s.value_max, s.value_min, s.value_cnt, s.sample_tz_code, s.start_ts, s.srcd_ts
FROM metric_stg s
LEFT JOIN res_alias a ON a.res_type=s.res_type AND a.res_alias=s.res_alias
LEFT JOIN res r       ON r.res_id=a.res_id
LEFT JOIN metric m    ON m.metric_code=s.metric_code
LEFT JOIN provider p  ON p.provider_name=s.provider_name;

INSERT INTO load_guard(rule, violations)
SELECT 'METRIC_STG row with an unresolved resource, metric or provider', COUNT(*)
FROM metric_stg2 WHERE res_id IS NULL OR metric_id IS NULL OR provider_id IS NULL;

INSERT INTO metric_sample(res_id, metric_id, sample_utc_ts, provider_id, value,
                          res_tz_code, sample_lcl_ts, srcd_d2k)
SELECT res_id, metric_id, start_utc_ts, provider_id, value, res_tz_code, start_lcl_ts,
       CAST(julianday(date(srcd_ts)) - julianday('2000-01-01') AS INTEGER)
FROM metric_stg2
WHERE summary_level IS NULL AND value IS NOT NULL
ON CONFLICT(res_id, metric_id, sample_utc_ts, provider_id)
DO UPDATE SET value=excluded.value, srcd_d2k=excluded.srcd_d2k
WHERE metric_sample.value IS NOT excluded.value;

DELETE FROM load_guard;
COMMIT;"

printf "    metrics: %s staged, %s sample(s) held\n" \
  "$(sql_scalar "SELECT COUNT(*) FROM metric_stg2;")" \
  "$(sql_scalar "SELECT COUNT(*) FROM metric_sample;")"
