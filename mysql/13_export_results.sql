-- ============================================================
-- 13_export_results.sql
-- 用途：把前面各阶段的分析结果导出为 CSV，供 Tableau（D8）与 Excel（D7）使用
-- 依赖：05、06（清洗层 + 派生字段）
-- ============================================================
-- 【为什么必须导出，而不是让 Tableau / Excel 直连数据库】
--   1) 两个工具直连 MySQL 的配置麻烦，且大表会拖慢它们
--   2) 关键是【导出的应该是聚合后的小结果集，不是 99 万行明细】
--      —— 三屏看板需要的是"25 行月度数据""8 行客户分群"，不是原始流水
--
-- 【两个必须注意的技术点】
--
--   1) 【导出路径受 secure-file-priv 限制】
--      MySQL 只能往 C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/ 写文件，
--      与 D1 导入时是同一个限制。所以先导出到那里，再复制进项目目录。
--      （不改服务器安全配置 —— 与 D1 的处理原则一致。）
--
--   2) 【导出用 ESCAPED BY '"'，导入用 ESCAPED BY '' —— 方向相反，别抄错】
--      · 导入（03_load_data.sql）用 ESCAPED BY ''：防止 MySQL 把数据里的
--        反斜杠当转义符吃掉（PINK\ON STICK → PINKON STICK）。
--      · 导出（本文件）用 ESCAPED BY '"'：让字段内部的【双引号】按 RFC4180
--        规则双写。实测三种写法的输出：
--            ESCAPED BY ''    → "RABBIT 8"","TEA,COFFEE"   引号提前闭合，字段错位 ❌
--            默认（反斜杠）    → "RABBIT 8\"","TEA,COFFEE"   非 RFC4180        ⚠️
--            ESCAPED BY '"'   → "RABBIT 8""","TEA,COFFEE"   标准双写         ✅
--
--      本文件第一版抄了导入的写法（ESCAPED BY ''），结果 2 个商品描述里含
--      英寸符号（PINK ROSES/GINGHAM PATCH RABBIT 8"、RUBY GLASS NECKLACE 42"）
--      的行被写坏 —— 解析后多出一个"品类 = C"的假分类，销售额为 0。
--      这与 D4 阶段"Workbench 导出破坏含双引号字段"是同一类问题，务必记住。
--
--   3) 【INTO OUTFILE 不写表头】
--      导出的文件只有数据行。表头在复制进项目目录时补上 —— 见 README 的导出说明。
--      这么做是为了让数据行保持原始类型（带表头的话所有列会被强制转成字符串）。
--
-- 【导出清单 —— 对应 D8 三屏看板】
--   屏 1 经营全景 ：01_月度趋势、02_品类结构、03_商品ABC
--   屏 2 客户分群 ：04_RFM八类客户、05_帕累托十分位
--   屏 3 留存复购 ：06_同期群留存矩阵、07_购买间隔分布
--   附赠给 Excel  ：08_商品Top50（供数据透视表 + 图表）
--
--   4) 【导出文件名用纯 ASCII】
--      MySQL 写文件时用操作系统默认编码解释路径，中文文件名会被写成乱码
--      （实测导出成 01_鏈堝害瓒嬪娍.csv，且部分文件因此创建失败）。
--      所以这里统一用英文文件名 —— 顺带也让它跨平台、跨工具都安全。
--      中文名在复制进项目目录时再改，或直接在 Tableau / Excel 里重命名。
--
--   5) 【有 NULL 的列必须用 IFNULL(..., '') 包一层】
--      MySQL 写 NULL 的规则是"当 ESCAPED BY 非空时写成 \N"。
--      但我们把 ESCAPED BY 设成了 '"'，结果 \N 里的反斜杠被吃掉，
--      实际写出的是 `"N` —— 一个开引号后跟 N，**不是合法 CSV 字段**。
--      实测三种写法：
--          ① ESCAPED BY '"' + 原始 NULL   → "a","N,12.5        引号未闭合 ❌
--          ② ESCAPED BY ''  + 原始 NULL   → "a",NULL,12.5      变成文字 NULL ⚠️
--          ③ ESCAPED BY '"' + IFNULL(...,'') → "a","",12.5     空字段 ✅
--      **所以 06 的 M0–M12 全部包了 IFNULL(..., '')** ——
--      那些格子在热力图里代表"可观测性不足"，必须是空值而不是文字。
--      ⚠️ 只有 06 有 NULL 列；其余导出没有 NULL，不需要包。
--
-- 【重新执行前】INTO OUTFILE 在文件已存在时会报 Error 1086，先删除旧文件。
-- ============================================================

