-- Q2. Which customers are deleted?  Expected after D5: C002,C003
-- A delete is a core row: the latest row per customer has change_type DELETE.
SELECT group_concat(customer_id, ',') FROM (
  SELECT customer_id FROM v_latest__customer WHERE change_type = 'DELETE' ORDER BY customer_id);
