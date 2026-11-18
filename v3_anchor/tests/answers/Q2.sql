-- Q2. Which customers are deleted?  Expected after D5: C002,C003
-- Existence is data: the latest value of the EST knot per customer.
SELECT group_concat(r.Customer_Reference, ',') FROM (
  SELECT r.Customer_Reference FROM lCU_EST x
  JOIN EST_ExistenceStatus k USING (EST_ID)
  JOIN CU_REF_Customer_Reference r ON r.CU_ID = x.CU_ID
  WHERE k.ExistenceStatus = 'DELETED' ORDER BY r.Customer_Reference) r;