USE online_retail;

SET @dir = 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/exports/';


-- ------------------------------------------------------------
-- 01 月度趋势（25 行）—— 屏 1 的折线图
-- ------------------------------------------------------------
SELECT
  DATE_FORMAT(YearMonth, '%Y-%m')                  AS 月份,
  YearMonth                                        AS 月份日期,
  COUNT(DISTINCT Invoice)                          AS 订单数,
  ROUND(SUM(Revenue), 2)                           AS 营收,
  ROUND(SUM(Revenue) / COUNT(DISTINCT Invoice), 2) AS AOV,
  CASE WHEN YearMonth = (SELECT MAX(DATE_FORMAT(InvoiceDate, '%Y-%m-01'))
                         FROM online_retail_clean)
       THEN 0 ELSE 1 END                           AS 是否完整月   -- 1=完整 0=数据截断
FROM online_retail_clean
GROUP BY YearMonth
ORDER BY YearMonth
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/exports/01_monthly_trend.csv'
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n';


-- ------------------------------------------------------------
-- 02 品类结构（10 行）—— 屏 1 的品类占比
--    关键词与 12_product_abc.sql 完全一致，改动时两处必须同步
-- ------------------------------------------------------------
WITH p AS (
  SELECT StockCode, MAX(Description) AS d, SUM(Revenue) AS 销售额
  FROM online_retail_clean WHERE Description IS NOT NULL GROUP BY StockCode
),
k AS (
  SELECT 销售额, CASE
      WHEN d LIKE '%CHRISTMAS%' OR d LIKE '%XMAS%' OR d LIKE '%SANTA%' OR d LIKE '%ADVENT%'
        OR d LIKE '%REINDEER%' OR d LIKE '%SNOWMAN%' OR d LIKE '%STOCKING%' THEN '圣诞节日'
      WHEN d LIKE '%BAG%' OR d LIKE '%SHOPPER%' OR d LIKE '%TOTE%' THEN '包袋'
      WHEN d LIKE '%T-LIGHT%' OR d LIKE '%LIGHT%' OR d LIKE '%CANDLE%' OR d LIKE '%LANTERN%' THEN '灯饰蜡烛'
      WHEN d LIKE '%CAKE%' OR d LIKE '%BAKING%' OR d LIKE '%CUTLERY%' OR d LIKE '%KITCHEN%'
        OR d LIKE '%MUG%' OR d LIKE '%CUP%' OR d LIKE '%JUG%' OR d LIKE '%TEAPOT%'
        OR d LIKE '%PLATE%' OR d LIKE '%BOWL%' OR d LIKE '%TEA %' OR d LIKE '%APRON%' THEN '厨房餐具'
      WHEN d LIKE '%BOX%' OR d LIKE '%HOLDER%' OR d LIKE '%BASKET%' OR d LIKE '%JAR%'
        OR d LIKE '%STORAGE%' OR d LIKE '%RACK%' OR d LIKE '%TIN%' OR d LIKE '%POT%'
        OR d LIKE '%CABINET%' OR d LIKE '%DRAWER%' OR d LIKE '%SHELF%' THEN '收纳家居'
      WHEN d LIKE '%ORNAMENT%' OR d LIKE '%DECORATION%' OR d LIKE '%SIGN%' OR d LIKE '%FRAME%'
        OR d LIKE '%HANGING%' OR d LIKE '%HEART%' OR d LIKE '%BOARD%' OR d LIKE '%CLOCK%' THEN '装饰摆件'
      WHEN d LIKE '%BUNTING%' OR d LIKE '%PAPER%' OR d LIKE '%CARD%' OR d LIKE '%PARTY%'
        OR d LIKE '%PENCIL%' OR d LIKE '%RIBBON%' OR d LIKE '%MEMO%' THEN '派对纸品文具'
      WHEN d LIKE '%DOORMAT%' OR d LIKE '%PARASOL%' OR d LIKE '%UMBRELLA%' OR d LIKE '%MAT %' THEN '门垫雨具'
      WHEN d LIKE '%HOT WATER BOTTLE%' OR d LIKE '%BOTTLE%' OR d LIKE '%FAN%'
        OR d LIKE '%PAINT%' OR d LIKE '%JAM%' THEN '家居日用'
      ELSE '未归类' END AS 品类
  FROM p
)
SELECT
  品类,
  COUNT(*)                                     AS 商品数,
  ROUND(SUM(销售额), 2)                        AS 销售额,
  ROUND(SUM(销售额) / (SELECT SUM(销售额) FROM k) * 100, 2) AS 销售占比,
  CASE WHEN 品类 = '未归类' THEN 1 ELSE 0 END   AS 是否未归类
