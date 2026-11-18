-- Q6. What is the total of the current orders?  Expected after D0: 48.99
-- Summed from the Orders stage of the bridge, so nothing is double counted.
SELECT printf('%.2f', SUM(amount)) FROM v_order;
