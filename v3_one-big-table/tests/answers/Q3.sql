-- Q3. What has C001's email been, oldest first?  Expected: alice@example.com>alice@newmail.com
-- v_customer_version: C001's versions, each a change from the one before.
.read v3_one-big-table/schema/03_log_views.sql
SELECT group_concat(email_addr, '>') FROM (
  SELECT email_addr FROM v_customer_version WHERE customer_id = 'C001' ORDER BY valid_from);
