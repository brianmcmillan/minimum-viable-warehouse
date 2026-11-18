-- Q8. Who owns O-101 now?  Expected after the re-point: Alice Smith (and nobody else)
-- Every current pairing in the historized tie, by the customer's latest name.
SELECT group_concat(n.Customer_Name, ',')
FROM v_order_customer_history h
JOIN CU_REF_Customer_Reference r ON r.Customer_Reference = h.customer_ref
JOIN lCU_NAM n ON n.CU_ID = r.CU_ID
WHERE h.order_ref = 'O-101' AND h.iscurrent = 1;
