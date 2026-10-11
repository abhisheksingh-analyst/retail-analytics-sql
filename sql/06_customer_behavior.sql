-- =====================================================================
-- 06_customer_behavior.sql
-- Objective: understand repeat purchases and loyalty indicators to
-- tailor engagement strategies and improve retention.
-- =====================================================================

-- name: purchase_frequency_distribution
SELECT Frequency AS purchases, COUNT(*) AS customers,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM customer_rfm), 1) AS pct_customers
FROM customer_rfm GROUP BY Frequency ORDER BY Frequency;

-- name: repeat_purchase_rate
SELECT COUNT(*)                                                   AS purchasing_customers,
       SUM(CASE WHEN Frequency >= 2 THEN 1 ELSE 0 END)            AS repeat_customers,
       ROUND(100.0 * SUM(CASE WHEN Frequency >= 2 THEN 1 ELSE 0 END) / COUNT(*), 1) AS repeat_rate_pct,
       ROUND(AVG(Frequency), 2)                                   AS avg_purchases_per_customer,
       ROUND(AVG(Monetary), 2)                                    AS avg_revenue_per_customer
FROM customer_rfm;

-- name: month_over_month_retention
-- Of customers active in month m, what share is active again in month m+1?
-- Only month pairs where BOTH months are complete (July is partial).
WITH cm AS (
    SELECT DISTINCT CustomerID, strftime('%Y-%m', TransactionDate) AS m FROM clean_sales
)
SELECT a.m                                              AS month,
       COUNT(DISTINCT a.CustomerID)                     AS active_customers,
       COUNT(DISTINCT b.CustomerID)                     AS active_next_month,
       ROUND(100.0 * COUNT(DISTINCT b.CustomerID) / COUNT(DISTINCT a.CustomerID), 1) AS retention_pct
FROM cm a
LEFT JOIN cm b
       ON b.CustomerID = a.CustomerID
      AND b.m = strftime('%Y-%m', date(a.m || '-01', '+1 month'))
WHERE a.m < '2023-06'
GROUP BY a.m ORDER BY a.m;

-- name: months_active_distribution
-- Loyalty indicator: in how many of the 7 months did a customer buy?
WITH cm AS (
    SELECT CustomerID, COUNT(DISTINCT strftime('%Y-%m', TransactionDate)) AS months_active
    FROM clean_sales GROUP BY CustomerID
)
SELECT months_active, COUNT(*) AS customers,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM cm), 1) AS pct_customers
FROM cm GROUP BY months_active ORDER BY months_active;

-- name: inter_purchase_gap_buckets
-- Days between consecutive purchases of the same customer.
WITH gaps AS (
    SELECT CustomerID,
           julianday(TransactionDate) - julianday(LAG(TransactionDate) OVER (PARTITION BY CustomerID ORDER BY TransactionDate, TransactionID)) AS gap
    FROM clean_sales
)
SELECT CASE WHEN gap = 0 THEN '0 (same day)'
            WHEN gap <= 7  THEN '1-7'
            WHEN gap <= 14 THEN '8-14'
            WHEN gap <= 30 THEN '15-30'
            WHEN gap <= 60 THEN '31-60'
            WHEN gap <= 90 THEN '61-90'
            ELSE '90+' END AS gap_days,
       COUNT(*) AS purchases
FROM gaps WHERE gap IS NOT NULL
GROUP BY gap_days
ORDER BY MIN(gap);

-- name: inter_purchase_gap_raw
SELECT CustomerID,
       julianday(TransactionDate) - julianday(LAG(TransactionDate) OVER (PARTITION BY CustomerID ORDER BY TransactionDate, TransactionID)) AS gap_days
FROM clean_sales;

-- name: recency_buckets
-- Churn-risk view: how long since each customer's last purchase?
SELECT CASE WHEN Recency <= 14 THEN '1-14 days'
            WHEN Recency <= 30 THEN '15-30 days'
            WHEN Recency <= 60 THEN '31-60 days'
            WHEN Recency <= 90 THEN '61-90 days'
            ELSE '90+ days' END AS days_since_last_purchase,
       COUNT(*) AS customers,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM customer_rfm), 1) AS pct_customers
FROM customer_rfm GROUP BY days_since_last_purchase ORDER BY MIN(Recency);

-- name: tenure_vs_spend
-- Do longer-standing customers (earlier join year) buy more?
SELECT substr(JoinDate, 1, 4)                    AS join_year,
       COUNT(*)                                  AS customers,
       ROUND(AVG(Frequency), 2)                  AS avg_purchases,
       ROUND(AVG(Monetary), 2)                   AS avg_revenue
FROM customer_rfm GROUP BY join_year ORDER BY join_year;

-- name: category_breadth
-- Do customers who shop across more categories spend more?
WITH b AS (
    SELECT s.CustomerID, COUNT(DISTINCT p.Category) AS categories, SUM(s.Revenue) AS revenue, COUNT(*) AS purchases
    FROM clean_sales s JOIN clean_products p USING (ProductID) GROUP BY s.CustomerID
)
SELECT categories, COUNT(*) AS customers, ROUND(AVG(purchases), 2) AS avg_purchases, ROUND(AVG(revenue), 2) AS avg_revenue
FROM b GROUP BY categories ORDER BY categories;

-- name: spend_by_demographic
SELECT 'Gender'   AS dimension, Gender   AS value, COUNT(*) AS customers, ROUND(AVG(Frequency),2) AS avg_purchases, ROUND(AVG(Monetary),2) AS avg_revenue FROM customer_rfm GROUP BY Gender
UNION ALL
SELECT 'Location', Location, COUNT(*), ROUND(AVG(Frequency),2), ROUND(AVG(Monetary),2) FROM customer_rfm GROUP BY Location
UNION ALL
SELECT 'AgeGroup', COALESCE(AgeGroup,'Unknown'), COUNT(*), ROUND(AVG(Frequency),2), ROUND(AVG(Monetary),2) FROM customer_rfm GROUP BY AgeGroup;

-- name: customer_category_matrix
-- Per-customer revenue by category (used for the k-means robustness check).
SELECT s.CustomerID, p.Category, ROUND(SUM(s.Revenue),2) AS revenue
FROM clean_sales s JOIN clean_products p USING (ProductID) GROUP BY s.CustomerID, p.Category;
