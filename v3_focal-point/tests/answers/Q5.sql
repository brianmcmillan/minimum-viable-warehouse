-- Q5. What does O-100's status read as?  Expected: PENDING (raw 'P')
-- Focal translates at ingest (meta_value_map); the raw 'P' is in the archive.
SELECT status FROM v_order WHERE order_ref = 'O-100';