FROM k
GROUP BY 品类
ORDER BY 销售占比 DESC
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/exports/02_category_mix.csv'
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n';


-- ------------------------------------------------------------
-- 03 商品 ABC 分类汇总（3 行）—— 屏 1
-- ------------------------------------------------------------
WITH p AS (SELECT StockCode, SUM(Revenue) AS 销售额 FROM online_retail_clean GROUP BY StockCode),
c AS (SELECT StockCode, 销售额,
             SUM(销售额) OVER (ORDER BY 销售额 DESC, StockCode) AS 累计销售额,
             SUM(销售额) OVER () AS 总额 FROM p),
t AS (SELECT StockCode, 销售额, ROUND(累计销售额 / 总额 * 100, 4) AS 累计占比 FROM c)
SELECT
  CASE WHEN 累计占比 <= 70 THEN 'A'
       WHEN 累计占比 <= 90 THEN 'B'
       ELSE 'C' END                              AS ABC类别,
  COUNT(*)                                       AS 商品数,
  ROUND(COUNT(*) / 4699 * 100, 2)                AS 商品数占比,
  ROUND(SUM(销售额), 2)                          AS 销售额,
  ROUND(SUM(销售额) / (SELECT SUM(销售额) FROM p) * 100, 2) AS 销售额占比
FROM t
GROUP BY ABC类别
ORDER BY ABC类别
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/exports/03_product_abc.csv'
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n';


-- ------------------------------------------------------------
-- 04 RFM 八类客户（8 行）—— 屏 2 的象限图
--    打分方向与 10_rfm.sql 完全一致
-- ------------------------------------------------------------
WITH c AS (
  SELECT Customer_ID,
         DATEDIFF((SELECT MAX(InvoiceDate) FROM online_retail_clean), MAX(InvoiceDate)) AS R,
         COUNT(DISTINCT Invoice) AS F, SUM(Revenue) AS M
  FROM online_retail_clean WHERE Customer_ID IS NOT NULL GROUP BY Customer_ID
),
s AS (SELECT Customer_ID, R, F, M,
             NTILE(5) OVER (ORDER BY R DESC) AS r分,
             NTILE(5) OVER (ORDER BY F ASC)  AS f分,
             NTILE(5) OVER (ORDER BY M ASC)  AS m分 FROM c),
