-- ============================================================
-- 04_profiling.sql
-- 用途：数据探查 —— 量化缺失值、重复行、异常值
-- 说明：这些查询用于【了解数据】和【设计清洗规则】，不修改任何数据（只读）。
--       探查结论已汇总至 ../数据质量记录.md
-- ============================================================

USE online_retail;

-- 1. 总行数（基准：1067371）
SELECT COUNT(*) AS 总行数 FROM online_retail_raw;


-- 2. 各字段缺失值统计
--    技巧：SUM(条件) 能实现计数，因为 MySQL 中 TRUE = 1、FALSE = 0
SELECT
  SUM(Invoice     = '') AS 发票号空,
  SUM(Description = '') AS 描述空,
  SUM(Customer_ID = '') AS 客户ID空,
  SUM(Country     = '') AS 国家空
FROM online_retail_raw;


-- 3. 完全重复行（去重后行数；总行数 - 该值 = 重复行数）
SELECT COUNT(*) AS 去重后行数
FROM (SELECT DISTINCT * FROM online_retail_raw) t;


-- 4. 异常值统计
SELECT
  SUM(CAST(Quantity AS SIGNED) < 0)      AS 负数量_退货,
  SUM(Invoice LIKE 'C%')                 AS 取消单,
  SUM(CAST(Price AS DECIMAL(10,2)) <= 0) AS 非正价格,
  SUM(CAST(Quantity AS SIGNED) = 0)      AS 数量为零
FROM online_retail_raw;


-- 5. 非商品类编码
--    商品编码规则 = 5 位数字 + 可选字母后缀（如 85123A）
--    注意：不可写成 '^[0-9]{5}$'，那会误伤约 5000 行真实商品
SELECT StockCode, COUNT(*) AS 出现次数
FROM online_retail_raw
WHERE StockCode NOT REGEXP '^[0-9]{5}[A-Za-z]*$'
GROUP BY StockCode
ORDER BY 出现次数 DESC;


-- 6. 国家分布
SELECT Country, COUNT(*) AS 订单行数
FROM online_retail_raw
GROUP BY Country
ORDER BY 订单行数 DESC;


-- 7. 时间范围
SELECT
  MIN(InvoiceDate) AS 最早,
  MAX(InvoiceDate) AS 最晚,
  COUNT(DISTINCT LEFT(InvoiceDate, 7)) AS 覆盖月份数
FROM online_retail_raw;
