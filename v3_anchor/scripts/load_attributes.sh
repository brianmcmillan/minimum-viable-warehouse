#!/usr/bin/env bash
# ---------------------------------------------------------------------
# ATTRIBUTE LOADER -- one metadata-driven loop, many typed tables.
#
# Structurally this is the Focal demo's load_desc.sh with one change:
# each iteration inserts into THAT ATTRIBUTE'S OWN typed table instead
# of writing a type_key row into a generic one. Everything else is the
# shared discipline:
#
#   * RESTATEMENT CONTROL (Anchor's own name for it): a historized
#     attribute inserts only when the delivered value differs from the
#     anchor's latest row -- the NOCHANGE no-op of the sibling demos.
#     Static attributes insert on first sight only.
#   * KNOTS ARE CLOSED DOMAINS: a knotted value that resolves to no
#     knot member fails the load. An unseen code is a data-quality
#     error, not a new member.
#   * PRESENCE IS DATA: after the mapped attributes, each entity's
#     EST (existence) knotted attribute is synthesised --
#       EXISTS  on upsert while the latest assertion is missing/DELETED
#       DELETED on tombstone, ALWAYS
#       DELETED on absence, ONLY when the delivery is FULL
#     Change-only, like every other attribute. Anchor has no row_st to
#     flip; deletion must be modeled, which is why the ghost-row gap
#     the Focal demo documents cannot arise here.
#
# Attribute rows are never closed or deleted -- history is append-only
# and end dates are computed on the way out.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
echo "==> Loading attributes (batch_ts=$BATCH_TS)"
q_bts="$(sql_quote "$BATCH_TS")"

# ---- mapped attributes -------------------------------------------------
sql_run "SELECT m.source_system||'|'||m.source_entity||'|'||m.source_attribute||'|'||
                m.attr_table||'|'||m.attr_col||'|'||m.slot||'|'||m.historized||'|'||
                COALESCE(m.knot_table,'')||'|'||COALESCE(m.knot_id_col,'')||'|'||
                COALESCE(m.knot_val_col,'')||'|'||a.ref_table||'|'||a.ref_col||'|'||a.id_col
         FROM meta_attribute_map m JOIN meta_anchor_map a ON a.anchor_mn=m.anchor_mn
         ORDER BY m.attr_table;" |
while IFS='|' read -r ss se sattr atab acol slot hist ktab kid kval rtab rcol idc; do
  [ "$(feed_present "$ss" "$se")" -gt 0 ] || continue
  atab="$(sql_ident "$atab")"; acol="$(sql_ident "$acol")"
  rtab="$(sql_ident "$rtab")"; rcol="$(sql_ident "$rcol")"; idc="$(sql_ident "$idc")"
  case "$slot" in value_str|value_num|value_ts) ;; *)
    echo "FATAL: bad slot '$slot' in meta_attribute_map" >&2; exit 1;; esac
  q_ss="$(sql_quote "$ss")"; q_se="$(sql_quote "$se")"; q_at="$(sql_quote "$sattr")"

  # Delivered values at anchor grain (landing is already recency-deduped).
  SRC="SELECT r.$idc AS id, sl.$slot AS raw
       FROM source_landing sl
       JOIN $rtab r ON r.$rcol = sl.business_key
       WHERE sl.source_system='$q_ss' AND sl.source_entity='$q_se'
         AND sl.attribute_name='$q_at' AND sl.op='UPSERT'"

  if [ -n "$ktab" ]; then
    ktab="$(sql_ident "$ktab")"; kid="$(sql_ident "$kid")"; kval="$(sql_ident "$kval")"
    bad="$(sql_scalar "SELECT COUNT(*) FROM ($SRC) s
                       LEFT JOIN $ktab k ON k.$kval = s.raw WHERE k.$kid IS NULL;")"
    [ "$bad" -eq 0 ] || {
      echo "FATAL: $bad value(s) for $ss.$se.$sattr resolve to no $ktab member." >&2
      echo "       A knot is a closed domain; extend the seed, do not invent members." >&2
      exit 1; }
    VAL="k.$kid"; KJOIN="JOIN $ktab k ON k.$kval = s.raw"
  else
    VAL="s.raw"; KJOIN=""
  fi

  if [ "$hist" = "1" ]; then
    sql_run "
      INSERT INTO $atab($idc, $acol, ChangedAt, Metadata_LDTS)
      SELECT s.id, $VAL, '$q_bts', '$q_bts'
      FROM ($SRC) s $KJOIN
      LEFT JOIN (SELECT $idc AS id, $acol AS cur, ROW_NUMBER() OVER
                   (PARTITION BY $idc ORDER BY ChangedAt DESC) rn FROM $atab) t
             ON t.id = s.id AND t.rn = 1
      WHERE t.id IS NULL OR t.cur IS NOT $VAL;"
  else
    sql_run "
      INSERT INTO $atab($idc, $acol, Metadata_LDTS)
      SELECT s.id, $VAL, '$q_bts'
      FROM ($SRC) s $KJOIN
      WHERE s.id NOT IN (SELECT $idc FROM $atab);"
  fi
  n="$(sql_scalar "SELECT COUNT(*) FROM $atab WHERE Metadata_LDTS='$q_bts';")"
  printf "    %-28s : %s row(s)\n" "$atab" "$n"
