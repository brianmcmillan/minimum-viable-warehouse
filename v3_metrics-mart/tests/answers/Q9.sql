-- Q9. After the 'P' label changes to PLACED, what does every past order read?
-- Expected: O-100=PLACED,O-101=PLACED. One row per order; the label is
-- joined from the order_status code table on read.
SELECT group_concat(order_ref || '=' || status, ',') FROM (
  SELECT order_ref, status FROM v_order ORDER BY order_ref);
