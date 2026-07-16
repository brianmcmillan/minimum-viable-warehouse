#!/usr/bin/env bash
# ---------------------------------------------------------------------
# ANCHOR LOADER -- identities and their *_REF business-key attributes.
#
# In Anchor even the business key is an attribute: the anchor row is
# pure identity (surrogate + metadata), the *_REF static attribute
# carries the identifier. The REF table is loaded first and acts as the
# key registry (MAX+ROW_NUMBER over it, base 1000, ORDER BY key --
# deterministic under ordered replay, exactly the Focal proof); the
# anchor row is then derived from it with a self-healing NOT IN, never
# an inst-gate (the lesson load_keys.sh taught the Focal demo).
#
# Tombstones never create identities. Only feeds present in this
# delivery are processed.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
echo "==> Loading anchors (batch_ts=$BATCH_TS)"
q_bts="$(sql_quote "$BATCH_TS")"

sql_run "SELECT anchor_mn||'|'||anchor_table||'|'||id_col||'|'||ref_table||'|'||ref_col
                ||'|'||source_system||'|'||source_entity
         FROM meta_anchor_map ORDER BY anchor_mn;" |
while IFS='|' read -r mn atab idc rtab rcol ss se; do
  [ "$(feed_present "$ss" "$se")" -gt 0 ] || continue
  atab="$(sql_ident "$atab")"; idc="$(sql_ident "$idc")"
  rtab="$(sql_ident "$rtab")"; rcol="$(sql_ident "$rcol")"
  q_ss="$(sql_quote "$ss")"; q_se="$(sql_quote "$se")"

  sql_run "
    INSERT INTO $rtab($idc, $rcol, Metadata_LDTS)
    SELECT (SELECT COALESCE(MAX($idc),1000) FROM $rtab)
             + ROW_NUMBER() OVER (ORDER BY s.bk),
           s.bk, '$q_bts'
    FROM (SELECT DISTINCT business_key AS bk FROM source_landing
          WHERE source_system='$q_ss' AND source_entity='$q_se' AND op='UPSERT') s
    WHERE s.bk NOT IN (SELECT $rcol FROM $rtab);

    INSERT INTO $atab($idc, Metadata_LDTS)
    SELECT DISTINCT r.$idc, '$q_bts' FROM $rtab r
    WHERE r.$idc NOT IN (SELECT $idc FROM $atab);"

  n="$(sql_scalar "SELECT COUNT(*) FROM $atab WHERE Metadata_LDTS='$q_bts';")"
  printf "    %-12s from %-14s : %s new identity(ies)\n" "$atab" "$ss.$se" "$n"
done
