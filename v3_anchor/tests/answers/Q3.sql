-- Q3. What has C001's email been, oldest first?  Expected: alice@example.com>alice@newmail.com
-- Attribute grain: the email attribute's own history table.
SELECT group_concat(Customer_Email, '>') FROM (
  SELECT Customer_Email FROM v_customer_email_history WHERE customer_ref = 'C001' ORDER BY ChangedAt);
