-- Q1. Which customers are live now?  Expected after D5: C001
SELECT group_concat(customer_ref, ',') FROM (SELECT customer_ref FROM dim_customer ORDER BY customer_ref);
