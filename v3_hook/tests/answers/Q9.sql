-- Q9. After the 'P' label changes to PLACED, what does every past order read?
-- Expected: O-100=PLACED,O-101=PLACED. Current state, one row per order:
-- each order's latest frame row, read under the rule in force now (the
-- decode happens on read). History over time is a separate question.
SELECT group_concat(order_ref || '=' || status, ',') FROM (
  SELECT order_ref, status FROM v_order ORDER BY order_ref);
