-- Q1. Which customers are live now?  Expected after D5: C001
SELECT group_concat(customer_ref, ',') FROM (SELECT customer_ref FROM mart_customers ORDER BY customer_ref);
