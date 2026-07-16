#!/usr/bin/env bash
# KEY LOADER -- surrogate keys from UPSERT rows only (tombstones never
# create keys). Keys are stable; existing ones are reused.
source "$(dirname "$0")/lib.sh"
echo "==> Loading identifiers & surrogate keys (batch_ts=$BATCH_TS)"
q_bts="$(sql_quote "$BATCH_TS")"
# Only the feeds this delivery actually carries (see load_desc.sh).
#
# The ORDER BY is load-bearing, not tidiness. Keys are allocated as
# MAX(key)+ROW_NUMBER(), so within an entity the assignment depends on the
# order feeds are processed. rebuild.sh reproduces every surrogate key by
# replaying deliveries in load_seq order, and that only holds if this loop
# is deterministic too. Today each entity has exactly one IDFR feed and the
# question is moot; the day one gains a second, silence here would corrupt
# a rebuild rather than fail it.
sql_run "SELECT m.entity_id, m.source_system, m.source_entity
                 FROM meta_source_map m
                 WHERE m.role='IDFR' AND EXISTS (
                   SELECT 1 FROM source_landing_stage s
                   WHERE s.source_system=m.source_system AND s.source_entity=m.source_entity)
                 ORDER BY m.entity_id, m.source_system, m.source_entity;" |
while IFS='|' read -r entity ss se; do
  q_entity="$(sql_quote "$entity")"; q_ss="$(sql_quote "$ss")"; q_se="$(sql_quote "$se")"
  key_col="$(sql_ident "$(sql_scalar "SELECT key_col FROM meta_entity WHERE entity_id='$q_entity';")")"
  le="$(printf '%s' "$entity" | tr 'A-Z' 'a-z')"
  idfr_tbl="$(sql_ident "${le}_idfr")"; focal_tbl="$(sql_ident "${le}_focal")"
  idfr_col="$(sql_ident "${le}_idfr")"
  tmp="$(mktemp)"
  cat > "$tmp" <<SQL
INSERT INTO $idfr_tbl($idfr_col, eff_tmstp, ver_tmstp, row_st, $key_col,
                      data_key, inst_key, inst_row_key, popln_tmstp)
SELECT s.idfr, '$q_bts', '$q_bts', 'Y',
       (SELECT COALESCE(MAX($key_col),1000) FROM $idfr_tbl)
         + ROW_NUMBER() OVER (ORDER BY s.idfr),
       0, __INST__, 1, '$q_bts'
FROM (SELECT DISTINCT business_key AS idfr FROM source_landing
      WHERE source_system='$q_ss' AND source_entity='$q_se' AND op='UPSERT') s
WHERE s.idfr NOT IN (SELECT $idfr_col FROM $idfr_tbl);

-- Every identifier that has no focal row yet gets one. Deliberately NOT
-- restricted to identifiers this execution created (`i.inst_key=__INST__`):
-- that gate makes the step unable to repair itself if a crash ever lands
-- between the two inserts, and it silently produces an empty warehouse in
-- any design that seeds *_idfr before replaying. The NOT IN guard already
-- makes this idempotent.
INSERT INTO $focal_tbl($key_col, eff_tmstp, ver_tmstp, row_st,
                       data_key, inst_key, inst_row_key, popln_tmstp)
SELECT DISTINCT i.$key_col, '$q_bts', '$q_bts', 'Y', 0, __INST__, 1, '$q_bts'
FROM $idfr_tbl i
WHERE i.$key_col NOT IN (SELECT $key_col FROM $focal_tbl);
SQL
  inst="$(sql_int "$(log_procinst "IDFR:$entity:$ss.$se" "$tmp")")"
  sed "s/__INST__/$inst/g" "$tmp" | sql
  n="$(sql_scalar "SELECT COUNT(*) FROM $idfr_tbl WHERE inst_key=$inst;")"
  printf "    %-9s from %-14s : %s new identifier(s)\n" "$entity" "$ss.$se" "$n"
  rm -f "$tmp"
done
