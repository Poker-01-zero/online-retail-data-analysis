-- ============================================================
-- 11_retention_cohort.sql
-- 用途：留存 / 同期群（cohort）分析 + 复购率 + 购买间隔
-- 依赖：05（清洗层）、06（派生字段 Revenue / YearMonth）
-- 表：online_retail_clean
-- ============================================================
-- 【同期群是什么】
--   按"首次购买月份"给客户分组（同一组 = 一个 cohort），
--   然后追踪这组人之后每个月还剩多少人回来买。
--
--   看【横行】：这一批客户随时间衰减得多快
--   看【竖列】：不同批次的客户，留存质量是在变好还是变差
--
-- 【为什么要做这个 —— 它补的是 RFM 补不了的洞】
--   RFM 是【照片】：告诉你客户此刻处于什么状态。
--   留存是【录像】：告诉你客户是怎么走到这个状态的、未来会怎样。
--   RFM 区分不了"一直在买的老客"和"最近才来的新客"—— 两者 R 都很小。
--
-- 【本项目唯一需要自连接的地方】
--   要把"每个客户的首购月"和"他之后的每一次购买"关联起来，
--   就得让同一张表跟自己 JOIN。这是本项目 JOIN 能力的真实体现
--   （项目计划中刻意不做星型模型，不为人造拆分而拆分）。
--   `act JOIN fb ON fb.Customer_ID = act.Customer_ID`
--
-- 【一个必须处理的技术陷阱：可观测性】
--   算"第 m 个月的留存率"时，分母应等于【所有有机会观察到第 m 个月的 cohort 规模之和】，
--   与该 cohort 在那个月是否真的有活动【无关】。
--   本文件用 TIMESTAMPDIFF(MONTH, 首购月, '2011-11-01') >= m 来限制。
--   （为什么是 2011-11 而不是 2011-12：2011-12 只有 9 天，不算完整月。）
--
--   不做这个过滤会出两个问题：
--     ① 分母退化成"恰好在该月有活动的 cohort" —— 这个分母取决于分子是否存在，
--        是循环定义。若某 cohort 在某月全军覆没（0 活跃），它会直接从分母里消失，
--        反而把留存率【抬高】。
--     ② 暴露期不完整的 cohort 会被混进来。例如 2010-12 的 cohort，
--        它的 M12 落在 2011-12 —— 而那个月只有 9 天，
--        拿它和完整月一起算，口径不一致。
--
--   实测（M12）：
--     不过滤 → 分母 4,300、留存率 22.4%（多收了 2010-12 的 77 人）
--     过滤后 → 分母 4,223、留存率 22.8%
--   可见方向【不是固定的】—— 所以不能简单说"高估"或"低估"，
--   关键是这个过滤让分母的定义变得【与分子无关】，口径才站得住。
--
-- 【已知局限】
--   · 数据只有两年（25 个月），因此能观察到的最大月序约 12，
--     更长期的留存（如 M24）无法计算 —— 这是数据本身的边界，不是方法问题。
--   · 最后一次购买发生在 2011-12 的客户，其后续留存同样被截断。
--
-- 【⚠️ 一个必须先讲清的读法：④ 是「月度留存率」，不是「累积留存」】
--   ④ 每一格 = 【恰好在第 m 月有购买】的客户占比。这就是行业标准的
--   同期群留存定义（Amplitude / Mixpanel 的 cohort 表用的是同一个口径）。
--   所以 ④ 【就是留存率】，它没有算错 —— 容易错的是【解读】：
--     不能把"第 m 月的活跃比例 23%"读成"只剩 23% 的客户还活着"。
--     正确读法是"这一个月里，有 23% 的客户下单了"。
--   同一个客户会在多个月份重复出现，因此各月数值【不可相加】。
--   M0 恒为 100% 是【定义使然】（首购月人人必然有购买），
--   它与 M1 之间的落差【不是流失】，只是首购月的特殊性。
--
--   两个口径回答两个不同的问题，必须分开问、分开答：
--     ④ 月度留存率 ≈ 23%     → 客户【多久来一次】（平均间隔 52.6 天）
--     ⑥ 累积回归率 = 74.2%   → 客户【还回不回来】
--   二者不矛盾：不是同一批人每个月都来。
--
-- 【关键数字（2026-10-15 实测）】
--   复购率 72.43%（4,226 / 5,835）｜ 平均购买间隔 52.6 天
--   月度留存率：M1–M12 稳定在 19.4%–25.0%，M12 为 22.8%
--   一年内至少回来过一次：74.2%（3,134 / 4,223）← "买完就走"的只占 25.8%
-- ============================================================

