-- Q9. After the 'P' label changes to PLACED, what does every past order read?
-- Expected: O-100=PLACED,O-101=PLACED. Every order frame row, each read
-- under the rule in force now (the decode happens on read).
SELECT group_concat(order_ref || '=' || status, ',') FROM (
  SELECT order_ref, status FROM v_order_as_recorded ORDER BY order_ref, recorded_at);
