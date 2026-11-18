-- Q2. Which customers are deleted?  Expected after D5: C002,C003
-- CANNOT: the latest tables hold only live customers; who was deleted is in the log alone
-- Needs the archive attached as `arch`. The latest table only says who is
-- live; who was deleted is every customer the log has seen that the latest
-- table no longer holds.
SELECT group_concat(customer_id, ',') FROM (
  SELECT DISTINCT customer_id FROM arch.hist_customer
  WHERE customer_id NOT IN (SELECT customer_ref FROM obt_customer) ORDER BY customer_id);