g AS (
  SELECT *, CASE
      WHEN r分 >= 4 AND f分 >= 4 AND m分 >= 4 THEN '重要价值客户'
      WHEN r分 <  4 AND f分 >= 4 AND m分 >= 4 THEN '重要保持客户'
      WHEN r分 >= 4 AND f分 <  4 AND m分 >= 4 THEN '重要发展客户'
      WHEN r分 <  4 AND f分 <  4 AND m分 >= 4 THEN '重要挽留客户'
      WHEN r分 >= 4 AND f分 >= 4 AND m分 <  4 THEN '一般价值客户'
      WHEN r分 <  4 AND f分 >= 4 AND m分 <  4 THEN '一般保持客户'
      WHEN r分 >= 4 AND f分 <  4 AND m分 <  4 THEN '一般发展客户'
      ELSE '一般挽留客户' END AS 客户类型
  FROM s
)
SELECT
  客户类型,
  COUNT(*)                                        AS 客户数,
  ROUND(COUNT(*) / 5835 * 100, 2)                 AS 客户数占比,
  ROUND(SUM(M), 2)                                AS 营收,
  ROUND(SUM(M) / (SELECT SUM(M) FROM c) * 100, 2) AS 营收占比,
  ROUND(AVG(R), 0)                                AS 平均R天,
  ROUND(AVG(F), 1)                                AS 平均F,
  ROUND(AVG(M), 0)                                AS 平均M,
  ROUND(AVG(r分), 2)                              AS 平均R分,
  ROUND(AVG(f分), 2)                              AS 平均F分,
  ROUND(AVG(m分), 2)                              AS 平均M分
FROM g
GROUP BY 客户类型
ORDER BY 营收 DESC
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/exports/04_rfm_segments.csv'
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n';


-- ------------------------------------------------------------
-- 05 帕累托十分位（10 行）—— 屏 2 的帕累托曲线
-- ------------------------------------------------------------
WITH c AS (SELECT Customer_ID, SUM(Revenue) AS pay FROM online_retail_clean
           WHERE Customer_ID IS NOT NULL GROUP BY Customer_ID),
f AS (SELECT Customer_ID, pay, NTILE(10) OVER (ORDER BY pay DESC) AS grp FROM c),
g AS (SELECT grp, COUNT(*) AS 客户数, SUM(pay) AS 营收 FROM f GROUP BY grp)
SELECT
  grp                                                          AS 组号,
  客户数,
  ROUND(营收, 2)                                               AS 营收,
  ROUND(营收 / (SELECT SUM(pay) FROM c) * 100, 2)              AS 营收占比,
  ROUND(SUM(营收) OVER (ORDER BY grp)
        / (SELECT SUM(pay) FROM c) * 100, 2)                   AS 累计占比
FROM g
ORDER BY grp
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/exports/05_pareto_deciles.csv'
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n';


