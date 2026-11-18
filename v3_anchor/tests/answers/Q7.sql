-- Q7. Who placed O-101, as at purchase?  Expected: Bob Jones
-- The historized tie's first pairing, and that customer's name as it
-- stood when the pairing was recorded.
WITH t AS (SELECT t.CU_ID, t.ChangedAt FROM OD_placed_CU_by t
           JOIN OD_REF_Order_Reference o ON o.OD_ID = t.OD_ID
           WHERE o.Order_Reference = 'O-101' ORDER BY t.ChangedAt LIMIT 1)
SELECT n.Customer_Name FROM CU_NAM_Customer_Name n, t
WHERE n.CU_ID = t.CU_ID AND n.ChangedAt <= t.ChangedAt
ORDER BY n.ChangedAt DESC LIMIT 1;
