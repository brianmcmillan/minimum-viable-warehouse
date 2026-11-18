-- Q9. After the 'P' label changes to PLACED, what does every past order read?
-- Expected: O-100=PLACED,O-101=PLACED. Every open ORDER_STATUS version,
-- as translated at ingest (after a seed edit and a rebuild).
SELECT group_concat(order_ref || '=' || status, ',') FROM (
  SELECT order_ref, status FROM v_order_status_history WHERE row_st = 'Y'
  ORDER BY order_ref, eff_tmstp, ver_tmstp);
