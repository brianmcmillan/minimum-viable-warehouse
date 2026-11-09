-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- DRIVING-KEY RE-POINT: OMS corrects order O-101 to customer C001.
-- The core writes a new core_order row (customer_ref is in the diff).
-- The USS refresh then re-derives the bridge: the Orders stage row AND
-- the Order line stage row for O-101 now both carry _key_customer=C001,
-- because the line reaches its customer through its order.
--
-- The data row is byte-identical with the sibling demos' d6 fixture.
INSERT INTO stg_order_l1(order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode) VALUES
('O-101','C001','P',19.5,'USD','2026-02-02 11:30','2027-02-01','UPSERT','INCREMENTAL');
