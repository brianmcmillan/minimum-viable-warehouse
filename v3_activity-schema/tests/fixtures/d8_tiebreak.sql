-- TEST FIXTURE (Activity Schema only; not part of the demo sequence).
--
-- Two ordering guarantees the shared scenario never stresses:
--   * TIEBREAK: C001 delivered twice with the SAME extract_dt. Stage L2
--     breaks the tie by staged order (rowid DESC): the later row wins.
--     Replay must restore stage in seq_nbr order, or the rebuilt stream
--     resolves the tie the other way.
--   * KEY ORDER: C005 is staged before C004. Activities are numbered in
--     business-key order (not staged or scan order), so C004's
--     signed_up gets the lower activity_id -- on ingest and on replay.
--     The two order lines stress the same rule where it bites: stage
--     L2 sorts lines by (order_ref, sku), the loader numbers them by
--     (sku, order_ref), and the two orders disagree for this pair.
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C005','Eve Park','eve@x.com','2027-04-01','2027-04-01','UPSERT','INCREMENTAL'),
('C004','Dan Wu','dan@x.com','2027-04-01','2027-04-01','UPSERT','INCREMENTAL'),
('C001','Alice Smith','tie-first@x.com','2026-01-05','2027-04-01','UPSERT','INCREMENTAL'),
('C001','Alice Smith','tie-second@x.com','2026-01-05','2027-04-01','UPSERT','INCREMENTAL');
INSERT INTO stg_order_line_l1(order_ref, sku, extract_dt, op, load_mode) VALUES
('O-100','SKU-3','2027-04-01','UPSERT','INCREMENTAL'),
('O-101','SKU-1','2027-04-01','UPSERT','INCREMENTAL');
