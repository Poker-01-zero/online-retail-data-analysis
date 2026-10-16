-- ============================================================
-- 06_add_derived_fields.sql
-- 用途：为清洗层 online_retail_clean 增加分析所需的派生字段
-- 依赖：05_build_clean_table.sql 已执行（表存在且为 1,003,213 行）
-- ============================================================
-- 【为什么需要派生字段】
--   源数据只有 Quantity 和 Price 两个独立的列，没有"这一行卖了多少钱"这个概念。
--   几乎每一条分析（趋势 / 帕累托 / RFM / 留存）都要用到行营收，
--   若每次都写 Quantity * Price，一是啰嗦，二是极易写错（见下方决策 B）。
--   因此在这里一次性物化。
--
-- 【三个决策】
--
--   决策 A：使用【生成列 GENERATED ALWAYS AS ... STORED】，而不是
--           "ADD COLUMN 普通列 + UPDATE 回填"。
--     理由：普通列一旦回填就与源列脱钩 —— 日后任何人改了 Quantity 或 Price，
--           Revenue 仍是旧值，且数据库不会报错。生成列由 MySQL 自动维护，
--           物理上不可能与源列不一致，还能建索引。
--     代价：ALTER 时需要整表重建（约 100 万行），耗时数十秒，期间表被锁定。
--
--   决策 B：Revenue 声明为 DECIMAL(14,2)，且【不做 ROUND】。
--     理由：Price 为 DECIMAL(10,2)、Quantity 为 INT，两者相乘结果恰好是两位小数，
--           不存在需要舍入的情况。额外套一层 ROUND 只是噪音。
--     口径警示：必须【逐行相乘后求和】 SUM(Quantity * Price)；
--           写成 SUM(Quantity) * SUM(Price) 得到的是"总量 × 总价"，
--           没有业务含义，数值也完全不同。
--
--   决策 C：时间维度给三个字段 Year / Month / YearMonth。
--     理由：分工不同，不是冗余。
--       YearMonth (DATE，存每月 1 号) → 月度趋势，且日期类型可被 Tableau 识别为时间轴
--       Month  (1-12)               → 季节性分析（跨年合并同一月份）
--       Year                        → 跨年对比
--     为什么不把 YearMonth 存成字符串 '2009-12'：
--       字符串比较虽能排序，但 Tableau / Excel 无法当日期处理，图表会退化成分类轴。
--
-- 【分层说明（要能讲出来）】
--   严格讲，清洗层应只装源数据的忠实还原，派生字段属于分析层的产物。
--   这里选择物化进清洗层，是因为后续 5 个分析与 Tableau 会反复使用它 ——
--   这是【刻意的工程取舍】，不是不懂分层。
-- ============================================================

USE online_retail;

-- ------------------------------------------------------------
-- 加字段
-- 注意：已存在时报 Error 1060 (Duplicate column name)，属预期无害，跳过即可。
-- 若全部 4 列都已存在，则无需再执行本语句。
-- ------------------------------------------------------------
ALTER TABLE online_retail_clean
  ADD COLUMN Revenue   DECIMAL(14,2) GENERATED ALWAYS AS (Quantity * Price) STORED
                       COMMENT '行营收 = Quantity × Price，逐行相乘',
  ADD COLUMN Year      SMALLINT      GENERATED ALWAYS AS (YEAR(InvoiceDate)) STORED
                       COMMENT '年份，用于跨年对比',
  ADD COLUMN Month     TINYINT       GENERATED ALWAYS AS (MONTH(InvoiceDate)) STORED
                       COMMENT '月份 1-12，用于季节性分析',
  ADD COLUMN YearMonth DATE          GENERATED ALWAYS AS (CAST(DATE_FORMAT(InvoiceDate, '%Y-%m-01') AS DATE)) STORED
                       COMMENT '月初日期，用于月度趋势';


-- ------------------------------------------------------------
-- 验证 1：字段确已生成（Extra 列应显示 STORED GENERATED）
-- ------------------------------------------------------------
DESCRIBE online_retail_clean;


-- ------------------------------------------------------------
-- 验证 2：抽样看一眼，确认派生值肉眼可验算
-- 挑 Quantity 和 Price 都是小整数的行，方便手算核对
-- ------------------------------------------------------------
SELECT Invoice, StockCode, Quantity, Price, Revenue, InvoiceDate, YearMonth
FROM online_retail_clean
WHERE Quantity BETWEEN 2 AND 6 AND Price BETWEEN 1 AND 5
ORDER BY InvoiceDate
LIMIT 5;


-- ------------------------------------------------------------
-- 验证 3：对账 —— 总营收必须仍为 19642676.02
-- 这是全部后续分析的总基准。若对不上，说明类型或计算口径出了问题，
-- 必须先解决再往下走。
-- ------------------------------------------------------------
SELECT
  COUNT(*)                    AS 行数,        -- 期望 1003213
  SUM(Revenue)                AS 总营收,      -- 期望 19642676.02
  MIN(InvoiceDate)            AS 最早时间,    -- 期望 2009-12-01
  MAX(InvoiceDate)            AS 最晚时间,    -- 期望 2011-12-09
  COUNT(DISTINCT YearMonth)   AS 月份数,      -- 期望 25
  COUNT(DISTINCT Customer_ID) AS 客户数
FROM online_retail_clean;


-- ------------------------------------------------------------
-- 验证 4：确认 DECIMAL(14,2) 的精度够用（看单行营收的最大值）
-- 若最大值接近 10^12 才需要担心溢出，实际应在十亿级以内。
-- ------------------------------------------------------------
SELECT MAX(Quantity * Price) AS 单行最大营收 FROM online_retail_clean;


-- ------------------------------------------------------------
-- 验证 5：月度营收一览（D5 第二步的预告，先看个数对不对）
-- 期望 25 行，首行 2009-12，末行 2011-12
-- ------------------------------------------------------------
SELECT
  YearMonth            AS 月份,
  COUNT(DISTINCT Invoice) AS 发票数,
  ROUND(SUM(Revenue), 2)  AS 月营收
FROM online_retail_clean
GROUP BY YearMonth
ORDER BY YearMonth;