-- ------------------------------------------------------------
-- 06 同期群留存矩阵（24 行 × 15 列）—— 屏 3 的热力图
--    M0 固定 100%，M13 之后不再输出（数据只到 M12 左右可观测）
--    ⚠️ 空白格 = 可观测性不足，不是 0。CSV 里会导出为空值，Tableau 需按 NULL 处理。
-- ------------------------------------------------------------
WITH fb AS (
  SELECT Customer_ID, DATE(DATE_FORMAT(MIN(InvoiceDate), '%Y-%m-01')) AS 首购月
  FROM online_retail_clean WHERE Customer_ID IS NOT NULL GROUP BY Customer_ID
),
act AS (
  SELECT DISTINCT Customer_ID, DATE(DATE_FORMAT(InvoiceDate, '%Y-%m-01')) AS 购买月
  FROM online_retail_clean WHERE Customer_ID IS NOT NULL
),
base AS (SELECT 首购月, COUNT(*) AS n0 FROM fb GROUP BY 首购月),
j AS (
  SELECT fb.首购月, TIMESTAMPDIFF(MONTH, fb.首购月, act.购买月) AS m,
         COUNT(DISTINCT act.Customer_ID) AS n
  FROM act JOIN fb ON fb.Customer_ID = act.Customer_ID
  GROUP BY fb.首购月, m
)
SELECT
  DATE_FORMAT(j.首购月, '%Y-%m')                                     AS 首购月,
  base.n0                                                            AS 新增客户数,
  IFNULL(ROUND(MAX(CASE WHEN j.m = 0  THEN j.n END) / base.n0 * 100, 1), '')  AS M0,
  IFNULL(ROUND(MAX(CASE WHEN j.m = 1  THEN j.n END) / base.n0 * 100, 1), '')  AS M1,
  IFNULL(ROUND(MAX(CASE WHEN j.m = 2  THEN j.n END) / base.n0 * 100, 1), '')  AS M2,
  IFNULL(ROUND(MAX(CASE WHEN j.m = 3  THEN j.n END) / base.n0 * 100, 1), '')  AS M3,
  IFNULL(ROUND(MAX(CASE WHEN j.m = 4  THEN j.n END) / base.n0 * 100, 1), '')  AS M4,
  IFNULL(ROUND(MAX(CASE WHEN j.m = 5  THEN j.n END) / base.n0 * 100, 1), '')  AS M5,
  IFNULL(ROUND(MAX(CASE WHEN j.m = 6  THEN j.n END) / base.n0 * 100, 1), '')  AS M6,
  IFNULL(ROUND(MAX(CASE WHEN j.m = 7  THEN j.n END) / base.n0 * 100, 1), '')  AS M7,
  IFNULL(ROUND(MAX(CASE WHEN j.m = 8  THEN j.n END) / base.n0 * 100, 1), '')  AS M8,
  IFNULL(ROUND(MAX(CASE WHEN j.m = 9  THEN j.n END) / base.n0 * 100, 1), '')  AS M9,
  IFNULL(ROUND(MAX(CASE WHEN j.m = 10 THEN j.n END) / base.n0 * 100, 1), '')  AS M10,
  IFNULL(ROUND(MAX(CASE WHEN j.m = 11 THEN j.n END) / base.n0 * 100, 1), '')  AS M11,
  IFNULL(ROUND(MAX(CASE WHEN j.m = 12 THEN j.n END) / base.n0 * 100, 1), '')  AS M12
FROM j JOIN base ON base.首购月 = j.首购月
GROUP BY j.首购月, base.n0
ORDER BY j.首购月
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/exports/06_cohort_retention.csv'
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n';


-- ------------------------------------------------------------
-- 07 购买间隔分布（6 行）—— 屏 3
-- ------------------------------------------------------------
WITH inv AS (SELECT DISTINCT Customer_ID, InvoiceDate
             FROM online_retail_clean WHERE Customer_ID IS NOT NULL),
g AS (SELECT DATEDIFF(InvoiceDate,
                      LAG(InvoiceDate) OVER (PARTITION BY Customer_ID ORDER BY InvoiceDate)) AS d
      FROM inv)
SELECT
  -- 前面加序号：Tableau 对离散维度默认按字母排序，
  -- 不加序号会排成「1-7 天 / 180 天以上 / 31-90 天 / 8-30 天 / 91-180 天 / 同一天」
  CASE WHEN d = 0 THEN '1. 同一天' WHEN d <= 7 THEN '2. 1-7 天'
       WHEN d <= 30 THEN '3. 8-30 天' WHEN d <= 90 THEN '4. 31-90 天'
       WHEN d <= 180 THEN '5. 91-180 天' ELSE '6. 180 天以上' END AS 间隔段,
  COUNT(*)                                                  AS 次数,
  ROUND(COUNT(*) / (SELECT COUNT(*) FROM g WHERE d IS NOT NULL) * 100, 1) AS 占比
FROM g WHERE d IS NOT NULL
GROUP BY 间隔段
ORDER BY MIN(d)
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/exports/07_purchase_interval.csv'
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n';


-- ------------------------------------------------------------
-- 08 商品 Top 50（供 Excel 数据透视表 + 图表）
-- ------------------------------------------------------------
SELECT
  StockCode,
  MAX(Description)                                        AS 商品描述,
  SUM(Quantity)                                            AS 销量,
  COUNT(DISTINCT Invoice)                                  AS 订单数,
  COUNT(DISTINCT Customer_ID)                              AS 购买客户数,
  ROUND(SUM(Revenue), 2)                                   AS 销售额
