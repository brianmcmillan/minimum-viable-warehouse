-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- DRIVING-KEY RE-POINT: OMS corrects order O-101 to customer C001. The
-- link table gains the (O-101,C001) pair; the effectivity satellite opens
-- it, which closes (O-101,C002) by LEAD computation -- no update, no
-- delete, and the order now has exactly ONE current customer.
--
-- This is the scenario the Focal demo's load_rel.sh cannot yet express:
-- there, the new pair would be inserted and the old one left active.
--
-- Every order attribute is unchanged, so rv_order_hsat writes NOTHING --
-- the re-point is purely a relationship event.
INSERT INTO stg_order_l1(order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode) VALUES
('O-101','C001','P',19.5,'USD','2026-02-02 11:30','2027-02-01','UPSERT','INCREMENTAL');