done

# ---- existence (presence) synthesis -------------------------------------
sql_run "SELECT anchor_mn||'|'||est_table||'|'||id_col||'|'||ref_table||'|'||ref_col
                ||'|'||source_system||'|'||source_entity
         FROM meta_anchor_map ORDER BY anchor_mn;" |
while IFS='|' read -r mn etab idc rtab rcol ss se; do
  [ "$(feed_present "$ss" "$se")" -gt 0 ] || continue
  etab="$(sql_ident "$etab")"; idc="$(sql_ident "$idc")"
  rtab="$(sql_ident "$rtab")"; rcol="$(sql_ident "$rcol")"
  mode="$(feed_mode "$ss" "$se")"
  q_ss="$(sql_quote "$ss")"; q_se="$(sql_quote "$se")"

  LATEST="(SELECT $idc AS id, EST_ID, ROW_NUMBER() OVER
             (PARTITION BY $idc ORDER BY ChangedAt DESC) rn FROM $etab)"

  ABS=""
  [ "$mode" = "FULL" ] && ABS="
    INSERT INTO $etab($idc, EST_ID, ChangedAt, Metadata_LDTS)
    SELECT t.id, 2, '$q_bts', '$q_bts'
    FROM $LATEST t JOIN $rtab r ON r.$idc = t.id
    WHERE t.rn=1 AND t.EST_ID=1
      AND r.$rcol NOT IN (SELECT business_key FROM source_landing
                          WHERE source_system='$q_ss' AND source_entity='$q_se');"

  sql_run "
    INSERT INTO $etab($idc, EST_ID, ChangedAt, Metadata_LDTS)
    SELECT r.$idc, 1, '$q_bts', '$q_bts'
    FROM (SELECT DISTINCT business_key AS bk FROM source_landing
          WHERE source_system='$q_ss' AND source_entity='$q_se' AND op='UPSERT') s
    JOIN $rtab r ON r.$rcol = s.bk
    WHERE COALESCE((SELECT t.EST_ID FROM $LATEST t WHERE t.id=r.$idc AND t.rn=1),2)=2;

    INSERT INTO $etab($idc, EST_ID, ChangedAt, Metadata_LDTS)
    SELECT r.$idc, 2, '$q_bts', '$q_bts'
    FROM (SELECT DISTINCT business_key AS bk FROM source_landing
          WHERE source_system='$q_ss' AND source_entity='$q_se' AND op='DELETE') s
    JOIN $rtab r ON r.$rcol = s.bk
    WHERE COALESCE((SELECT t.EST_ID FROM $LATEST t WHERE t.id=r.$idc AND t.rn=1),2)=1;
    $ABS"
  n="$(sql_scalar "SELECT COUNT(*) FROM $etab WHERE Metadata_LDTS='$q_bts';")"
  printf "    %-28s [%-11s]: %s assertion(s)\n" "$etab" "$mode" "$n"
done
