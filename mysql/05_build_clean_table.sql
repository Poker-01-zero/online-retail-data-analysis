-- ============================================================
-- 05_build_clean_table.sql
-- 用途：由原始层（VARCHAR）构建清洗层（类型正确 + 业务有效）
-- 结果：online_retail_clean，约 996,548 行
-- ============================================================
-- 【分层设计说明】
--   原始层 online_retail_raw 全部字段为 VARCHAR —— 只负责"接住"数据。
--   本脚本负责"理解"数据：剔除脏数据 + 转换类型。这是 ELT 的 T（Transform）。
--
-- 【清洗漏斗（顺序不可随意调整，各类脏数据存在重叠）】
--   步骤 0  原始                     1,067,371
--   步骤 1  剔取消订单(Invoice C)      -19,494
--   步骤 2  剔退货(Quantity < 0)        -3,457
--   步骤 3  剔非正价格(Price <= 0)      -2,768
--   步骤 4  剔非商品行(StockCode)       -4,776
--   步骤 5  去完全重复行               -33,663
--   步骤 6  剔「被取消的原始订单行」     -6,665   ← 本次新增，见决策 4
--   最终    有效销售明细               996,548  （保留率 93.4%）
--
--   注意：不能把各类型独立计数相加（19,494+22,950+6,207+6,094 = 54,745 是虚高的），
--         因为大部分退货行本身就是取消订单，已被步骤 1 剔除。详见 ../数据质量记录.md
-- ============================================================
-- 【关键决策】
--   1) Customer_ID 为空的行【保留】，转为 NULL。
--      理由：这些是有效销售记录，仅买家未知。剔除会低估营收；
--            用户维度分析（RFM/留存）应在查询时用 WHERE Customer_ID IS NOT NULL 过滤。
--      补充（D5 实测）：匿名订单并非随机缺失 —— 匿名发票平均 77.6 行、£880.94，
--            分别是实名发票的 3.66 倍与 1.89 倍，且呈"1-5 行小散单"与
--            "100+ 行宽篮子批发单"的双峰分布。因此实名子集是有偏样本，
--            基于它的集中度/分档结论必须写明口径。
--   2) Description 的 TRIM 放在【去重之后】执行。
--      【实测结论】先 TRIM 再去重 与 先去重再 TRIM，在本数据集上【结果完全相同】：
--         按原值去重                  → 1,003,213 行
--         先 TRIM(Description) 再去重 → 1,003,213 行
--         连 Price 一起规范化再去重   → 1,003,213 行（差 0 行）
--      原因：重复行是"同一行被记录了两次"，两遍的原始文本【连空格都一样】，
--            所以去重先后都能删掉。要产生差异，得是同一笔交易录入两次、
--            其中一次多打了空格 —— 本数据不存在这种情况。
--      （另：Price 的 2,807 种字符串形式对应 2,806 个数值，唯一差异来自
--        0.0 与 0.001 都四舍五入为 0.00，而这类行已被规则 3 剔除。）
--
--      ⚠️ 早期版本的注释写的是"先去空格会改变漏斗口径"—— 那句话本身没错，
--         但属于【未经验证的防御性理由】。实测证明两种顺序在本数据上等价。
--      保留"先去重"顺序的理由仅剩一条：去重基于【文件里实际存的原始值】，
--      不依赖任何"规范化选择"，漏斗更易复现。这是低风险选择，不是唯一正确做法。
--      若换到别的数据集，更通用的做法是【先规范化、再去重】。
--      注：商品唯一标识是 StockCode，Description 仅作展示，不影响品类归集。
--   3) 非商品行（POST/DOT/M/BANK CHARGES/AMAZONFEE/坏账冲销等）全部剔除。
--      理由：它们是发票上的费用与调账条目，不是商品，混入会污染品类分析与价格统计。
--   4) 【被取消的原始订单行必须一并剔除】—— D5 发现的清洗漏洞，详见步骤 6。
-- ============================================================

USE online_retail;