USE online_retail;


-- ------------------------------------------------------------
-- ① 复购率：买过 2 次及以上的客户占比
--    检查点：4,226 / 5,835 = 72.43%
-- ------------------------------------------------------------
SELECT
  COUNT(*)                        AS 总客户数,
  SUM(F >= 2)                     AS 复购客户数,
  ROUND(SUM(F >= 2) / COUNT(*) * 100, 2) AS 复购率
FROM (
  SELECT Customer_ID, COUNT(DISTINCT Invoice) AS F
  FROM online_retail_clean
  WHERE Customer_ID IS NOT NULL
  GROUP BY Customer_ID
) t;


-- ------------------------------------------------------------
-- ② 购买间隔分布：同一客户相邻两次购买的间隔天数
--    用窗口函数 LAG 取"上一次购买时间"。
--    ⚠️ 先对 (客户, 时间) 去重，否则同一张发票的多行会产生 0 天间隔的假样本。
--      （实测去重后仍有 3,515 次"同一天"下单 —— 这是真实的：
--        同一客户同一天开了多张发票，属于正常的批发行为，不是脏数据。）
--    检查点：间隔样本 30,361 ｜ 平均 52.6 天
-- ------------------------------------------------------------
WITH inv AS (
  SELECT DISTINCT Customer_ID, InvoiceDate
  FROM online_retail_clean
  WHERE Customer_ID IS NOT NULL
),
g AS (
  SELECT DATEDIFF(InvoiceDate,
                  LAG(InvoiceDate) OVER (PARTITION BY Customer_ID ORDER BY InvoiceDate)) AS d
  FROM inv
)
SELECT
  CASE WHEN d = 0    THEN '0. 同一天'
       WHEN d <= 7   THEN '1. 1-7 天'
       WHEN d <= 30  THEN '2. 8-30 天'
       WHEN d <= 90  THEN '3. 31-90 天'
       WHEN d <= 180 THEN '4. 91-180 天'
       ELSE               '5. 180 天以上' END  AS 间隔段,
  COUNT(*)                                     AS 次数,
  ROUND(COUNT(*) / (SELECT COUNT(*) FROM g WHERE d IS NOT NULL) * 100, 1) AS 占比
FROM g
WHERE d IS NOT NULL
GROUP BY 间隔段
ORDER BY 间隔段;

-- 实测：同一天 11.6% ｜ 1-7 天 13.7% ｜ 8-30 天 29.5%
--       31-90 天 28.0% ｜ 91-180 天 10.8% ｜ 180 天以上 6.5%
--   → 主体（57.5%）集中在 8-90 天，大致是月度到季度的补货节奏


-- ------------------------------------------------------------
-- ③ 每月新增客户数（cohort 规模）—— 看拉新能力的变化
--    检查点：25 行 ｜ 合计 5,835
-- ------------------------------------------------------------
WITH fb AS (
  SELECT Customer_ID, DATE(DATE_FORMAT(MIN(InvoiceDate), '%Y-%m-01')) AS 首购月
  FROM online_retail_clean
  WHERE Customer_ID IS NOT NULL
  GROUP BY Customer_ID
)
SELECT 首购月,
       COUNT(*)                              AS 新增客户数,
       ROUND(COUNT(*) / (SELECT COUNT(*) FROM fb) * 100, 2) AS 占比
FROM fb
GROUP BY 首购月
ORDER BY 首购月;

-- 实测：2009-12 有 949 人（16.26%，数据集起点，存量客户集中在此）
--       2010 上半年每月 254–442 人
--       2010-12 ~ 2011-08 跌到每月 73–126 人  ← 拉新明显萎缩
--       2011-09 ~ 2011-11 回升到 185–220 人


