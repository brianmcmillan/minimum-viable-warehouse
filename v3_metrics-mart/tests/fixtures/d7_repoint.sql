-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- DRIVING-ROLE RE-POINT, the same row as the d6_repoint fixture used by
-- the DV and Kimball demos: OMS corrects order O-101 to customer
-- C001, every other attribute unchanged. The historized tie appends a
-- new pairing (superseding O-101->C002 by ChangedAt); restatement
-- control keeps every attribute table silent. A relationship event and
-- nothing else -- Anchor's native equivalent of the DV effectivity sat.
--
-- Wide, like every delivery: one OMS.ORDER row, the same row as the
-- d6_repoint fixture the DV and Kimball demos use.
INSERT INTO stg_order_l1(order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode) VALUES
('O-101','C001','P',19.5,'USD','2026-02-02 11:30','2027-02-01','UPSERT','INCREMENTAL');
