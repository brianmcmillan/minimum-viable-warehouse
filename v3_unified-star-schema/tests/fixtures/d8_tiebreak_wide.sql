-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- SAME-EXTRACT TIEBREAK, the same rows as the Anchor, Focal and metrics
-- mart fixture d6_tiebreak_wide.sql. C004 arrives TWICE in one delivery
-- with an IDENTICAL extract_dt, so recency cannot decide and the stage-2
-- dedup (`ORDER BY extract_dt DESC, rowid DESC`) falls back to physical
-- row order: the LAST row in the file must win, 'last@x.com'.
--
-- This is the case that makes the archive's seq_nbr load-bearing through
-- replay: rebuild.sh must restore the stage in seq_nbr order, or the
-- rebuilt core resolves the tie the other way.
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C004','Dana Ellis','first@x.com','2027-01-15','2027-02-01','UPSERT','INCREMENTAL'),
('C004','Dana Ellis','last@x.com' ,'2027-01-15','2027-02-01','UPSERT','INCREMENTAL');
