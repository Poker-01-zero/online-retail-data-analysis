-- ============================================================
-- 12_product_abc.sql
-- 用途：商品 ABC 分类 + 品类销售结构
-- 依赖：05（清洗层）、06（派生字段 Revenue）
-- 表：online_retail_clean
-- ============================================================
-- 【ABC 是什么】
--   帕累托的商品版 —— D5 把【客户】按消费额分组，这里把【商品】按销售额分组。
--   同一个方法，换一个维度用。
--
--     A 类：累计销售额前 70%  → 少数商品贡献大部分营收  → 重点保障库存
--     B 类：70% – 90%         → 中间                     → 常规管理
--     C 类：90% – 100%        → 大量商品贡献极少         → 考虑缩减/淘汰
--
--   业务意义：这是【采购和库存决策的直接依据】。资金压在 C 类商品上就是浪费。
--
-- 【三个必须写明的口径决策】
--
--   1) 分类依据用【销售额】，不是销量。
--      两者会给出不同答案：单价高但卖得少的商品在销售额口径下是 A 类，
--      在销量口径下可能是 C 类。选销售额是因为它对应"营收贡献"，
--      与财务/采购的决策语言一致。若目标是仓储/物流（按件数占用库位），
--      应改用销量口径并重跑。
--
--   2) 阈值 70% / 90% 是【人为设定】的。
--      常见的还有 80%/95%、75%/95% 等。换一个阈值，A 类商品数会变。
--      所以"Top X% 商品贡献 Y%"这个说法必须连同阈值一起写出来。
--
--   3) 【商品标识只用 StockCode，Description 只能看不能算。】
--      实测：独立 StockCode 4,699 个，独立 Description 5,307 个 ——
--      描述比商品多 638 个，说明同一个商品有多种描述写法（空格/大小写/拼写差异）。
--      用 Description 分组会把同一个商品拆成多个。
--
-- 【品类是人工归纳的近似 —— 必须声明】
--   本数据集【没有品类字段】。Description 的首词不可靠（WHITE / RED / SMALL
--   都是形容词），尾词也不可靠（REGENCY CAKESTAND 3 TIER 的尾词是 TIER）。
--   所以下面的品类是用一组关键词【人工归纳】出来的近似分类：
--     · 一个商品只归一类，判定顺序即 CASE 的书写顺序（先判的优先）
--     · 判定顺序把「圣诞节日」放在最前 —— 圣诞商品在运营上有独立的备货节奏
--     · 描述中不含任何关键词的商品归入「未归类」
--     · 【引用品类结论时必须同时报告覆盖率】，否则会高估结构结论的可靠性
--
-- 【关键数字（2026-10-15 实测）】
--   独立商品 4,699 个 ｜ 商品销售总额 = 全量营收 £19,082,339.73
-- ============================================================

USE online_retail;


-- ------------------------------------------------------------
-- ① 商品销售明细（每个 StockCode 一行）
--    检查点：4,699 行 ｜ 销售额合计 19082339.73
-- ------------------------------------------------------------
SELECT
  StockCode,
  MAX(Description)          AS 商品描述,   -- 一个商品可能有多种描述写法，取其一作展示
  SUM(Quantity)             AS 销量,
  COUNT(DISTINCT Invoice)   AS 订单数,
  ROUND(SUM(Revenue), 2)    AS 销售额
FROM online_retail_clean
GROUP BY StockCode
ORDER BY 销售额 DESC;


-- ============================================================
-- ② ABC 分类：按销售额降序，用【累计占比】划档
--
--    「累计销售额」用窗口函数 SUM() OVER (ORDER BY ...) 求：
--    它对排在前面的所有商品求和，正是"前 N 个商品一共卖了多少"。
--    这和 D5 帕累托里的「累计占比」是同一个手法。
--
--    检查点：A+B+C 商品数 = 4699 ｜ 销售额合计 = 19082339.73
-- ============================================================
WITH p AS (
  SELECT StockCode, SUM(Revenue) AS 销售额
  FROM online_retail_clean
  GROUP BY StockCode
),
c AS (
  SELECT
    StockCode,
    销售额,
    ROW_NUMBER() OVER (ORDER BY 销售额 DESC, StockCode)          AS 排名,
    SUM(销售额) OVER (ORDER BY 销售额 DESC, StockCode)           AS 累计销售额,
    SUM(销售额) OVER ()                                          AS 总额
  FROM p
),
t AS (
  SELECT
    StockCode, 销售额, 排名, 累计销售额, 总额,
    ROUND(累计销售额 / 总额 * 100, 4) AS 累计占比
  FROM c
)
SELECT
  StockCode,
  排名,
  ROUND(销售额, 2)  AS 销售额,
  累计占比,
  CASE WHEN 累计占比 <= 70 THEN 'A'
       WHEN 累计占比 <= 90 THEN 'B'
       ELSE                     'C' END AS ABC类别
