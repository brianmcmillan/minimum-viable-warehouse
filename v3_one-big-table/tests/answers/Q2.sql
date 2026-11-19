-- Q2. Which customers are deleted?  Expected after D5: C002,C003
-- v_customer_gone: every customer the log has seen that the latest table
-- no longer holds (TEMP views over the log; run from the repo root).
.read v3_one-big-table/schema/03_log_views.sql
SELECT group_concat(customer_id, ',') FROM (SELECT customer_id FROM v_customer_gone ORDER BY customer_id);
