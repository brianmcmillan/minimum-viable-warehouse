-- Q5. What does O-100's status read as?  Expected: PENDING (raw 'P')
-- Inmon conforms at ingest: the EDW already stores the label.
SELECT status FROM v_order WHERE order_ref = 'O-100';