FROM t
ORDER BY 排名;


-- ------------------------------------------------------------
-- ③ 三类汇总 —— ABC 分析真正要看的表
-- ------------------------------------------------------------
WITH p AS (
  SELECT StockCode, SUM(Revenue) AS 销售额
  FROM online_retail_clean GROUP BY StockCode
),
c AS (
  SELECT StockCode, 销售额,
         SUM(销售额) OVER (ORDER BY 销售额 DESC, StockCode) AS 累计销售额,
         SUM(销售额) OVER () AS 总额
  FROM p
),
t AS (
  SELECT StockCode, 销售额,
         ROUND(累计销售额 / 总额 * 100, 4) AS 累计占比
  FROM c
)
SELECT
  CASE WHEN 累计占比 <= 70 THEN 'A'
       WHEN 累计占比 <= 90 THEN 'B'
       ELSE                     'C' END          AS ABC类别,
  COUNT(*)                                       AS 商品数,
  ROUND(COUNT(*) / 4699 * 100, 2)                AS 商品数占比,
  ROUND(SUM(销售额), 2)                          AS 销售额,
  ROUND(SUM(销售额) / (SELECT SUM(销售额) FROM p) * 100, 2) AS 销售额占比,
  ROUND(AVG(销售额), 2)                          AS 平均单品销售额
FROM t
GROUP BY ABC类别
ORDER BY ABC类别;

-- 实测：
--   A 类   674 个（14.34%）→ 销售额占比 69.99% ｜ 平均单品 £19,816
--   B 类 1,015 个（21.60%）→ 销售额占比 20.00% ｜ 平均单品 £ 3,761
--   C 类 3,010 个（64.06%）→ 销售额占比 10.00% ｜ 平均单品 £   634
--   → 14% 的商品贡献 70% 销售额；64% 的商品只贡献 10%。
--      A 类与 C 类的平均单品销售额相差 31 倍。


-- ============================================================
-- ④ 品类销售结构（关键词人工归纳，见文件头声明）
-- ============================================================
WITH p AS (
  SELECT StockCode, MAX(Description) AS d, SUM(Revenue) AS 销售额
  FROM online_retail_clean
  WHERE Description IS NOT NULL
  GROUP BY StockCode
),
k AS (
  SELECT d, 销售额,
    CASE
      -- 1 圣诞节日（判定顺序最前：圣诞商品有独立的备货节奏）
      WHEN d LIKE '%CHRISTMAS%' OR d LIKE '%XMAS%'   OR d LIKE '%SANTA%'
        OR d LIKE '%ADVENT%'    OR d LIKE '%REINDEER%' OR d LIKE '%SNOWMAN%'
        OR d LIKE '%STOCKING%'                                    THEN '1 圣诞节日'
      -- 2 包袋
      WHEN d LIKE '%BAG%' OR d LIKE '%SHOPPER%' OR d LIKE '%TOTE%' THEN '2 包袋'
      -- 3 灯饰蜡烛
      WHEN d LIKE '%T-LIGHT%' OR d LIKE '%LIGHT%' OR d LIKE '%CANDLE%'
        OR d LIKE '%LANTERN%'                                     THEN '3 灯饰蜡烛'
      -- 4 厨房餐具
      WHEN d LIKE '%CAKE%' OR d LIKE '%BAKING%' OR d LIKE '%CUTLERY%'
        OR d LIKE '%KITCHEN%' OR d LIKE '%MUG%' OR d LIKE '%CUP%'
        OR d LIKE '%JUG%' OR d LIKE '%TEAPOT%' OR d LIKE '%PLATE%'
        OR d LIKE '%BOWL%' OR d LIKE '%TEA %'  OR d LIKE '%APRON%' THEN '4 厨房餐具'
      -- 5 收纳家居
      WHEN d LIKE '%BOX%' OR d LIKE '%HOLDER%' OR d LIKE '%BASKET%'
        OR d LIKE '%JAR%' OR d LIKE '%STORAGE%' OR d LIKE '%RACK%'
        OR d LIKE '%TIN%' OR d LIKE '%POT%' OR d LIKE '%CABINET%'
        OR d LIKE '%DRAWER%' OR d LIKE '%SHELF%'                  THEN '5 收纳家居'
      -- 6 装饰摆件
      WHEN d LIKE '%ORNAMENT%' OR d LIKE '%DECORATION%' OR d LIKE '%SIGN%'
        OR d LIKE '%FRAME%' OR d LIKE '%HANGING%' OR d LIKE '%HEART%'
        OR d LIKE '%BOARD%' OR d LIKE '%CLOCK%'                   THEN '6 装饰摆件'
      -- 7 派对纸品文具
      WHEN d LIKE '%BUNTING%' OR d LIKE '%PAPER%' OR d LIKE '%CARD%'
        OR d LIKE '%PARTY%' OR d LIKE '%PENCIL%' OR d LIKE '%RIBBON%'
        OR d LIKE '%MEMO%'                                        THEN '7 派对纸品文具'
      -- 8 门垫雨具
      WHEN d LIKE '%DOORMAT%' OR d LIKE '%PARASOL%' OR d LIKE '%UMBRELLA%'
        OR d LIKE '%MAT %'                                        THEN '8 门垫雨具'
      -- 9 家居日用
      WHEN d LIKE '%HOT WATER BOTTLE%' OR d LIKE '%BOTTLE%' OR d LIKE '%FAN%'
        OR d LIKE '%PAINT%' OR d LIKE '%JAM%'                     THEN '9 家居日用'
      ELSE '10 未归类'
    END AS 品类
  FROM p
)
SELECT
  品类,
  COUNT(*)                                        AS 商品数,
  ROUND(SUM(销售额), 2)                           AS 销售额,
  ROUND(SUM(销售额) / (SELECT SUM(销售额) FROM k) * 100, 2) AS 销售占比
