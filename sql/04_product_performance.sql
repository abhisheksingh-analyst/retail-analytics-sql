-- =====================================================================
-- 04_product_performance.sql
-- Objective: identify high- and low-sales products to optimise
-- inventory and focus marketing.
-- =====================================================================

-- setup
DROP VIEW IF EXISTS product_perf;
CREATE VIEW product_perf AS
WITH days AS (
    SELECT CAST(julianday(MAX(TransactionDate)) - julianday(MIN(TransactionDate)) + 1 AS INT) AS n
    FROM clean_sales
),
base AS (
    SELECT p.ProductID, p.ProductName, p.Category, p.CatalogPrice AS Price, p.StockLevel,
           COALESCE(SUM(s.Quantity), 0)       AS Units,
           COALESCE(SUM(s.Revenue), 0)        AS Revenue,
           COUNT(s.TransactionID)             AS Transactions,
           COUNT(DISTINCT s.CustomerID)       AS UniqueBuyers
    FROM clean_products p
    LEFT JOIN clean_sales s USING (ProductID)
    GROUP BY p.ProductID
),
ranked AS (
    SELECT *,
           RANK()   OVER (ORDER BY Revenue DESC)                        AS RevenueRank,
           NTILE(4) OVER (ORDER BY Revenue DESC, ProductID)             AS RevenueQuartile,   -- 1 = best
           NTILE(4) OVER (ORDER BY StockLevel DESC, ProductID)          AS StockQuartile,     -- 1 = most stock
           -- share of total revenue accumulated BEFORE this product (for ABC class)
           (SUM(Revenue) OVER (ORDER BY Revenue DESC, ProductID
                               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)) * 1.0
              / SUM(Revenue) OVER ()                                    AS CumShareBefore,
           SUM(Revenue) OVER (ORDER BY Revenue DESC, ProductID
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) * 1.0
              / SUM(Revenue) OVER ()                                    AS CumShare
    FROM base
)
SELECT r.*,
       -- Pareto/ABC: A = products that make up the first 80% of revenue,
       -- B = next 15%, C = last 5%
       CASE WHEN COALESCE(CumShareBefore, 0) < 0.80 THEN 'A'
            WHEN CumShareBefore < 0.95 THEN 'B' ELSE 'C' END            AS ABCClass,
       CASE RevenueQuartile WHEN 1 THEN 'High' WHEN 4 THEN 'Low' ELSE 'Mid' END AS PerformanceTier,
       ROUND(Units * 1.0 / (SELECT n FROM days), 3)                     AS UnitsPerDay,
       -- days of cover = how long current stock lasts at the observed demand
       CASE WHEN Units = 0 THEN NULL
            ELSE ROUND(StockLevel / (Units * 1.0 / (SELECT n FROM days)), 0) END AS DaysOfCover,
       -- Inventory flag. Stock-outs are driven by UNIT demand, not revenue, so the
       -- restock rule uses days of cover (threshold 90 days = a typical
       -- replenishment lead time + safety buffer; change it to fit the business).
       CASE WHEN StockLevel = 0                                     THEN 'Out of stock'
            WHEN Units > 0 AND StockLevel / (Units * 1.0 / (SELECT n FROM days)) < 90
                                                                    THEN 'Restock now (<90 days of cover)'
            WHEN RevenueQuartile = 4 AND StockQuartile = 1          THEN 'Overstock (weak seller, high stock)'
            ELSE 'Balanced' END                                     AS InventoryFlag
FROM ranked r;

-- name: product_performance_full
SELECT ProductID, ProductName, Category, Price, StockLevel, Units, Revenue, Transactions,
       UniqueBuyers, RevenueRank, ABCClass, PerformanceTier, UnitsPerDay, DaysOfCover, InventoryFlag
FROM product_perf
ORDER BY RevenueRank;

-- name: top10_products
SELECT RevenueRank, ProductName, Category, Price, Units, ROUND(Revenue, 2) AS Revenue, StockLevel, InventoryFlag
FROM product_perf ORDER BY RevenueRank LIMIT 10;

-- name: bottom10_products
SELECT RevenueRank, ProductName, Category, Price, Units, ROUND(Revenue, 2) AS Revenue, StockLevel, InventoryFlag
FROM product_perf ORDER BY RevenueRank DESC LIMIT 10;

-- name: abc_summary
SELECT ABCClass,
       COUNT(*)                                                           AS products,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM product_perf), 1)   AS pct_of_products,
       ROUND(SUM(Revenue), 2)                                             AS revenue,
       ROUND(100.0 * SUM(Revenue) / (SELECT SUM(Revenue) FROM product_perf), 1) AS pct_of_revenue
FROM product_perf GROUP BY ABCClass ORDER BY ABCClass;

-- name: inventory_flag_summary
SELECT InventoryFlag, COUNT(*) AS products,
       SUM(StockLevel) AS units_in_stock,
       ROUND(SUM(Revenue), 2) AS revenue
FROM product_perf GROUP BY InventoryFlag ORDER BY products DESC;

-- name: restock_priority_list
SELECT ProductID, ProductName, Category, Price, StockLevel, Units, ROUND(Revenue,2) AS Revenue, DaysOfCover
FROM product_perf WHERE InventoryFlag LIKE 'Restock%' OR InventoryFlag = 'Out of stock' ORDER BY DaysOfCover;

-- name: overstock_list
SELECT ProductID, ProductName, Category, Price, StockLevel, Units, ROUND(Revenue,2) AS Revenue, DaysOfCover
FROM product_perf WHERE InventoryFlag LIKE 'Overstock%' ORDER BY StockLevel DESC;

-- name: category_performance
-- Does revenue differ by category because of volume (units) or price?
SELECT Category,
       COUNT(*)                         AS products,
       SUM(Units)                       AS units,
       ROUND(SUM(Revenue), 2)           AS revenue,
       ROUND(AVG(Price), 2)             AS avg_price,
       ROUND(AVG(Units), 1)             AS avg_units_per_product,
       ROUND(AVG(Revenue), 2)           AS avg_revenue_per_product,
       SUM(CASE WHEN PerformanceTier = 'High' THEN 1 ELSE 0 END) AS high_tier_products,
       SUM(CASE WHEN PerformanceTier = 'Low'  THEN 1 ELSE 0 END) AS low_tier_products,
       SUM(StockLevel)                  AS stock_units
FROM product_perf GROUP BY Category ORDER BY revenue DESC;

-- name: product_half_split
-- Used in Python to test whether product rankings are STABLE over time:
-- revenue per product in the first vs. second part of the period.
SELECT ProductID,
       ROUND(SUM(CASE WHEN TransactionDate <  '2023-05-01' THEN Revenue ELSE 0 END), 2) AS revenue_h1,
       ROUND(SUM(CASE WHEN TransactionDate >= '2023-05-01' THEN Revenue ELSE 0 END), 2) AS revenue_h2,
       SUM(CASE WHEN TransactionDate <  '2023-05-01' THEN Quantity ELSE 0 END) AS units_h1,
       SUM(CASE WHEN TransactionDate >= '2023-05-01' THEN Quantity ELSE 0 END) AS units_h2
FROM clean_sales GROUP BY ProductID;