FROM online_retail_clean
GROUP BY StockCode
ORDER BY 销售额 DESC
LIMIT 50
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/exports/08_top50_products.csv'
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n';


-- ------------------------------------------------------------
-- 09 商品级明细（4,699 行，带品类 + ABC 标签）—— 给 Excel 做数据透视表
--    ⚠️ 为什么单独导这个：
--      前 8 个 CSV 都是"聚合后"的结果集，行数很少（3–50 行）。
--      数据透视表的价值在于对【明细】分组汇总 —— 拿 10 行的聚合结果做透视表
--      等于什么都没做。所以这里导出商品级明细，这才是透视表的正料。
-- ------------------------------------------------------------
WITH p AS (
  SELECT StockCode,
         MAX(Description) AS d,
         SUM(Quantity) AS 销量,
         COUNT(DISTINCT Invoice) AS 订单数,
         COUNT(DISTINCT Customer_ID) AS 购买客户数,
         SUM(Revenue) AS 销售额
  FROM online_retail_clean
  WHERE Description IS NOT NULL
  GROUP BY StockCode
),
k AS (
  SELECT StockCode, d AS 商品描述, 销量, 订单数, 购买客户数, 销售额,
    CASE
      WHEN d LIKE '%CHRISTMAS%' OR d LIKE '%XMAS%' OR d LIKE '%SANTA%' OR d LIKE '%ADVENT%'
        OR d LIKE '%REINDEER%' OR d LIKE '%SNOWMAN%' OR d LIKE '%STOCKING%' THEN '圣诞节日'
      WHEN d LIKE '%BAG%' OR d LIKE '%SHOPPER%' OR d LIKE '%TOTE%' THEN '包袋'
      WHEN d LIKE '%T-LIGHT%' OR d LIKE '%LIGHT%' OR d LIKE '%CANDLE%' OR d LIKE '%LANTERN%' THEN '灯饰蜡烛'
      WHEN d LIKE '%CAKE%' OR d LIKE '%BAKING%' OR d LIKE '%CUTLERY%' OR d LIKE '%KITCHEN%'
        OR d LIKE '%MUG%' OR d LIKE '%CUP%' OR d LIKE '%JUG%' OR d LIKE '%TEAPOT%'
        OR d LIKE '%PLATE%' OR d LIKE '%BOWL%' OR d LIKE '%TEA %' OR d LIKE '%APRON%' THEN '厨房餐具'
      WHEN d LIKE '%BOX%' OR d LIKE '%HOLDER%' OR d LIKE '%BASKET%' OR d LIKE '%JAR%'
        OR d LIKE '%STORAGE%' OR d LIKE '%RACK%' OR d LIKE '%TIN%' OR d LIKE '%POT%'
        OR d LIKE '%CABINET%' OR d LIKE '%DRAWER%' OR d LIKE '%SHELF%' THEN '收纳家居'
      WHEN d LIKE '%ORNAMENT%' OR d LIKE '%DECORATION%' OR d LIKE '%SIGN%' OR d LIKE '%FRAME%'
        OR d LIKE '%HANGING%' OR d LIKE '%HEART%' OR d LIKE '%BOARD%' OR d LIKE '%CLOCK%' THEN '装饰摆件'
      WHEN d LIKE '%BUNTING%' OR d LIKE '%PAPER%' OR d LIKE '%CARD%' OR d LIKE '%PARTY%'
        OR d LIKE '%PENCIL%' OR d LIKE '%RIBBON%' OR d LIKE '%MEMO%' THEN '派对纸品文具'
      WHEN d LIKE '%DOORMAT%' OR d LIKE '%PARASOL%' OR d LIKE '%UMBRELLA%' OR d LIKE '%MAT %' THEN '门垫雨具'
      WHEN d LIKE '%HOT WATER BOTTLE%' OR d LIKE '%BOTTLE%' OR d LIKE '%FAN%'
        OR d LIKE '%PAINT%' OR d LIKE '%JAM%' THEN '家居日用'
      ELSE '未归类' END AS 品类
  FROM p
),
abc AS (
  SELECT StockCode,
         SUM(销售额) OVER (ORDER BY 销售额 DESC, StockCode) AS 累计销售额,
         SUM(销售额) OVER () AS 总额
  FROM p
),
abcx AS (
  SELECT StockCode, ROUND(累计销售额 / 总额 * 100, 4) AS 累计占比 FROM abc
)
SELECT
  k.StockCode,
  k.商品描述,
  k.品类,
  CASE WHEN abcx.累计占比 <= 70 THEN 'A'
       WHEN abcx.累计占比 <= 90 THEN 'B'
       ELSE 'C' END        AS ABC类别,
  k.销量,
  k.订单数,
  k.购买客户数,
  ROUND(k.销售额, 2)       AS 销售额
