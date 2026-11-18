-- Q2. Which customers are deleted?  Expected after D5: C002,C003
-- LAST EVER lifecycle activity per customer: was_deleted means not alive.
SELECT group_concat(customer_id, ',') FROM (
  SELECT customer_id FROM v_customer_state WHERE alive = 0 ORDER BY customer_id);
