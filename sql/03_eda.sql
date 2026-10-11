-- =====================================================================
-- 03_eda.sql  -  Exploratory data analysis on the CLEAN tables
-- =====================================================================

-- name: eda_overview
SELECT COUNT(*)                                        AS transactions,
       SUM(Quantity)                                   AS units_sold,
       ROUND(SUM(Revenue), 2)                          AS total_revenue,
       ROUND(SUM(Revenue) * 1.0 / COUNT(*), 2)         AS avg_revenue_per_transaction,
       ROUND(AVG(Quantity), 2)                         AS avg_units_per_transaction,
       COUNT(DISTINCT CustomerID)                      AS purchasing_customers,
       (SELECT COUNT(*) FROM clean_customers)          AS total_customers,
       COUNT(DISTINCT ProductID)                       AS products_sold,
       MIN(TransactionDate)                            AS first_date,
       MAX(TransactionDate)                            AS last_date,
       CAST(julianday(MAX(TransactionDate)) - julianday(MIN(TransactionDate)) + 1 AS INT) AS days_observed
FROM clean_sales;

-- name: eda_revenue_by_category
SELECT p.Category,
       COUNT(DISTINCT p.ProductID)                              AS products,
       SUM(s.Quantity)                                          AS units_sold,
       ROUND(SUM(s.Revenue), 2)                                 AS revenue,
       ROUND(100.0 * SUM(s.Revenue) / (SELECT SUM(Revenue) FROM clean_sales), 1) AS revenue_share_pct,
       ROUND(AVG(s.UnitPrice), 2)                               AS avg_price_per_sale,
       ROUND(SUM(s.Revenue) / COUNT(DISTINCT p.ProductID), 2)   AS revenue_per_product
FROM clean_sales s JOIN clean_products p USING (ProductID)
GROUP BY p.Category
ORDER BY revenue DESC;

-- name: eda_monthly_trend
-- The LAST day in the data (28-Jul) is only partly recorded (8 of the usual
-- 24 transactions), and July ends there. So per-day figures use COMPLETE
-- days only; otherwise July would look artificially weak.
WITH flagged AS (
    SELECT *, CASE WHEN TransactionDate < (SELECT MAX(TransactionDate) FROM clean_sales) THEN 1 ELSE 0 END AS complete_day
    FROM clean_sales
)
SELECT strftime('%Y-%m', TransactionDate)                                   AS month,
       COUNT(DISTINCT CASE WHEN complete_day = 1 THEN TransactionDate END)  AS complete_days,
       COUNT(*)                                                             AS transactions,
       SUM(Quantity)                                                        AS units,
       ROUND(SUM(Revenue), 2)                                               AS revenue,
       ROUND(SUM(CASE WHEN complete_day = 1 THEN Revenue END) * 1.0
             / COUNT(DISTINCT CASE WHEN complete_day = 1 THEN TransactionDate END), 2) AS revenue_per_day,
       ROUND(SUM(complete_day) * 1.0
             / COUNT(DISTINCT CASE WHEN complete_day = 1 THEN TransactionDate END), 2) AS transactions_per_day,
       COUNT(DISTINCT CustomerID)                                           AS active_customers
FROM flagged
GROUP BY month
ORDER BY month;

-- name: eda_daily_revenue
SELECT TransactionDate AS date,
       COUNT(*)        AS transactions,
       ROUND(SUM(Revenue), 2) AS revenue,
       CASE WHEN TransactionDate < (SELECT MAX(TransactionDate) FROM clean_sales) THEN 1 ELSE 0 END AS complete_day
FROM clean_sales GROUP BY TransactionDate ORDER BY TransactionDate;

-- name: eda_weekday
SELECT CASE strftime('%w', TransactionDate)
         WHEN '0' THEN '7-Sun' WHEN '1' THEN '1-Mon' WHEN '2' THEN '2-Tue'
         WHEN '3' THEN '3-Wed' WHEN '4' THEN '4-Thu' WHEN '5' THEN '5-Fri' ELSE '6-Sat' END AS weekday,
       COUNT(*) AS transactions,
       ROUND(SUM(Revenue), 2) AS revenue
FROM clean_sales GROUP BY weekday ORDER BY weekday;

-- name: eda_customer_demographics
SELECT 'Gender' AS dimension, Gender AS value, COUNT(*) AS customers FROM clean_customers GROUP BY Gender
UNION ALL
SELECT 'Location', Location, COUNT(*) FROM clean_customers GROUP BY Location
UNION ALL
SELECT 'AgeGroup', COALESCE(AgeGroup, 'Unknown'), COUNT(*) FROM clean_customers GROUP BY AgeGroup;

-- name: eda_impact_of_price_correction
-- How wrong would the "top products" list be if we had NOT cleaned?
SELECT ProductID,
       ROUND(SUM(RawRevenue), 2)  AS revenue_uncleaned,
       ROUND(SUM(Revenue), 2)     AS revenue_cleaned,
       RANK() OVER (ORDER BY SUM(RawRevenue) DESC) AS rank_uncleaned,
       RANK() OVER (ORDER BY SUM(Revenue) DESC)    AS rank_cleaned
FROM clean_sales
GROUP BY ProductID
ORDER BY revenue_uncleaned DESC
LIMIT 10;
