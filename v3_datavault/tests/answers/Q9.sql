-- Q9. After the 'P' label changes to PLACED, what does every past order read?
-- Expected: O-100=PLACED,O-101=PLACED. Every status row the raw satellite
-- holds, decoded by the computed satellite (a view: no reload).
SELECT group_concat(order_ref || '=' || status, ',') FROM (
  SELECT order_ref, status FROM v_order_status_history ORDER BY order_ref, ldts);
