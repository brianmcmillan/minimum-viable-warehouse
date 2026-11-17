-- Q6. What is the total of the current orders?  Expected after D0: 48.99
SELECT printf('%.2f', SUM(amount)) FROM fact_order;