-- ------------------------------------------------------------
-- ④ 整体月度留存率曲线（按月序聚合所有 cohort）
--    ⚠️ 这是【月度留存率】—— 每一格是"恰好在第 m 月有购买"的占比。
--       它就是留存率（行业标准定义），但【不能】读成"累积还剩多少人"：
--       同一客户会在多个月出现，各月数值不可相加。
--       M0 恒为 100% 是定义使然，不要拿它和 M1 比出"断崖"。
--    检查点：M0 = 100.0%
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
SELECT j.m                                   AS 月序,
       SUM(base.n0)                          AS 可观测客户数,
       SUM(j.n)                              AS 活跃客户数,
       ROUND(SUM(j.n) / SUM(base.n0) * 100, 1) AS 留存率
FROM j JOIN base ON base.首购月 = j.首购月
WHERE TIMESTAMPDIFF(MONTH, j.首购月, '2011-11-01') >= j.m   -- 可观测性过滤
GROUP BY j.m
ORDER BY j.m;

-- 实测：
--   月序   0     1     2     3     4     5     6     7     8     9    10    11    12
--   活跃 100.0  23.2  23.6  25.0  22.8  21.8  22.1  21.8  20.0  19.4  19.7  21.9  22.8
--   → M1 之后【稳定在 19–25%】，没有随客户"变老"而崩塌。
--     含义：任意一个月，约 1/4 的客户会有购买行为。
--     M0 的 100% 是定义使然，与 M1 的落差不是流失。

-- ------------------------------------------------------------
-- ⑥ 「会不会回来」—— 这才是累积口径
--    月活率答不了"客户还回不回来"，要用这个口径：
--    在可观察满 12 个月的客户中，M1–M12 至少有过一次购买的比例。
--    检查点：3,134 / 4,223 = 74.2%
-- ------------------------------------------------------------
WITH fb AS (
  SELECT Customer_ID, DATE(DATE_FORMAT(MIN(InvoiceDate), '%Y-%m-01')) AS 首购月
  FROM online_retail_clean WHERE Customer_ID IS NOT NULL GROUP BY Customer_ID
),
act AS (
  SELECT DISTINCT Customer_ID, DATE(DATE_FORMAT(InvoiceDate, '%Y-%m-01')) AS 购买月
  FROM online_retail_clean WHERE Customer_ID IS NOT NULL
),
j AS (
  SELECT fb.Customer_ID, TIMESTAMPDIFF(MONTH, fb.首购月, act.购买月) AS m
  FROM act JOIN fb ON fb.Customer_ID = act.Customer_ID
),
obs AS (
  SELECT Customer_ID FROM fb
  WHERE TIMESTAMPDIFF(MONTH, 首购月, '2011-11-01') >= 12
)
SELECT
  COUNT(*)                                  AS 可观测客户,
  COUNT(back.Customer_ID)                   AS 一年内回来过,
  ROUND(COUNT(back.Customer_ID) / COUNT(*) * 100, 1) AS 回来过的比例,
  ROUND((1 - COUNT(back.Customer_ID) / COUNT(*)) * 100, 1) AS 从未回来
FROM obs
LEFT JOIN (SELECT DISTINCT Customer_ID FROM j WHERE m BETWEEN 1 AND 12) back
  ON back.Customer_ID = obs.Customer_ID;

-- 实测：4,223 人中 3,134 人一年内回来过 = 【74.2%】，从未回来的只有 25.8%


-- ------------------------------------------------------------
-- ⑤ 同期群留存矩阵（透视版，M0–M6 便于阅读）
--    完整矩阵用 ④ 的长表格式交给 Tableau 透视即可。
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
  j.首购月                                                        AS 首购月,
  base.n0                                                         AS 新增客户,
  ROUND(MAX(CASE WHEN j.m = 0 THEN j.n END) / base.n0 * 100, 1)   AS M0,
  ROUND(MAX(CASE WHEN j.m = 1 THEN j.n END) / base.n0 * 100, 1)   AS M1,
  ROUND(MAX(CASE WHEN j.m = 2 THEN j.n END) / base.n0 * 100, 1)   AS M2,
  ROUND(MAX(CASE WHEN j.m = 3 THEN j.n END) / base.n0 * 100, 1)   AS M3,
  ROUND(MAX(CASE WHEN j.m = 4 THEN j.n END) / base.n0 * 100, 1)   AS M4,
  ROUND(MAX(CASE WHEN j.m = 5 THEN j.n END) / base.n0 * 100, 1)   AS M5,
  ROUND(MAX(CASE WHEN j.m = 6 THEN j.n END) / base.n0 * 100, 1)   AS M6
