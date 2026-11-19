#!/usr/bin/env bash
# ---------------------------------------------------------------------
# LOAD METRICS: METRIC_STG -> METRIC_STG2 -> METRIC_SAMPLE. One
# transaction.
#
# METRIC_STG carries names (res_type + res_alias, metric_code,
# provider_name). METRIC_STG2 is the same rows with every name resolved
# to its surrogate: res_id through RES_ALIAS, metric_id, provider_id.
# A row that does not resolve fails the load, and so does a sample
# dated outside CALNDR.
#
# A sample is a VALUE FIRST SEEN OR CHANGED. A staged value is written
# only when it differs from the sample in force before it -- the newest
# sample, stored or staged, earlier than it in the same resource, metric
# and provider (NOCHANGE). So A, B, A writes three samples and A, A, A
# writes one. Values are compared in the stored type (FLOAT) and with
# IS NOT, so NULL-safe.
#
# A value seen again moves only last_seen_utc_ts on the sample in force
# at that time, and only forward (MAX): a delivery with an earlier
# extract never moves it back. Nothing else on a sample changes, except
# a correction: a different value for an existing key overwrites value
# and srcd_d2k -- the mart keeps no correction history; the archive
# does. trg_metric_sample_nu refuses every other change.
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

-- Weeks come from CALNDR, so a sample dated outside it would drop out of
-- every weekly rollup. Fail the load instead.
INSERT INTO load_guard(rule, violations)
SELECT 'metric sample dated outside CALNDR', COUNT(*)
FROM metric_stg2 s
WHERE s.summary_level IS NULL AND s.value IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM calndr c WHERE c.calndr_date = date(s.start_utc_ts));

-- The staged samples, in the stored type: t_in.value has the same FLOAT
-- affinity as metric_sample.value.
CREATE TEMP TABLE t_in(res_id INTEGER, metric_id INTEGER, sample_utc_ts TIMESTAMP,
                       provider_id INTEGER, value FLOAT, res_tz_code CHAR(6),
                       sample_lcl_ts TIMESTAMP, srcd_d2k SMALLINT);
INSERT INTO t_in
SELECT res_id, metric_id, start_utc_ts, provider_id, value, res_tz_code, start_lcl_ts,
       CAST(julianday(date(srcd_ts)) - julianday('2000-01-01') AS INTEGER)
FROM metric_stg2
WHERE summary_level IS NULL AND value IS NOT NULL;

-- The timeline each staged value is compared against: the stored samples
-- of the same series, plus the staged values (a staged value replaces a
-- stored sample with the same key).
CREATE TEMP TABLE t_tl AS
SELECT res_id, metric_id, provider_id, sample_utc_ts, value FROM metric_sample m
WHERE EXISTS (SELECT 1 FROM t_in i WHERE i.res_id=m.res_id AND i.metric_id=m.metric_id
                                     AND i.provider_id=m.provider_id)
  AND NOT EXISTS (SELECT 1 FROM t_in i WHERE i.res_id=m.res_id AND i.metric_id=m.metric_id
                                         AND i.provider_id=m.provider_id
                                         AND i.sample_utc_ts=m.sample_utc_ts)
UNION ALL
SELECT res_id, metric_id, provider_id, sample_utc_ts, value FROM t_in;

-- NOCHANGE: a staged value is written when it differs from the value
-- before it on the timeline. A staged row whose key is already stored
-- goes to the upsert as well: the same value writes nothing, a different
-- one is a correction.
INSERT INTO metric_sample(res_id, metric_id, sample_utc_ts, provider_id, value,
                          res_tz_code, sample_lcl_ts, srcd_d2k, last_seen_utc_ts)
SELECT i.res_id, i.metric_id, i.sample_utc_ts, i.provider_id, i.value,
       i.res_tz_code, i.sample_lcl_ts, i.srcd_d2k, i.sample_utc_ts
FROM t_in i
WHERE (SELECT p.value FROM t_tl p
        WHERE p.res_id=i.res_id AND p.metric_id=i.metric_id AND p.provider_id=i.provider_id
          AND p.sample_utc_ts < i.sample_utc_ts
        ORDER BY p.sample_utc_ts DESC LIMIT 1) IS NOT i.value
   OR EXISTS (SELECT 1 FROM metric_sample m
               WHERE m.res_id=i.res_id AND m.metric_id=i.metric_id
                 AND m.provider_id=i.provider_id AND m.sample_utc_ts=i.sample_utc_ts)
ON CONFLICT(res_id, metric_id, sample_utc_ts, provider_id)
DO UPDATE SET value=excluded.value, srcd_d2k=excluded.srcd_d2k
WHERE metric_sample.value IS NOT excluded.value;

-- LAST SEEN: every staged value is a sighting of the sample in force at
-- its time (the newest sample at or before it). Move that sample's
-- last_seen_utc_ts forward to the latest sighting, never back.
CREATE TEMP TABLE t_seen AS
SELECT res_id, metric_id, provider_id, in_force_utc_ts, MAX(sample_utc_ts) AS seen_utc_ts
FROM (SELECT i.res_id, i.metric_id, i.provider_id, i.sample_utc_ts,
             (SELECT m.sample_utc_ts FROM metric_sample m
               WHERE m.res_id=i.res_id AND m.metric_id=i.metric_id
                 AND m.provider_id=i.provider_id AND m.sample_utc_ts <= i.sample_utc_ts
               ORDER BY m.sample_utc_ts DESC LIMIT 1) AS in_force_utc_ts
      FROM t_in i)
GROUP BY res_id, metric_id, provider_id, in_force_utc_ts;

UPDATE metric_sample
SET last_seen_utc_ts = MAX(metric_sample.last_seen_utc_ts, t.seen_utc_ts)
FROM t_seen t
WHERE t.res_id=metric_sample.res_id AND t.metric_id=metric_sample.metric_id
  AND t.provider_id=metric_sample.provider_id AND t.in_force_utc_ts=metric_sample.sample_utc_ts;

DELETE FROM load_guard;
COMMIT;"

printf "    metrics: %s staged, %s sample(s) held\n" \
  "$(sql_scalar "SELECT COUNT(*) FROM metric_stg2;")" \
  "$(sql_scalar "SELECT COUNT(*) FROM metric_sample;")"
