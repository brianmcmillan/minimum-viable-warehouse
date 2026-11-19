-- Q3. What has C001's email been, oldest first?  Expected: alice@example.com>alice@newmail.com
-- RES keeps current state; RES_HIST keeps a version per change of a
-- resource's descriptive columns or parent. Keep each email that differs
-- from the version before it (a version can change for another column).
SELECT group_concat(email_addr, '>') FROM (
  SELECT email_addr, LAG(email_addr) OVER (ORDER BY valid_from) AS prev
  FROM v_res_version WHERE res_type = 'CUSTOMER' AND res_code = 'C001')
WHERE prev IS NULL OR email_addr IS NOT prev;