FROM k
GROUP BY 品类
ORDER BY 销售占比 DESC;

-- 【覆盖率声明 —— 引用品类结论时必须一起报这个数】
--   覆盖率 = 100% − 「10 未归类」的销售占比。
--   上表最后一行的 销售占比 就是未归类占比，减一下即可。
--   覆盖率越低，结构结论越不可靠 —— 所以引用时必须把它一起写出来。


-- ============================================================
-- 【分析结论】
-- ============================================================
--
-- 一、商品端的集中度比客户端【更高】
--
--    · 客户：Top 10%（584 人）贡献 63.18% 营收
--    · 商品：Top 14.34%（674 个）贡献 69.99% 销售额
--      更极端的对比是 C 类：64% 的商品只贡献 10%
--
--    → 所以：两端都高度集中，但【商品端的"长尾"拖得更长】——
--      客户端的 90% 贡献了 37% 营收，而商品端的 86% 只贡献 30%。
--      这意味着 SKU 数量本身是一个可优化的杠杆：砍掉 C 类商品对营收的伤害
--      远小于砍掉 90% 客户的伤害。
--
-- 二、ABC 的真实用途是把 SKU 数量砍下来
--
--    C 类 3,010 个商品只贡献 10.00% 销售额，平均单品仅 £634。
--    → 所以：C 类不应该有同等的库存深度和采购频次。
--      真正该做的是【对 C 类做减法】—— 减少 SKU 数量，把资金和货架
--      腾给 A 类那 674 个商品。
--
-- 三、品类结构：收纳家居、厨房餐具、装饰摆件三分天下
--
--    （数字见 ④ 的运行结果；覆盖率 82.50%）
--    前三类合计约 49% 销售额，且商品数都在 500 上下 ——
--    看不出哪一类是"小而美"的暴利品类，营收结构比较平均。
--
--    → 所以：这个商家的商品结构是"多品类均摊"，没有明显的拳头品类。
--      这解释了为什么商品端的集中度主要体现在【单品】而非【品类】上 ——
--      A 类 674 个商品分散在各个品类里，而不是集中在某一个品类。
--
-- 四、本分析的边界
--
--    · 口径：全量营收（含匿名订单），因为商品分析不涉及客户归属。
--    · 【品类是人工归纳的近似】。一个商品只归一类，判定顺序见 CASE 书写顺序；
--      描述不含关键词的归入「未归类」。引用品类结论时必须同时报告覆盖率 ——
--      覆盖率越低，结构结论越不可靠。
--    · ABC 阈值 70%/90% 是人为设定，换阈值会改变 A 类商品数。
--    · 只有 25 个月数据，无法判断某个商品是"季节性热销"还是"正在衰退"。
--      要做这个判断需要按年拆开看同一商品的销售额变化。
-- ============================================================