FROM k JOIN abcx ON abcx.StockCode = k.StockCode
ORDER BY k.销售额 DESC
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/exports/09_product_detail.csv'
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n';


-- ------------------------------------------------------------
-- 10 同期群留存【长表】—— 给 Tableau 热力图专用
--    ⚠️ 为什么单独导这个，而不是用 06 的宽表：
--      06 是宽表（M0–M12 是 12 列），在 Tableau 里画热力图需要先「数据透视」。
--      而直接导长表能一次消掉 4 个坑：
--        ① NULL 问题 —— 长表里没有 NULL（不存在的格子干脆没有行）
--        ② 排序陷阱 —— 月序是整数 0/1/2…/12，不会出现 M0/M1/M10/M11/M12/M2 的字母序
--        ③ 省掉 Tableau 的「数据透视」步骤（那一步最容易点错）
--        ④ 类型歧义 —— 留存率是真数字，不会被引号包成字符串
--      06 的宽表仍然保留 —— 它适合【人读】，长表适合【机器画】。
--      （这正是"同一份分析结果的两种形态"，不是重复导出。）
--    检查点：行数 = 各 cohort 可观测格子数（远少于 25×13）
-- ------------------------------------------------------------
WITH fb AS (
  SELECT Customer_ID, DATE(DATE_FORMAT(MIN(InvoiceDate), '%Y-%m-01')) AS 首购月
  FROM online_retail_clean WHERE Customer_ID IS NOT NULL GROUP BY Customer_ID
),
act AS (
  SELECT DISTINCT Customer_ID, DATE(DATE_FORMAT(InvoiceDate, '%Y-%m-01')) AS 购买月
  FROM online_retail_clean WHERE Customer_ID IS NOT NULL
),
base AS (SELECT 首购月, COUNT(*) AS n0 FROM fb GROUP BY 首购月),
j AS (
  SELECT fb.首购月, TIMESTAMPDIFF(MONTH, fb.首购月, act.购买月) AS m,
         COUNT(DISTINCT act.Customer_ID) AS n
  FROM act JOIN fb ON fb.Customer_ID = act.Customer_ID
  GROUP BY fb.首购月, m
)
SELECT
  DATE_FORMAT(j.首购月, '%Y-%m')  AS 首购月,
  j.m                              AS 月序,          -- 整数，用于排序
  j.n                              AS 活跃客户数,
  base.n0                          AS 新增客户数,
  ROUND(j.n / base.n0 * 100, 1)    AS 留存率
FROM j JOIN base ON base.首购月 = j.首购月
WHERE j.m <= 12        -- 与 06 宽表口径一致（M0–M12）。
                       -- 不加此限制会长到 M24 —— 数据跨度 25 个月，
                       -- 早期 cohort 能观察到 2 年后的购买，那部分本文件不输出。
ORDER BY j.首购月, j.m
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/exports/10_cohort_long.csv'
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n';


-- ------------------------------------------------------------
-- 导出结果确认
-- ------------------------------------------------------------
SELECT '导出完成，文件位于 ' AS 提示, @@secure_file_priv AS 目录;