FROM j JOIN base ON base.首购月 = j.首购月
WHERE TIMESTAMPDIFF(MONTH, j.首购月, '2011-11-01') >= 0
GROUP BY j.首购月, base.n0
ORDER BY j.首购月;

-- 说明：空白格 = 该 cohort 还没机会观察到那个月（可观测性不足），
--       不是"留存率为 0"。两者必须区分 —— 这是同期群分析最常见的误读。


-- ============================================================
-- 【分析结论】
-- ============================================================
--
-- 一、先纠正一个极易误读的地方：月度留存率 ≠ 累积留存
--
--    ④ 的曲线【就是留存率】，用的是行业标准定义（第 m 月活跃占比），没有算错。
--    错的是解读方式 —— 曾把它读成"第一个月就流失 77%"，
--    即把"第 m 月的活跃比例"当成了"累积还剩多少客户"。
--
--    正确的读法：
--      · 23% 的意思是"这一个月里，有 23% 的客户下单了"
--      · 不是"只剩 23% 的客户还活着"
--      · M0 的 100% 是定义使然（首购月人人必然有购买），
--        它与 M1 的落差【不是流失】
--
--    问"客户还回不回来"要用 ⑥ 的累积口径：74.2% 一年内至少回来过一次。
--
--    （本文件第一版曾写成"约 77% 买完就走、再不回头"，
--      与实际 25.8% 相差近 3 倍。修正依据见 ⑥。）
--
-- 二、真实结论：客户【会回来】，但【回来得慢】
--
--    两个数放在一起看：
--      · 一年内至少回来过一次 —— 【74.2%】，所以"买完就走"只占 25.8%
--      · 但月度留存率只有 19–25%，平均购买间隔 52.6 天
--
--    → 所以：客户并不是"流失了"，而是"回来得慢"。
--      运营动作不是"抢救流失客"，而是【把触达节奏匹配到客户的采购周期】——
--      30–60 天一次，而不是按月推送（对平均 52.6 天的周期来说月度太密）。
--
-- 三、不同批次的活跃水平差异明显（矩阵的竖向读法）
--
--    2009-12 cohort 的 M1 = 34.8%（最高，但它含数据集起点时的存量老客户，
--    那批人本来就已经是老客了，不能算作"新客转化好"）；
--    2010-12 cohort 的 M1 = 9.1%（最低）；
--    2011 年各批次回升到 14–32%。
--
--    → 所以：拉新带来的客户质量在波动。做 cohort 分析的价值正在于此 ——
--      它能把"这个月营收不错"拆解成"是量上来了"还是"是质变好了"。
--
-- 四、拉新能力在 2010 年底到 2011 年中期大幅萎缩
--
--    每月新增客户：2010 上半年 254–442 人/月，
--                  2010-12 ~ 2011-08 跌到 73–126 人/月，
--                  2011-09 起回升到 185–220 人/月。
--
--    → 所以：这段低谷期与 D5 发现的两件事时间上吻合 ——
--      ① 月度趋势里"订单量 −3.53%"，② 帕累托里"一次性客户占 27.57%"。
--      三条独立分析指向同一段时间，可信度互相加强。
--
-- 五、复购率 72.43%，购买间隔主体集中在 8–90 天
--
--    平均间隔 52.6 天，57.5% 的相邻购买发生在 8–90 天内 ——
--    大致是月度到季度的补货节奏，符合批发/半批发客户的采购习惯。
--
--    → 所以：唤醒触达的时机应设在"距上次购买约 30–60 天"，
--      而不是等半年。等半年时，客户已经进入 RFM 里的"重要保持客户"
--      区间（平均 181 天没来），唤醒成本会高得多。
--
-- 六、本分析的边界
--
--    · 口径：仅【实名客户】，不能外推为全体客户（匿名行占 22.74%）。
--    · 数据只有 25 个月，最长只能观察 M12 左右；M12 之后无法计算
--      —— 这是数据边界，不是方法缺陷。
--    · 空白格 ≠ 留存为 0，而是"可观测性不足"。矩阵解读时必须区分。
--    · 【月度留存率 ≠ 累积留存】。本文件两者都给了（④ 与 ⑥），
--      引用时必须写明用的是哪个口径 —— 这是全文最重要的一条提醒。
-- ============================================================
