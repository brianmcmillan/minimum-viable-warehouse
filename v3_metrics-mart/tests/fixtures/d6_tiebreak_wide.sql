-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- The wide-delivery form of d6_tiebreak.sql: C004 arrives TWICE in one
-- delivery with an IDENTICAL extract_dt, so recency cannot decide and the
-- dedup tiebreak (`ORDER BY extract_ts DESC, rowid DESC`) falls back to
-- physical row order -- the LAST row in the file must win: 'last@x.com'.
--
-- This is the case that makes the archive's seq_nbr load-bearing through
-- replay: rebuild must restore the wide stage in seq_nbr order, and
-- stage_narrow.sh must keep that order within every (key, attribute), or
-- the rebuilt warehouse disagrees with the ingested one.
--
-- d6_tiebreak.sql (narrow, unchanged) still tests the same tiebreak at the
-- attribute level, straight into the narrow stage (level 2).
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C004','Dana Ellis','first@x.com','2027-01-15','2027-02-01','UPSERT','INCREMENTAL'),
('C004','Dana Ellis','last@x.com' ,'2027-01-15','2027-02-01','UPSERT','INCREMENTAL');
