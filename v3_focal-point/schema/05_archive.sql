-- =====================================================================
-- FOCAL :: RAW LAYER (the archive database -- a separate file)
-- ---------------------------------------------------------------------
-- Everything else in this project is derived. This is not. Every delivery
-- ever accepted is captured here, verbatim and unmodified, BEFORE it is
-- applied. rebuild.sh replays it to regenerate the whole warehouse.
--
-- Three properties make that work:
--
--   1. APPEND-ONLY, absolutely. The triggers below have no unlock path,
--      because nothing in this project has any business deleting a raw
--      fact. (An earlier design pruned old deliveries and therefore
--      needed an escape hatch. Retaining everything is what lets the
--      guarantee be a guarantee.)
--
--   2. SELF-DESCRIBING. load_seq and batch_ts are denormalised onto every
--      history row, so the archive replays even if focal.db is destroyed
--      outright -- it does not depend on the derived database for
--      anything, not even to know what order the deliveries arrived in.
--
--   3. COMPLETE. Because no delivery is ever dropped, replaying them all
--      in load_seq order re-runs surrogate-key assignment against
--      identical prior state, and reproduces every key exactly. Keys are
--      therefore DERIVED, not preserved. Prune even one delivery and that
--      stops being true -- see INCREMENTAL.md.
--
-- Applied with IF NOT EXISTS by init_db.sh, which never drops this file.
-- =====================================================================

-- Load control. Lives here, not in focal.db, because it must outlive the
-- derived warehouse: rebuild.sh reads it to know what to replay and in
-- what order.
CREATE TABLE IF NOT EXISTS loaded_files (
    file_id    TEXT PRIMARY KEY,        -- delivery identity (batch/version, NOT the filename:
                                        -- the extractor overwrites filenames)
    load_seq   INTEGER NOT NULL UNIQUE, -- replay order; assigned once, on first sight of file_id
    batch_ts   TEXT    NOT NULL,        -- logical load ts; reproduces eff_tmstp / ver_tmstp
    status     TEXT    NOT NULL DEFAULT 'STARTED',  -- STARTED | COMPLETE
    loaded_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    row_count  INTEGER                  -- staged rows; guards a file_id reused with new content
);

-- The raw layer itself: one row per (delivery, staged row), captured
-- pre-dedup. Recency de-duplication is loader behaviour and must be
-- REPRODUCED by replay, not baked in here.
CREATE TABLE IF NOT EXISTS source_landing_history (
    file_id        TEXT    NOT NULL REFERENCES loaded_files(file_id),
    load_seq       INTEGER NOT NULL,    -- denormalised: see property 2 above
    batch_ts       TEXT    NOT NULL,    -- denormalised: see property 2 above
    seq_nbr        INTEGER NOT NULL,    -- the staged rowid. LOAD-BEARING: the dedup tiebreak in
                                        -- apply_delivery.sh is `ORDER BY extract_ts DESC, rowid
                                        -- DESC`, so replay must restore stage in this order or a
                                        -- duplicate attribute can resolve to the wrong value.
    source_system  TEXT    NOT NULL,
    source_entity  TEXT    NOT NULL,
    business_key   TEXT    NOT NULL,
    attribute_name TEXT    NOT NULL,
    value_str      TEXT,
    value_num      REAL,
    value_ts       TEXT,
    extract_ts     TEXT    NOT NULL,
    op             TEXT    NOT NULL,    -- UPSERT | DELETE (tombstone)
    load_mode      TEXT,                -- FULL | INCREMENTAL (per delivery)
    archived_at    TEXT    NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (file_id, seq_nbr)
);

CREATE INDEX IF NOT EXISTS ix_slh_replay ON source_landing_history(load_seq);
CREATE INDEX IF NOT EXISTS ix_slh_feed   ON source_landing_history(source_system, source_entity);

-- Append-only, enforced. Not a comment: a trigger, with no way around it.
-- Note INSERT OR IGNORE does NOT fire this (unlike INSERT OR REPLACE),
-- which is what makes re-archiving a retried delivery a safe no-op.
CREATE TRIGGER IF NOT EXISTS trg_slh_no_update
BEFORE UPDATE ON source_landing_history
BEGIN SELECT RAISE(ABORT,'source_landing_history is append-only'); END;

CREATE TRIGGER IF NOT EXISTS trg_slh_no_delete
BEFORE DELETE ON source_landing_history
BEGIN SELECT RAISE(ABORT,'source_landing_history is append-only'); END;
