-- =====================================================================
-- 02_data_cleaning.sql
-- Builds CLEAN tables from RAW tables. Raw data is never modified.
-- Each decision is documented where it is made.
-- =====================================================================

-- setup
DROP TABLE IF EXISTS clean_products;
DROP TABLE IF EXISTS clean_customers;
DROP TABLE IF EXISTS clean_sales;

-- ---------- Products ------------------------------------------------
CREATE TABLE clean_products AS
SELECT ProductID,
       ProductName,
       Category,
       StockLevel,
       Price AS CatalogPrice
FROM raw_products;

-- ---------- Customers -----------------------------------------------
-- * Age outside 18-100 -> NULL (customer kept, impossible value removed;
--   we do not guess a replacement).
-- * Missing Location   -> 'Unknown' (explicit category, rows not deleted).
-- * JoinDate dd/mm/yy  -> ISO yyyy-mm-dd so dates sort/compare correctly.
CREATE TABLE clean_customers AS
SELECT CustomerID,
       CASE WHEN Age BETWEEN 18 AND 100 THEN Age END AS Age,
       CASE WHEN Age NOT BETWEEN 18 AND 100 THEN NULL
            WHEN Age < 25 THEN '18-24'
            WHEN Age < 35 THEN '25-34'
            WHEN Age < 45 THEN '35-44'
            WHEN Age < 55 THEN '45-54'
            WHEN Age < 65 THEN '55-64'
            ELSE '65+' END                            AS AgeGroup,
       Gender,
       COALESCE(Location, 'Unknown')                  AS Location,
       '20' || substr(JoinDate, 7, 2) || '-' ||
               substr(JoinDate, 4, 2) || '-' ||
               substr(JoinDate, 1, 2)                 AS JoinDate
FROM raw_customers;

-- ---------- Sales ---------------------------------------------------
-- * SELECT DISTINCT removes exact duplicate rows.
-- * Unit price = catalog price. Justification: every mismatch is one
--   product at exactly 100x its catalog price (a decimal-shift error),
--   while all other rows match the catalog exactly
--   (see dq_price_mismatch_detail / dq_price_consistency_rest).
-- * RawRevenue is kept so the impact of the correction can be shown.
CREATE TABLE clean_sales AS
WITH dedup AS (SELECT DISTINCT * FROM raw_sales)
SELECT d.TransactionID,
       d.CustomerID,
       d.ProductID,
       d.QuantityPurchased                                   AS Quantity,
       '20' || substr(d.TransactionDate, 7, 2) || '-' ||
               substr(d.TransactionDate, 4, 2) || '-' ||
               substr(d.TransactionDate, 1, 2)               AS TransactionDate,
       d.Price                                               AS RecordedPrice,
       p.CatalogPrice                                        AS UnitPrice,
       CASE WHEN ABS(d.Price - p.CatalogPrice) > 0.01 THEN 1 ELSE 0 END AS PriceCorrected,
       ROUND(d.QuantityPurchased * d.Price, 2)               AS RawRevenue,
       ROUND(d.QuantityPurchased * p.CatalogPrice, 2)        AS Revenue
FROM dedup d
JOIN clean_products p ON p.ProductID = d.ProductID;

CREATE INDEX idx_cs_cust ON clean_sales(CustomerID);
CREATE INDEX idx_cs_prod ON clean_sales(ProductID);
CREATE INDEX idx_cs_date ON clean_sales(TransactionDate);

-- name: cleaning_validation
-- Post-cleaning assertions.
SELECT 'clean_sales rows (expect 5000)'              AS check_name, COUNT(*) AS n FROM clean_sales
UNION ALL SELECT 'duplicate TransactionIDs (expect 0)',
       COUNT(*) - COUNT(DISTINCT TransactionID) FROM clean_sales
UNION ALL SELECT 'rows with price corrected (expect 20)', SUM(PriceCorrected) FROM clean_sales
UNION ALL SELECT 'revenue removed by correction', ROUND(SUM(RawRevenue) - SUM(Revenue)) FROM clean_sales
UNION ALL SELECT 'invalid ISO dates (expect 0)', COUNT(*) FROM clean_sales WHERE date(TransactionDate) IS NULL
UNION ALL SELECT 'customers with NULL age (expect 1)', COUNT(*) FROM clean_customers WHERE Age IS NULL;
