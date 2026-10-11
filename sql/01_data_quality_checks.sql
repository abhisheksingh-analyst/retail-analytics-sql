-- =====================================================================
-- 01_data_quality_checks.sql
-- Goal: audit the RAW tables BEFORE touching anything.
-- Rows prefixed "ISSUE" are problems that 02_data_cleaning.sql fixes.
-- =====================================================================

-- name: dq_report
SELECT 'raw_sales rows'                         AS check_name, COUNT(*) AS n FROM raw_sales
UNION ALL SELECT 'raw_customers rows',           COUNT(*) FROM raw_customers
UNION ALL SELECT 'raw_products rows',            COUNT(*) FROM raw_products
-- 1) Exact duplicate transaction rows (same ID + same values)
UNION ALL SELECT 'ISSUE: duplicate sales rows',
       (SELECT COUNT(*) FROM raw_sales) - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM raw_sales))
-- 2) Recorded price differs from the catalog price of that product
UNION ALL SELECT 'ISSUE: sales price != catalog price',
       COUNT(*) FROM raw_sales s JOIN raw_products p USING (ProductID)
       WHERE ABS(s.Price - p.Price) > 0.01
-- 3) Missing customer location
UNION ALL SELECT 'ISSUE: customers with missing Location',
       COUNT(*) FROM raw_customers WHERE Location IS NULL
-- 4) Impossible ages (outside 18-100)
UNION ALL SELECT 'ISSUE: customers with implausible Age',
       COUNT(*) FROM raw_customers WHERE Age < 18 OR Age > 100
-- 5) Referential integrity (orphan foreign keys)
UNION ALL SELECT 'check: sales with unknown CustomerID',
       COUNT(*) FROM raw_sales s LEFT JOIN raw_customers c USING (CustomerID) WHERE c.CustomerID IS NULL
UNION ALL SELECT 'check: sales with unknown ProductID',
       COUNT(*) FROM raw_sales s LEFT JOIN raw_products p USING (ProductID) WHERE p.ProductID IS NULL
-- 6) Non-positive quantities / prices
UNION ALL SELECT 'check: non-positive quantity or price',
       COUNT(*) FROM raw_sales WHERE QuantityPurchased <= 0 OR Price <= 0
-- 7) Products out of stock
UNION ALL SELECT 'note: products with zero stock',
       COUNT(*) FROM raw_products WHERE StockLevel = 0;

-- name: dq_price_mismatch_detail
-- Which products carry the price mismatch, and by what factor?
SELECT s.ProductID,
       COUNT(*)                          AS affected_rows,
       MIN(s.Price)                      AS recorded_price,
       p.Price                           AS catalog_price,
       ROUND(MIN(s.Price) / p.Price, 2)  AS ratio
FROM raw_sales s JOIN raw_products p USING (ProductID)
WHERE ABS(s.Price - p.Price) > 0.01
GROUP BY s.ProductID, p.Price;

-- name: dq_price_consistency_rest
-- Evidence that the catalog is the reliable source: for every OTHER row
-- the recorded price matches the catalog exactly.
SELECT COUNT(*) AS rows_matching_catalog
FROM raw_sales s JOIN raw_products p USING (ProductID)
WHERE ABS(s.Price - p.Price) <= 0.01;
