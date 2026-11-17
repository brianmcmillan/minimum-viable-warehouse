-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- DRIVING-KEY RE-POINT: OMS corrects order O-101 to customer C001.
-- In the Activity Schema an activity never changes, so C002's
-- placed_order stays exactly where it is. The re-point is a NEW
-- activity, order_reassigned, written to C001's stream with
-- feature_json.from_customer = 'C002'. Current owner = the customer on
-- the order's newest activity (LAST EVER on link = 'O-101').
--
-- The data row is byte-identical with the sibling demos' d6 fixture.
INSERT INTO stg_order_l1(order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode) VALUES
('O-101','C001','P',19.5,'USD','2026-02-02 11:30','2027-02-01','UPSERT','INCREMENTAL');
