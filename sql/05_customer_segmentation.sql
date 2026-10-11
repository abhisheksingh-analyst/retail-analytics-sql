-- =====================================================================
-- 05_customer_segmentation.sql
-- Objective: segment customers by purchasing behaviour (RFM).
--   R = Recency   (days since last purchase, as of the day after the data ends)
--   F = Frequency (number of transactions)
--   M = Monetary  (total cleaned revenue)
-- Each is scored 1-4 (4 = best) using CUME_DIST so customers with the
-- SAME value always get the SAME score. (NTILE would split ties
-- arbitrarily, which is a subtle bug for integer metrics like Frequency.)
-- =====================================================================

-- setup
DROP VIEW IF EXISTS customer_rfm;
CREATE VIEW customer_rfm AS
WITH snap AS (
    SELECT date(MAX(TransactionDate), '+1 day') AS snapshot_date FROM clean_sales
),
agg AS (
    SELECT c.CustomerID, c.Age, c.AgeGroup, c.Gender, c.Location, c.JoinDate,
           MAX(s.TransactionDate)                       AS LastPurchase,
           COUNT(s.TransactionID)                       AS Frequency,
           ROUND(COALESCE(SUM(s.Revenue), 0), 2)        AS Monetary,
           CAST(julianday((SELECT snapshot_date FROM snap)) - julianday(MAX(s.TransactionDate)) AS INT) AS Recency
    FROM clean_customers c
    LEFT JOIN clean_sales s USING (CustomerID)
    GROUP BY c.CustomerID
),
cd AS (
    SELECT *,
           CUME_DIST() OVER (ORDER BY Recency   DESC) AS r_cd,   -- long ago  -> low cd
           CUME_DIST() OVER (ORDER BY Frequency ASC)  AS f_cd,
           CUME_DIST() OVER (ORDER BY Monetary  ASC)  AS m_cd
    FROM agg WHERE Frequency > 0
),
scored AS (
    SELECT *,
           CASE WHEN r_cd <= 0.25 THEN 1 WHEN r_cd <= 0.50 THEN 2 WHEN r_cd <= 0.75 THEN 3 ELSE 4 END AS R,
           CASE WHEN f_cd <= 0.25 THEN 1 WHEN f_cd <= 0.50 THEN 2 WHEN f_cd <= 0.75 THEN 3 ELSE 4 END AS F,
           CASE WHEN m_cd <= 0.25 THEN 1 WHEN m_cd <= 0.50 THEN 2 WHEN m_cd <= 0.75 THEN 3 ELSE 4 END AS M
    FROM cd
)
SELECT CustomerID, Age, AgeGroup, Gender, Location, JoinDate, LastPurchase,
       Recency, Frequency, Monetary, R, F, M,
       CASE
         WHEN R >= 3 AND F >= 3 AND M >= 3      THEN '1 Champions'          -- recent, frequent, big spenders
         WHEN R <= 2 AND (F >= 3 OR M >= 3)     THEN '2 At-Risk High Value' -- valuable but gone quiet
         WHEN F >= 3                            THEN '3 Loyal'              -- frequent, moderate spend
         WHEN R >= 3                            THEN '4 Recent / Promising' -- bought recently, few orders so far
         ELSE                                        '5 Hibernating'        -- long ago, few orders, low spend
       END AS Segment
FROM scored;

-- name: rfm_customers
SELECT * FROM customer_rfm ORDER BY CustomerID;

-- name: segment_summary
SELECT Segment,
       COUNT(*)                                                               AS customers,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM customer_rfm), 1)       AS pct_customers,
       ROUND(AVG(Recency), 1)                                                 AS avg_recency_days,
       ROUND(AVG(Frequency), 2)                                               AS avg_frequency,
       ROUND(AVG(Monetary), 2)                                                AS avg_monetary,
       ROUND(SUM(Monetary), 2)                                                AS revenue,
       ROUND(100.0 * SUM(Monetary) / (SELECT SUM(Monetary) FROM customer_rfm), 1) AS pct_revenue,
       ROUND(SUM(Monetary) * 1.0 / SUM(Frequency), 2)                         AS avg_order_value
FROM customer_rfm GROUP BY Segment ORDER BY Segment;

-- name: segment_by_location
SELECT Segment, Location, COUNT(*) AS customers FROM customer_rfm GROUP BY Segment, Location ORDER BY Segment, Location;

-- name: segment_by_gender
SELECT Segment, Gender, COUNT(*) AS customers FROM customer_rfm GROUP BY Segment, Gender ORDER BY Segment, Gender;

-- name: segment_by_agegroup
SELECT Segment, COALESCE(AgeGroup,'Unknown') AS AgeGroup, COUNT(*) AS customers FROM customer_rfm GROUP BY Segment, AgeGroup ORDER BY Segment, AgeGroup;

-- name: segment_category_mix
-- What does each segment buy? (share of the segment's revenue per category)
SELECT r.Segment, p.Category,
       ROUND(SUM(s.Revenue), 2) AS revenue,
       ROUND(100.0 * SUM(s.Revenue) / SUM(SUM(s.Revenue)) OVER (PARTITION BY r.Segment), 1) AS pct_of_segment
FROM clean_sales s
JOIN customer_rfm r USING (CustomerID)
JOIN clean_products p USING (ProductID)
GROUP BY r.Segment, p.Category
ORDER BY r.Segment, revenue DESC;

-- name: customers_never_purchased
SELECT c.CustomerID, c.Gender, c.Location, c.JoinDate
FROM clean_customers c LEFT JOIN clean_sales s USING (CustomerID)
WHERE s.TransactionID IS NULL ORDER BY c.CustomerID;

-- name: top_decile_concentration
-- How concentrated is revenue? (top 10% of customers' share of revenue)
WITH ranked AS (
  SELECT Monetary, NTILE(10) OVER (ORDER BY Monetary DESC, CustomerID) AS decile FROM customer_rfm
)
SELECT decile, COUNT(*) AS customers, ROUND(SUM(Monetary), 2) AS revenue,
       ROUND(100.0 * SUM(Monetary) / (SELECT SUM(Monetary) FROM customer_rfm), 1) AS pct_revenue
FROM ranked GROUP BY decile ORDER BY decile;
