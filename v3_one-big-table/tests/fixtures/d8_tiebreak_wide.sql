-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- SAME-EXTRACT TIEBREAK, the same rows as the sibling d8/d9 tiebreak
-- fixtures. C004 arrives TWICE in one delivery with an IDENTICAL
-- extract_dt, so load_seq and recency cannot decide and the refresh's
-- ranking (`ORDER BY load_seq DESC, extract_dt DESC, seq_nbr DESC`)
-- falls back to the archive's seq_nbr: the LAST row in the file must
-- win, 'last@x.com'. OBT's rebuild is the same refresh, so it must
-- resolve the tie the same way.
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C004','Dana Ellis','first@x.com','2027-01-15','2027-02-01','UPSERT','INCREMENTAL'),
('C004','Dana Ellis','last@x.com' ,'2027-01-15','2027-02-01','UPSERT','INCREMENTAL');