-- 表已存在时报 Error 1050，属预期无害。如需重建先手动 DROP。
CREATE TABLE online_retail_clean (
  Invoice      VARCHAR(12)   NOT NULL,
  StockCode    VARCHAR(15)   NOT NULL,
  Description  VARCHAR(100)      NULL,   -- 有 4,382 行为空
  Quantity     INT           NOT NULL,   -- 全部为正（退货已剔除）
  InvoiceDate  DATETIME      NOT NULL,
  Price        DECIMAL(10,2) NOT NULL,   -- 全部为正（赠品/坏账已剔除）
  Customer_ID  INT               NULL,   -- NULL 表示匿名订单（约 22.8%）
  Country      VARCHAR(50)   NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- ------------------------------------------------------------
-- 数据装载
-- 内层子查询：执行清洗漏斗的步骤 1-5（与统计口径完全一致）
-- 外层 SELECT：执行类型转换与文本规范化
-- ------------------------------------------------------------
INSERT INTO online_retail_clean
SELECT
  Invoice,
  StockCode,
  TRIM(Description)                                        AS Description,
  CAST(Quantity AS SIGNED)                                 AS Quantity,
  STR_TO_DATE(InvoiceDate, '%Y-%m-%d %H:%i:%s')            AS InvoiceDate,
  CAST(Price AS DECIMAL(10,2))                             AS Price,
  -- Customer_ID 源值为 '13085.0' 格式，需先去掉小数部分；
  -- 空字符串 '' 需转为真正的 NULL（NULL 与 '' 在 SQL 中语义不同）
  CAST(NULLIF(SUBSTRING_INDEX(Customer_ID, '.', 1), '') AS UNSIGNED) AS Customer_ID,
  Country
FROM (
  SELECT DISTINCT
    Invoice, StockCode, Description, Quantity, InvoiceDate, Price, Customer_ID, Country
  FROM online_retail_raw
  WHERE Invoice NOT LIKE 'C%'                                   -- 剔除取消订单
    AND CAST(Quantity AS SIGNED) > 0                            -- 剔除退货
    AND CAST(Price AS DECIMAL(10,2)) > 0                        -- 剔除赠品与坏账冲销
    AND StockCode REGEXP '^[0-9]{5}[A-Za-z]*$'                  -- 剔除非商品行
) t;


-- ============================================================
-- 步骤 6：剔除「被取消的原始订单行」【D5 新增】
-- ============================================================
-- 【漏洞说明】
--   步骤 1 的 'Invoice NOT LIKE C%' 只剔除了【取消动作本身】，
--   被取消的【原始订单】仍留在表里，导致营收虚增。
--
--   实例（本数据集金额最大的一行就是这个漏洞）：
--     581483  23843 PAPER CRAFT LITTLE BIRDIE   +80,995  2011-12-09 09:15
--     C581484 23843 PAPER CRAFT LITTLE BIRDIE   -80,995  2011-12-09 09:27  ← 12 分钟后取消
--   我们剔掉了 C581484，却留着 581483，于是 £168,469.60 凭空计入营收。
--   另有 541431 / C541433（£77,183.60，16 分钟后取消）同理。
--
--   影响：清洗层中残留 6,665 行此类记录，虚增营收 £560,336.29（占总营收 2.85%）。
--   危害不止于营收数字：客户 12346 唯一的"大额订单"其实被取消了，
--   若不修正，他会在 RFM 里被误判为高价值客户。
--
-- 【配对口径】按四要素精确匹配：Customer_ID + StockCode + Quantity + Price
--   - 不用 Invoice 号配对：取消发票号与原始发票号【不成规律】
--     （581483→C581484，541431→C541433），无法由发票号推出原始单。
--   - 加上 Price 是为了降低巧合碰撞的概率。
--   - 匿名订单一律不参与配对：Customer_ID 为 NULL 时等值比较不成立
--     （NULL = NULL 在 SQL 中为 UNKNOWN）。这既是数据库语义的自然结果，
--     也恰好规避了实测中匿名记录的巧合错误配对。
--   - 局限：若原始单与取消行的 StockCode 有笔误差异（如 47556B / 47566B），
--     该配对会漏掉，因此本步骤的剔除量是【下限】，实际虚增略高于此。
--
-- 【为什么不能简单 DELETE ... JOIN】
--   朴素写法「只要存在同四要素的取消行就删」会【删多】：
--   客户 15749 在 2011-01 与 2011-04 各买了 21108 ×3114 @2.10 一次，
--   只在 4 月取消了 1 月那笔；朴素 JOIN 会把 4 月那笔真实销售一并删掉。
--   实测差异：朴素口径删 13,045 行 / £769,891.74，
--            按条数配对删  6,935 行 / £565,776.48 —— 相差 £204,115.26。
--   正确口径：每个 key 下【最多】删除 min(原始行数, 取消行数) 行，
--            用 ROW_NUMBER() 编号后按 rn <= 取消行数 截取即可实现。
-- ============================================================

-- ------------------------------------------------------------
-- 6.1 取消键表：把所有取消行规范化成"被取消的那个订单行"的键
-- ------------------------------------------------------------
DROP TABLE IF EXISTS cancel_keys;
CREATE TABLE cancel_keys (
  StockCode   VARCHAR(15)   NOT NULL,
  Quantity    INT           NOT NULL,   -- 存正值（原始行的数量）
  Price       DECIMAL(10,2) NOT NULL,
  Customer_ID INT           NOT NULL,   -- 匿名取消不参与配对，故为 NOT NULL
  KEY idx_ck (StockCode, Quantity, Price, Customer_ID)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO cancel_keys
SELECT
  StockCode,
  -CAST(Quantity AS SIGNED),                                          -- -(-80995) = 80995
  CAST(Price AS DECIMAL(10,2)),
  CAST(NULLIF(SUBSTRING_INDEX(Customer_ID, '.', 1), '') AS UNSIGNED)
FROM online_retail_raw
WHERE Invoice LIKE 'C%'
  AND CAST(Quantity AS SIGNED) < 0
  AND NULLIF(SUBSTRING_INDEX(Customer_ID, '.', 1), '') IS NOT NULL;


-- ------------------------------------------------------------
-- 6.2 待删行清单：每个 key 下取前 n_neg 行（n_neg = 该 key 的取消行数）
--     ROW_NUMBER 的排序是任意的 —— 一个 key 下被配对的若干行
--     四要素完全相同，因此营收也完全相同，删哪几行不影响聚合结果。
--     ⚠️ 这里【不能】加 SELECT DISTINCT：本清单是与清洗层做 JOIN 删除用的，
--        JOIN 的键不含 Description / Country，因此同键多行本来就会被一并删除。
--        若加 DISTINCT 会把"同键多行"折叠成 1 行，导致这里的【行数统计】报少
--        （实测会从 6,665 报成 6,664），虽然删除结果不变，但对账口径会失真。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS cancel_targets;
CREATE TABLE cancel_targets (
  Invoice     VARCHAR(12)   NOT NULL,
  StockCode   VARCHAR(15)   NOT NULL,
  Quantity    INT           NOT NULL,
  Price       DECIMAL(10,2) NOT NULL,
  Customer_ID INT           NOT NULL,
  InvoiceDate DATETIME      NOT NULL,
  KEY idx_ct (StockCode, Quantity, Price, Customer_ID)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO cancel_targets
SELECT p.Invoice, p.StockCode, p.Quantity, p.Price, p.Customer_ID, p.InvoiceDate
FROM (
  SELECT Invoice, StockCode, Quantity, Price, Customer_ID, InvoiceDate,
         ROW_NUMBER() OVER (
           PARTITION BY StockCode, Quantity, Price, Customer_ID
           ORDER BY InvoiceDate, Invoice
         ) AS rn
  FROM online_retail_clean
  WHERE Customer_ID IS NOT NULL
) p
JOIN (
  SELECT StockCode, Quantity, Price, Customer_ID, COUNT(*) AS n_neg
  FROM cancel_keys
  GROUP BY StockCode, Quantity, Price, Customer_ID
) k
  ON k.StockCode   = p.StockCode
 AND k.Quantity    = p.Quantity
 AND k.Price       = p.Price
 AND k.Customer_ID = p.Customer_ID
WHERE p.rn <= k.n_neg;


-- ------------------------------------------------------------
-- 6.2b 独立复核（必须在 6.3 删除【之前】执行！）
--      不依赖 ROW_NUMBER 的实现，直接按定义求和：
--        应删行数 = Σ min(每个 key 的原始行数, 取消行数)
--      若与 6.2 的待删行数不一致，说明配对逻辑写错了。
--      实测：6665 = 6665 ✅
--      ⚠️ 删除之后再跑这个查询会得到无意义的小数字（因为表已被改小），
--         曾因此误判过一次。
-- ------------------------------------------------------------
SELECT SUM(LEAST(p.n_pos, k.n_neg)) AS 应删行数_理论值
FROM (SELECT StockCode, Quantity, Price, Customer_ID, COUNT(*) AS n_pos
      FROM online_retail_clean WHERE Customer_ID IS NOT NULL
      GROUP BY StockCode, Quantity, Price, Customer_ID) p
JOIN (SELECT StockCode, Quantity, Price, Customer_ID, COUNT(*) AS n_neg
      FROM cancel_keys GROUP BY StockCode, Quantity, Price, Customer_ID) k
  ON k.StockCode = p.StockCode AND k.Quantity = p.Quantity
 AND k.Price = p.Price AND k.Customer_ID = p.Customer_ID;


-- ------------------------------------------------------------
-- 6.3 执行剔除
-- ------------------------------------------------------------
DELETE c
FROM online_retail_clean c
JOIN cancel_targets t
  ON t.Invoice     = c.Invoice
 AND t.StockCode   = c.StockCode
 AND t.Quantity    = c.Quantity
 AND t.Price       = c.Price
 AND t.Customer_ID = c.Customer_ID
 AND t.InvoiceDate = c.InvoiceDate;


-- ------------------------------------------------------------
-- 索引：为后续分析（按客户/日期/商品聚合）提速
-- ------------------------------------------------------------
CREATE INDEX idx_clean_customer ON online_retail_clean (Customer_ID);
CREATE INDEX idx_clean_date     ON online_retail_clean (InvoiceDate);
CREATE INDEX idx_clean_stock    ON online_retail_clean (StockCode);
CREATE INDEX idx_clean_invoice  ON online_retail_clean (Invoice);


-- ------------------------------------------------------------
-- 对账（下方注释为 2026-10-14 实测值）
-- ------------------------------------------------------------
SELECT COUNT(*) AS 清洗后行数 FROM online_retail_clean;                    -- 996548
SELECT ROUND(SUM(Quantity * Price), 2) AS 总营收 FROM online_retail_clean; -- 19082339.73
SELECT COUNT(*) AS 待删行数 FROM cancel_targets;                           -- 6665
SELECT COUNT(*) AS 取消键数 FROM cancel_keys;                              -- 18744
